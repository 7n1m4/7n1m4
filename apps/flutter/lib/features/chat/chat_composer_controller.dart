// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../../daemon_client/daemon_client.dart';
import 'composer_draft_store.dart';

/// A composer attachment.
///
/// Local attachments queued for a send.
class ChatComposerAttachment {
  const ChatComposerAttachment({required this.type, required this.url});

  /// `'image'` or `'audio'`.
  final String type;
  final String url;
}

/// Draft, send/stop state and error restore for the chat composer.
///
/// Attachments are local-only and refused on send until the daemon wire
/// contract supports them.
///
/// Mirrors `useChatComposer` (packages/stage-ui/src/composables/use-chat-composer.ts)
/// and `WhisperComposerBar.onSubmit`: the draft is cleared only once a send is
/// committed, a failed send puts the text back, and Stop cancels the in-flight
/// turn through `chat.cancel`. The unsent text is mirrored client-locally in
/// [ComposerDraftStore], keyed by session; it never goes to the daemon. The
/// transcript, the token-delta reconciliation and GenUI rehydration stay in
/// the view.
class ChatComposerController extends ChangeNotifier {
  ChatComposerController({
    required this._client,
    this._sessionId,
    this.onMessageCommitted,
    ComposerDraftStore? draftStore,
  }) : _input = TextEditingController(),
       _drafts = draftStore ?? ComposerDraftStore() {
    _input.addListener(_onDraftChanged);
    // Best-effort: an unavailable platform channel leaves an empty draft.
    unawaited(restoreDraft());
  }

  final DaemonClient _client;
  final TextEditingController _input;

  /// Client-local, file-backed drafts (one per session). Never sent to the
  /// daemon; injected in tests so no platform channel is needed.
  final ComposerDraftStore _drafts;

  /// Suppresses the text listener while the controller itself writes the field
  /// (restore, session switch) so those writes do not become new drafts.
  bool _restoring = false;

  /// The empty key holds a draft typed before any session was assigned.
  String get _draftKey => _sessionId ?? '';

  void _onDraftChanged() {
    if (_disposed || _restoring) return;
    _drafts.write(_draftKey, _input.text);
  }

  /// Load the current session's draft into the composer. Safe to call more
  /// than once: it never overwrites text the user has already typed.
  Future<void> restoreDraft() async {
    await _drafts.ready();
    final sessionAtStart = _sessionId;
    final draft = _drafts.read(sessionAtStart ?? '');
    if (_disposed || _sending || _input.text.isNotEmpty) return;
    if (draft == null || draft.isEmpty || _sessionId != sessionAtStart) return;
    _restoring = true;
    _input.text = draft;
    _input.selection = TextSelection.collapsed(offset: draft.length);
    _restoring = false;
    _notify();
  }

  /// Sent-text recall history. View-local only: never persisted, never sent to
  /// the daemon. ArrowUp/ArrowDown rewrite the draft from this list.
  static const int _maxSentTexts = 50;
  final List<String> _sentTexts = <String>[];

  /// Position counting back from the newest entry: -1 means no active recall.
  int _recallIndex = -1;

  /// The text field's controller: the view owns the widget, this owns the value.
  TextEditingController get input => _input;

  /// Context settings loaded from daemon `settings.get('chat')`.
  Map<String, dynamic> _contextSettings = <String, dynamic>{};

  /// Context settings with `settings.get` semantics.
  Map<String, dynamic> get contextSettings => _contextSettings;

  /// Valid values for the daemon-owned `settings/chat/send-mode` verb.
  static const String defaultSendMode = 'enter';
  static const Set<String> validSendModes = <String>{
    'enter',
    'ctrl-enter',
    'double-enter',
  };

  /// Send trigger selected on the daemon (`settings.get('chat')`).
  ///
  /// Read-only mirror: the client never writes this setting back. Missing or
  /// unknown values fall back to 'enter' so an older daemon cannot lock the
  /// composer. Mirrors `useSettingsChat.sendMode`.
  String get sendMode {
    final value = _contextSettings['sendMode'];
    return value is String && validSendModes.contains(value)
        ? value
        : defaultSendMode;
  }

  /// Attachments queued for the next send. Empty until the picker lands.
  final List<ChatComposerAttachment> attachments = <ChatComposerAttachment>[];

  String? _sessionId;

  /// Session the next send targets. Learned from `initialSessionId`, from the
  /// `chat.send` ack, or from the first streamed delta.
  String? get sessionId => _sessionId;

