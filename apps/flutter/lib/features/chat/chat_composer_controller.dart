// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/widgets.dart';

import '../../daemon_client/daemon_client.dart';

/// A composer attachment.
///
/// Placeholder in this slice: the controller owns the list so the "empty
/// draft" rule matches the web composer, but no picker or preview UI ships yet.
class ChatComposerAttachment {
  const ChatComposerAttachment({required this.type, required this.url});

  /// `'image'` or `'audio'`.
  final String type;
  final String url;
}

/// Draft, send/stop state and error restore for the chat composer.
///
/// Mirrors `useChatComposer` (packages/stage-ui/src/composables/use-chat-composer.ts)
/// and `WhisperComposerBar.onSubmit`: the draft is cleared only once a send is
/// committed, a failed send puts the text back, and Stop cancels the in-flight
/// turn through `chat.cancel`. The transcript, the token-delta reconciliation
/// and GenUI rehydration stay in the view.
class ChatComposerController extends ChangeNotifier {
  ChatComposerController({
    required this._client,
    this._sessionId,
    this.onMessageCommitted,
  }) : _input = TextEditingController();

  final DaemonClient _client;
  final TextEditingController _input;

  /// The text field's controller: the view owns the widget, this owns the value.
  TextEditingController get input => _input;

  /// Attachments queued for the next send. Empty until the picker lands.
  final List<ChatComposerAttachment> attachments = <ChatComposerAttachment>[];

  String? _sessionId;

  /// Session the next send targets. Learned from `initialSessionId`, from the
  /// `chat.send` ack, or from the first streamed delta.
  String? get sessionId => _sessionId;

  set sessionId(String? value) {
    if (_sessionId == value) return;
    _sessionId = value;
    _notify();
  }

  bool _sending = false;
  String? _error;
  bool _disposed = false;

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

  /// The daemon's final delta (or a cancel): the turn is over, so Stop goes
  /// back to Send.
  void finishTurn() {
    if (!_sending) return;
    _sending = false;
    _notify();
  }

  /// Commit the draft as a `chat.send` turn.
  ///
  /// Returns the acked message id, or null when no turn was started (empty
  /// draft, already composing, disconnected, or the RPC failed). The ack is
  /// early: the turn is still streaming, so [isComposing] stays true until a
  /// final delta, a cancel ack or an error.
  Future<String?> handleSend() async {
    final text = _input.text.trim();
    if (text.isEmpty || _sending) return null;
    if (!_client.snapshot.isConnected) {
      _fail('Not connected to the daemon.');
      return null;
    }
    _error = null;
    _sending = true;
    _input.clear();
    onMessageCommitted?.call(text);
    _notify();
    try {
      final reply = await _client.call('chat.send', payload: <String, dynamic>{
        'sessionId': _sessionId ?? '',
        'content': text,
        'genUi': true,
      });
      if (reply.ok && reply.data is Map<String, dynamic>) {
        // ChatSendReply is serde camelCase on the wire (sessionId/messageId);
        // snake_case here left the session unset so Stop cancelled nothing.
        final data = reply.data as Map<String, dynamic>;
        final sid = data['sessionId'] as String?;
        final mid = data['messageId'] as String?;
        if (sid != null && sid.isNotEmpty) _sessionId = sid;
        _notify();
        return mid;
      }
      if (!reply.ok) {
        _fail(reply.error?.message ?? 'chat.send failed', draft: text);
        return null;
      }
      return null;
    } on Object catch (e) {
      _fail(
        e is DaemonClientException ? e.message : 'Could not send message: $e',
        draft: text,
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

  void _fail(String message, {String? draft}) {
    _error = message;
    _sending = false;
    if (draft != null) _input.text = draft;
    _notify();
  }

  void _notify() {
    if (_disposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _input.dispose();
    super.dispose();
  }
}