  set sessionId(String? value) {
    if (_sessionId == value) return;
    // Park the outgoing draft before switching: the listener would otherwise
    // write it under the incoming session id.
    if (_input.text.isNotEmpty) _drafts.write(_sessionId ?? '', _input.text);
    _sessionId = value;
    _restoring = true;
    _input.clear();
    _restoring = false;
    unawaited(restoreDraft());
    _notify();
  }

  bool _sending = false;
  String? _error;
  bool _disposed = false;

  // Read-only mirror of the daemon-owned selection. It is refreshed from
  // `settings.get('chat-provider')` when context settings load and before
  // each send; there is no local persistence in the client.
  String _activeProvider = '';
  String _activeModel = '';

  /// Provider id selected on the daemon for chat sends (empty = automatic).
  String get activeProvider => _activeProvider;

  /// Model id selected on the daemon for chat sends (empty = provider default).
  String get activeModel => _activeModel;

  /// A turn is in flight: the text field is locked and the button is Stop.
  bool get isComposing => _sending;

  /// The daemon has a turn `chat.cancel` can stop.
  bool get canStop => _sending;

  /// Nothing queued to send: the button is Stop, not Send
  /// (`WhisperComposerBar.onSubmit`).
  bool get showStop => canStop && !hasContent;

  bool get hasContent =>
      _input.text.trim().isNotEmpty || attachments.isNotEmpty;

  /// Last send/cancel failure, or null. The view renders it verbatim.
  String? get error => _error;

  /// Fired synchronously when the draft is committed, before the RPC runs: the
  /// view appends the user's bubble so it lands ahead of the first delta.
  void Function(String text)? onMessageCommitted;

  void clearError() {
    if (_error == null) return;
    _error = null;
    _notify();
  }

  /// Load context settings and the daemon-owned active selection. Ignores
  /// failures: an unreachable selection RPC leaves automatic selection intact.
  Future<void> loadContextSettings() async {
    try {
      _contextSettings = await _client.settingsGet('chat');
      if (_disposed) return;
      _notify();
    } catch (_) {
      // ignore
    }
    await _refreshActiveSelection();
  }

  Future<void> _refreshActiveSelection() async {
    try {
      final settings = await _client.settingsGet('chat-provider');
      if (_disposed) return;
      _activeProvider = (settings['activeProvider'] ?? '').toString();
      _activeModel = (settings['activeModel'] ?? '').toString();
      _notify();
    } catch (_) {
      // The daemon still resolves selection on send; keep the last mirror.
    }
  }

  /// The daemon's final delta (or a cancel): the turn is over, so Stop goes
  /// back to Send.
  void finishTurn() {
    if (!_sending) return;
    _sending = false;
    _notify();
  }

  void addAttachment(String type, String url) {
    if (!{'image', 'audio'}.contains(type)) return;
    if (url.trim().isEmpty) return;
    attachments.add(ChatComposerAttachment(type: type, url: url));
    _notify();
  }

  void removeAttachmentAt(int index) {
    if (index < 0 || index >= attachments.length) return;
    attachments.removeAt(index);
    _notify();
  }

  /// Walk back through previously sent texts. Returns true only when the draft
  /// actually changed, so the view can consume the arrow key.
  bool recallPrevious() {
    if (_sentTexts.isEmpty) return false;
    final next = _recallIndex + 1;
    if (next >= _sentTexts.length) return false;
    _recallIndex = next;
    _showRecalled(_sentTexts[_sentTexts.length - 1 - next]);
    return true;
  }

  /// Walk forward, past the newest entry back to an empty draft. Returns true
  /// only when a recall step (including the final clear) happened.
  bool recallNext() {
    if (_recallIndex < 0) return false;
    final next = _recallIndex - 1;
    if (next < 0) {
      _recallIndex = -1;
      _input.clear();
      _input.selection = const TextSelection.collapsed(offset: 0);
      return true;
    }
    _recallIndex = next;
    _showRecalled(_sentTexts[_sentTexts.length - 1 - next]);
    return true;
  }

  void _showRecalled(String text) {
    _input.text = text;
    _input.selection = TextSelection.collapsed(offset: text.length);
  }

  /// Appends a committed send, deduped against the newest entry. Returns
  /// whether a new entry was appended so a failed RPC can roll it back.
  bool _rememberSentText(String text) {
    // A repeated send still leaves recall at the newest entry; resetting here
    // (rather than after the dedupe check) prevents a stuck index.
    _recallIndex = -1;
    if (_sentTexts.isNotEmpty && _sentTexts.last == text) return false;
    _sentTexts.add(text);
    return true;
  }

  /// Evict only after the RPC succeeds, so a failed 51st send cannot shrink
  /// history to 49 entries.
  void _commitSentText() {
    if (_sentTexts.length > _maxSentTexts) _sentTexts.removeAt(0);
  }

  void _forgetSentText({required bool appended, required String text}) {
    if (appended && _sentTexts.isNotEmpty && _sentTexts.last == text) {
      _sentTexts.removeLast();
    }
  }

  /// Commit the draft as a `chat.send` turn.
  ///
  /// Returns the acked message id, or null when no turn was started (empty
  /// draft, attachments, already composing, disconnected, or the RPC failed).
  /// The ack is early: the turn is still streaming, so [isComposing] stays
  /// true until a final delta, a cancel ack or an error.
  Future<String?> handleSend() async {
    if (_sending) return null;
    if (attachments.isNotEmpty) {
      // chat.send carries text only. Silently dropping the attachment would
      // lose the user's image/audio, so refuse the send and leave the draft
      // (including attachments) untouched; the screen renders [error].
      _fail(
        'Attachments are not supported by the daemon yet. Remove the '
        'attachment to send this message.',
      );
      return null;
    }
    final text = _input.text.trim();
    if (text.isEmpty) return null;
    // A session switch during the RPC must not file a restored draft under the
    // session the user is now looking at. Pin the key the text was sent from.
    final draftKey = _draftKey;
    if (!_client.snapshot.isConnected) {
      _fail('Not connected to the daemon.');
      return null;
    }
    final appendedToRecall = _rememberSentText(text);
    _error = null;
    _sending = true;
    _input.clear();
    await _refreshActiveSelection();
    onMessageCommitted?.call(text);
    _notify();
    try {
      final payload = <String, dynamic>{
        'sessionId': _sessionId ?? '',
        'content': text,
        'genUi': true,
      };
      final reply = await _client.call('chat.send', payload: payload);
      if (!reply.ok || reply.data is! Map<String, dynamic>) {
        _forgetSentText(appended: appendedToRecall, text: text);
        _fail(
          reply.ok
              ? 'Malformed chat.send reply.'
              : reply.error?.message ?? 'chat.send failed',
          draft: text,
          draftKey: draftKey,
        );
        return null;
      }
      // ChatSendReply is serde camelCase on the wire (sessionId/messageId);
      // snake_case here left the session unset so Stop cancelled nothing.
      final data = reply.data as Map<String, dynamic>;
      final sid = data['sessionId'] as String?;
      final mid = data['messageId'] as String?;
      if (sid != null && sid.isNotEmpty) _sessionId = sid;
      _commitSentText();
      _notify();
      return mid;
    } on Object catch (e) {
      _forgetSentText(appended: appendedToRecall, text: text);
      _fail(
        e is DaemonClientException ? e.message : 'Could not send message: $e',
        draft: text,
        draftKey: draftKey,
      );
      return null;
    }
  }

  /// Stop the in-flight turn via the daemon's `chat.cancel` verb.
  ///
  /// Returns false when the cancel RPC failed, so the caller can keep the open
  /// turn intact.
  Future<bool> stopGeneration() async {
    _error = null;
    _notify();
    try {
      final cancelled = await _client.cancelChat(_sessionId ?? '');
      if (_disposed) return false;
      _sending = false;
      if (!cancelled) _error = 'No active turn to cancel.';
      _notify();
      return true;
    } on DaemonClientException catch (e) {
      if (_disposed) return false;
      _error = e.message;
      _notify();
      return false;
    }
  }

  void _fail(String message, {String? draft, String? draftKey}) {
    _error = message;
    _sending = false;
    if (draft != null) {
      final key = draftKey ?? _draftKey;
      if (key == _draftKey) {
        // Restore the field only while it still belongs to this session. The
        // listener is suppressed so the draft is filed once, under [key].
        _restoring = true;
        _input.text = draft;
        _restoring = false;
      }
      // A session switch mid-RPC must not put the old text in the new field,
      // nor file it under the new session: persist to the send's own key.
      _drafts.write(key, draft);
    }
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _input.removeListener(_onDraftChanged);
    _drafts.write(_draftKey, _input.text);
    _drafts.flush();
    attachments.clear();
    _sentTexts.clear();
    _recallIndex = -1;
    _input.dispose();
    super.dispose();
  }
}
