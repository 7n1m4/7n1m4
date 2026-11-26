// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../daemon_client/daemon_client.dart';
import '../../theme/app_theme.dart';
import 'chat_composer_controller.dart';
import 'chat_message_display.dart';
import 'genui_surface_controller.dart';
import '../sessions/sessions_screen.dart';

/// Minimal chat surface: sends `chat.send` RPCs and renders streamed
/// `token.delta` events. View state only; the daemon owns sessions.
///
/// Draft, send/stop state and `chat.cancel` live in [ChatComposerController];
/// this widget owns the transcript, the delta reconciliation by `message_id`
/// and GenUI rehydration.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.client, this.initialSessionId});

  final DaemonClient client;

  /// When opening a persisted session, its id is replayed via `chat.history`.
  final String? initialSessionId;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final List<_ChatMessage> _messages = <_ChatMessage>[];
  List<Map<String, dynamic>> _sessions = const <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _cards = const <Map<String, dynamic>>[];
  String? _selectedCardId;
  bool _sessionPanelOpen = false;
  String? _contextError;
  ({String id, bool liked, bool bookmarked})? _cardMetadata;
  String? _metadataError;
  bool _metadataBusy = false;
  final AiriGenUiSession _genUi = AiriGenUiSession();
  late final ChatComposerController _composer;
  String? _activeMessageId;
  final StringBuffer _deltaBuffer = StringBuffer();
  bool _assistantStreaming = false;
  bool _historyUnavailable = false;
  Object? _historyCursor;
  bool _historyLoading = false;
  StreamSubscription<DaemonStatus>? _statusSub;
  void Function()? _unsubscribeEvent;
  bool _wasConnected = false;
  _EmotionCue? _cue;
  final Map<String, int> _cueSeqByActor = <String, int>{};
  // Bus ordering per message, used to drop replayed/out-of-order token frames
  // after a reconnect. The daemon re-publishes on the same event topic.
  final Map<String, int> _lastTokenSeq = <String, int>{};
  final Map<String, int> _lastTokenIndex = <String, int>{};
  final Set<String> _finalizedMessageIds = <String>{};
  // Dedup only needs replay depth, not session history: prune the oldest
  // finalized turn once the window is exceeded.
  final List<String> _finalizedMessageOrder = <String>[];
  // Event topics are per socket; serialize subscribe/unsubscribe so disposing
  // mid-RPC cannot leave a stale topic enabled on the daemon.
  Future<void> _eventRpc = Future<void>.value();

  @override
  void initState() {
    super.initState();
    _composer = ChatComposerController(
      client: widget.client,
      sessionId: widget.initialSessionId,
      onMessageCommitted: (text) {
        if (mounted) setState(() => _messages.add(_ChatMessage.user(text)));
      },
    );
    _unsubscribeEvent = widget.client.onEvent(_onEvent);
    _wasConnected = widget.client.snapshot.isConnected;
    if (_wasConnected) _requestEmotionEvents();
    // A reconnect drops the stuck Stop state, but the open turn and its
    // assistant bubble survive because the daemon keeps streaming the same
    // message_id; only a real disconnect -> connected transition counts.
    _statusSub = widget.client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      final regainedConnection = connected && !_wasConnected;
      _wasConnected = connected;
      if (regainedConnection) _requestEmotionEvents();
    });
    final initial = widget.initialSessionId;
    if (initial != null && initial.isNotEmpty) {
      unawaited(_loadHistory());
    }
    unawaited(_loadContext());
    unawaited(_composer.loadContextSettings());
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _unsubscribeEvent?.call();
    _requestEventRpc('event.unsubscribe');
    _composer.dispose();
    _genUi.dispose();
    super.dispose();
  }

  /// Best-effort topic opt-in on the authenticated socket. A daemon without
  /// event support must not break the chat surface.
  void _requestEmotionEvents() => _requestEventRpc('event.subscribe');

  void _requestEventRpc(String action) {
    _eventRpc = _eventRpc.then((_) async {
      try {
        await widget.client.call(
          action,
          payload: <String, dynamic>{
            'topics': <String>[EventTopic.emotionTag.wireName],
          },
        );
      } on Object {
        // Subscription failure is non-fatal: chat and cues degrade quietly.
      }
    });
  }

  void _onEvent(GatewayEventFrame event) {
    if (event.topic == EventTopic.emotionTag) {
      final cue = _decodeEmotionCue(event.data);
      if (cue == null || !mounted) return;
      // Only the selected character's cues drive the chat badge. With no
      // character selected there is no actor to filter against.
      final selected = _selectedCardId;
      if (selected != null && selected.isNotEmpty && cue.actorId != selected) {
        return;
      }
      // Per-actor monotonic sequence: ignore replays/out-of-order cues even
      // when another actor's cue happened to arrive later.
      final seq = cue.seq;
      if (seq != null) {
        final last = _cueSeqByActor[cue.actorId];
        if (last != null && seq <= last) return;
        _cueSeqByActor[cue.actorId] = seq;
      }
      setState(() => _cue = cue);
      return;
    }
    if (event.topic != EventTopic.tokenDelta) return;
    final data = event.data;
    final sid = data['session_id'] as String? ?? '';
    if (_composer.sessionId != null &&
        sid.isNotEmpty &&
        sid != _composer.sessionId) {
      return;
    }
    // The chat.send ack can arrive after the first delta; remember the session
    // from the stream so a Stop press cancels the right turn.
    if (_composer.sessionId == null && sid.isNotEmpty)
      _composer.sessionId = sid;
    final mid = data['message_id'] as String? ?? '';
    final delta = data['delta'] as String? ?? '';
    final isFinal = data['final'] == true;
    final reason = data['reason'];
    // The publisher treats cancelled/error as terminal even on a non-final
    // frame (events.rs:376-378), so the composer must unlock there too.
    final terminal = isFinal || reason == 'cancelled' || reason == 'error';
    // A missing reason means `complete` on older daemons. Cancelled/error
    // turns must not be displayed, parsed or spoken (mirrors main.dart).
    final failedTurn = terminal && reason != null && reason != 'complete';
    final rawSeq = data['seq'];
    final rawIndex = data['index'];
    final seq = rawSeq is int ? rawSeq : null;
    final index = rawIndex is int ? rawIndex : null;
    if (!mounted) return;

    // A reconnect can replay a whole turn. Drop stale/duplicate frames so a
    // delta never doubles visible text and a replayed final cannot close a
    // newer turn. Frames without seq/index (older daemons/fakes) bypass dedup.
    if (terminal && mid.isNotEmpty && _finalizedMessageIds.contains(mid)) {
      return;
    }
    final lastSeq = _lastTokenSeq[mid];
    final lastIndex = _lastTokenIndex[mid];
    if (seq != null && lastSeq != null && seq <= lastSeq) return;
    // Terminal frames may carry index 0 (or the next index) after higher
    // token indices, so the per-turn index check applies to deltas only.
    if (!terminal && index != null && lastIndex != null && index <= lastIndex) {
      return;
    }
    if (seq != null) _lastTokenSeq[mid] = seq;
    if (index != null) _lastTokenIndex[mid] = index;
    if (terminal && mid.isNotEmpty) {
      _finalizedMessageIds.add(mid);
      _finalizedMessageOrder.add(mid);
      if (_finalizedMessageOrder.length > 200) {
        final oldest = _finalizedMessageOrder.removeAt(0);
        _finalizedMessageIds.remove(oldest);
        _lastTokenSeq.remove(oldest);
        _lastTokenIndex.remove(oldest);
      }
    }

    setState(() {
      // The delta always lands on the open bubble: a genuinely new turn
      // starts a new assistant bubble; otherwise the delta appends to it.
      // _messages.last is the open assistant bubble (the chat.send ack never
      // appends a message), so the delta text is written there.
      final newTurn =
          mid.isNotEmpty && _activeMessageId != null && _activeMessageId != mid;
      final firstTurn = !_assistantStreaming;
      if (firstTurn || newTurn) {
        _messages.add(_ChatMessage.assistant(''));
        _deltaBuffer.clear();
        _assistantStreaming = true;
      }
      if (mid.isNotEmpty) _activeMessageId = mid;
      if (delta.isNotEmpty) {
        _deltaBuffer.write(delta);
        final idx = _messages.length - 1;
        if (idx >= 0) {
          final last = _messages[idx];
          _messages[idx] = last.copyWith(text: _deltaBuffer.toString());
        }
      }
      if (terminal) {
        _assistantStreaming = false;
        _activeMessageId = null;
        _deltaBuffer.clear();
        if (failedTurn) {
          // Discard the failed turn's partial text and GenUI surfaces. The
          // user's own bubble is never touched.
          final idx = _lastAssistantIndex();
          if (idx != null) _messages.removeAt(idx);
        }
      }
    });
    if (terminal) {
      _composer.finishTurn();
      if (!failedTurn) _finishGenUiTurn();
    }
  }

  /// Parse the fully accumulated turn once: GenUI handles split JSON tokens.
  Future<void> _finishGenUiTurn() async {
    final index = _lastAssistantIndex() ?? -1;
    if (index < 0 || _messages[index].isUser) return;
    final target = _messages[index];
    final output = target.text;
    if (output.isEmpty || target.surfaceIds.isNotEmpty || target.genUiFailed) {
      return;
    }
    final turn = await _parseGenUi(output);
    if (!mounted ||
        index >= _messages.length ||
        _messages.last.isUser ||
        _messages[index].text != output) {
      return;
    }
    setState(() {
      _messages[index] = target.copyWith(
        text: turn.text,
        surfaceIds: turn.surfaceIds,
        genUiFailed: turn.failed,
      );
    });
  }

  /// Decode `emotion.tag` defensively: only a well-typed tag/kind/intensity
  /// becomes a cue. `motion`/`vfx` stay cues but are never facial emotions.
  static _EmotionCue? _decodeEmotionCue(Map<String, dynamic> data) {
    final rawTag = data['tag'];
    final rawKind = data['kind'];
    final rawIntensity = data['intensity'];
    if (rawTag is! String || rawTag.trim().isEmpty) return null;
    if (rawKind is! String ||
        !const <String>{'emotion', 'motion', 'vfx'}.contains(rawKind)) {
      return null;
    }
    if (rawIntensity is! num || !rawIntensity.isFinite) return null;
    final rawActor = data['actor_id'];
    final rawSeq = data['seq'];
    final rawTs = data['ts_ms'];
    return _EmotionCue(
      tag: rawTag,
      kind: rawKind,
      intensity: rawIntensity.toDouble().clamp(0.0, 1.0),
      actorId: rawActor is String ? rawActor : '',
      seq: rawSeq is int ? rawSeq : null,
      tsMs: rawTs is int ? rawTs : null,
    );
  }

  /// Stop the in-flight turn via the daemon's `chat.cancel` verb.
  Future<void> _stop() async {
    final cancelled = await _composer.stopGeneration();
    if (!mounted || !cancelled) return;
    setState(() {
      _assistantStreaming = false;
      _activeMessageId = null;
      _deltaBuffer.clear();
    });
  }

  /// The composer's two-state button: Stop while a turn is open, Send
  /// otherwise (`WhisperComposerBar.onSubmit`).
  void _onSubmit() {
    if (_composer.showStop) {
      unawaited(_stop());
      return;
    }
    unawaited(_composer.handleSend());
  }

  /// Replay prior turns when a session is opened. Missing history (empty
  /// session) and an unregistered/failing `chat.history` are both non-fatal:
  /// the user can still chat, the screen just starts empty.
  Future<void> _loadHistory() async {
    final sid = _composer.sessionId;
    if (sid == null || sid.isEmpty) return;
    try {
      final page = await widget.client.chatHistoryPage(sid);
      final messages = await Future.wait(page.items.map(_messageFromHistory));
      if (!mounted) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(messages.toList());
        _historyCursor = page.nextCursor;
        _historyUnavailable = false;
      });
    } on DaemonClientException {
      if (!mounted) return;
      setState(() => _historyUnavailable = true);
    }
  }

  /// Append the next (older) history page ahead of the loaded transcript.
  Future<void> _loadOlderHistory() async {
    final sid = _composer.sessionId;
    final cursor = _historyCursor;
    if (sid == null || sid.isEmpty || cursor == null || _historyLoading) {
      return;
    }
    setState(() => _historyLoading = true);
    try {
      final page = await widget.client.chatHistoryPage(sid, cursor: cursor);
      // Older turns go above the current transcript; newest pages are loaded
      // first, so they are prepended in their existing oldest-first order.
      final messages = await Future.wait(page.items.map(_messageFromHistory));
      if (!mounted) return;
      final existing = _messages.toList();
      final older = messages.toList();
      setState(() {
        _historyCursor = page.nextCursor;
        _messages
          ..clear()
          ..addAll(older)
          ..addAll(existing);
      });
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _contextError = e.message);
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _loadContext() async {
    try {
      final results = await Future.wait<List<Map<String, dynamic>>>(
        <Future<List<Map<String, dynamic>>>>[
          widget.client.sessionsList(),
          widget.client.cardsList(),
        ],
      );
      if (!mounted) return;
      setState(() {
        _sessions = results[0];
        _cards = results[1];
        _selectedCardId ??= _cards.isEmpty
            ? null
            : (_cards.first['id'] as String?);
        _contextError = null;
        _cardMetadata = null;
        _metadataError = null;
        _metadataBusy = false;
      });
      unawaited(_loadCardMetadata(_selectedCardId));
    } on Object catch (e) {
      if (mounted) {
        setState(
          () => _contextError = e is DaemonClientException
              ? e.message
              : 'Could not load chat context: $e',
        );
      }
    }
  }

  Future<void> _loadCardMetadata(String? id) async {
    if (id == null || id.isEmpty) {
      if (mounted) {
        setState(() {
          _cardMetadata = null;
          _metadataError = null;
          _metadataBusy = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _metadataBusy = true;
        _metadataError = null;
      });
    }
    try {
      final data = await widget.client.cardsMetadata(id);
      if (!mounted) return;
      setState(() {
        _cardMetadata = data;
        _metadataBusy = false;
      });
    } on DaemonClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _metadataError = e.message;
        _metadataBusy = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _metadataError = 'Could not load card metadata: $e';
        _metadataBusy = false;
      });
    }
  }

  Future<void> _setCardMetadata({
    required bool liked,
    required bool bookmarked,
  }) async {
    final id = _selectedCardId;
    if (id == null || id.isEmpty) {
      return;
    }
    if (mounted) {
      setState(() {
        _metadataBusy = true;
        _metadataError = null;
      });
    }
    try {
      final data = await widget.client.cardsMetadataSet(
        id,
        liked: liked,
        bookmarked: bookmarked,
      );
      if (!mounted) return;
      setState(() {
        _cardMetadata = data;
        _metadataBusy = false;
      });
    } on DaemonClientException catch (e) {
      if (!mounted) return;
      setState(() {
        _metadataError = e.message;
        _metadataBusy = false;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() {
        _metadataError = 'Could not update card metadata: $e';
        _metadataBusy = false;
      });
    }
  }

  void _resetTranscript() {
    _messages.clear();
    _deltaBuffer.clear();
    _activeMessageId = null;
    _assistantStreaming = false;
    _historyUnavailable = false;
    _cue = null;
    _cueSeqByActor.clear();
    _lastTokenSeq.clear();
    _lastTokenIndex.clear();
    _finalizedMessageIds.clear();
    _finalizedMessageOrder.clear();
  }

  void _startNewSession() {
    _resetTranscript();
    _composer.sessionId = null;
    setState(() => _sessionPanelOpen = false);
  }

  Future<void> _openSession(String id) async {
    if (id.isEmpty || id == _composer.sessionId) {
      setState(() => _sessionPanelOpen = false);
      return;
    }
    setState(() {
      _resetTranscript();
      _composer.sessionId = id;
      _sessionPanelOpen = false;
    });
    await _loadHistory();
  }

  Future<void> _manageSessions() async {
    setState(() => _sessionPanelOpen = false);
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SessionsScreen(client: widget.client),
      ),
    );
    if (mounted) await _loadContext();
  }

  Future<_ChatMessage> _messageFromHistory(Map<String, dynamic> turn) async {
    final text = (turn['content'] as String?) ?? '';
    if (turn['role'] == 'user') return _ChatMessage.user(text);
    // Persisted assistant turns are already final: parse their full text so
    // replayed sessions show the same dynamic widgets as a live turn.
    final parsed = await _parseGenUi(text);
    return _ChatMessage.assistant(
      parsed.text,
      surfaceIds: parsed.surfaceIds,
      genUiFailed: parsed.failed,
    );
  }

  int? _lastAssistantIndex() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (!_messages[i].isUser) return i;
    }
    return null;
  }

  Future<AiriGenUiTurn> _parseGenUi(String output) async {
    try {
      return await _genUi.parseTurn(output);
    } on Object {
      return AiriGenUiTurn(
        text: output,
        surfaceIds: const <String>[],
        failed: true,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _composer,
      builder: (context, _) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final sending = _composer.isComposing;
    final error = _composer.error;
    return Material(
      child: Column(
        children: <Widget>[
          Column(
            children: <Widget>[
              Padding(
                key: const Key('chat-context-bar'),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: <Widget>[
                    IconButton(
                      key: const Key('chat-sessions-button'),
                      icon: const Icon(Icons.forum_outlined),
                      tooltip: 'Sessions',
                      onPressed: () => setState(
                        () => _sessionPanelOpen = !_sessionPanelOpen,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _composer.sessionId == null
                            ? 'New chat'
                            : 'Session ${_composer.sessionId}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    DropdownButton<String?>(
                      key: const Key('chat-character-dropdown'),
                      value: _selectedCardId,
                      hint: const Text('Character'),
                      items: <DropdownMenuItem<String?>>[
                        const DropdownMenuItem<String?>(
                          value: null,
                          child: Text('No character'),
                        ),
                        for (final card in _cards)
                          DropdownMenuItem<String?>(
                            value: card['id'] as String?,
                            child: Text(
                              (card['name'] as String?) ??
                                  (card['id'] as String?) ??
                                  '',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        setState(() => _selectedCardId = value);
                        unawaited(_loadCardMetadata(value));
                      },
                    ),
                  ],
                ),
              ),
              if (_selectedCardId != null && _cardMetadata != null)
                Padding(
                  key: const Key('chat-character-metadata'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        key: const Key('chat-character-liked'),
                        icon: Icon(
                          _cardMetadata!.liked
                              ? Icons.favorite
                              : Icons.favorite_border,
                        ),
                        tooltip: 'Liked',
                        onPressed: _metadataBusy
                            ? null
                            : () => unawaited(
                                _setCardMetadata(
                                  liked: !_cardMetadata!.liked,
                                  bookmarked: _cardMetadata!.bookmarked,
                                ),
                              ),
                      ),
                      IconButton(
                        key: const Key('chat-character-bookmarked'),
                        icon: Icon(
                          _cardMetadata!.bookmarked
                              ? Icons.bookmark
                              : Icons.bookmark_border,
                        ),
                        tooltip: 'Bookmarked',
                        onPressed: _metadataBusy
                            ? null
                            : () => unawaited(
                                _setCardMetadata(
                                  liked: _cardMetadata!.liked,
                                  bookmarked: !_cardMetadata!.bookmarked,
                                ),
                              ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _cardMetadata!.liked ? 'Liked' : 'Not liked',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_metadataBusy)
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                    ],
                  ),
                ),
              if (_sessionPanelOpen)
                SizedBox(
                  height: 200,
                  child: ListView(
                    children: <Widget>[
                      ListTile(
                        key: const Key('chat-new-session'),
                        leading: const Icon(Icons.add),
                        title: const Text('New chat'),
                        onTap: _startNewSession,
                      ),
                      for (final s in _sessions)
                        ListTile(
                          title: Text(
                            (s['title'] as String?) ??
                                (s['id'] as String?) ??
                                '',
                          ),
                          subtitle: Text((s['id'] as String?) ?? ''),
                          onTap: () => unawaited(
                            _openSession((s['id'] as String?) ?? ''),
                          ),
                        ),
                      ListTile(
                        key: Key('chat-manage-sessions'),
                        leading: Icon(Icons.settings_outlined),
                        title: Text('Manage sessions'),
                        onTap: _manageSessions,
                      ),
                    ],
                  ),
                ),
              if (_contextError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Text(
                    _contextError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (_metadataError != null)
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 4,
                  ),
                  child: Text(
                    _metadataError!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _messages.length + (_historyCursor == null ? 0 : 1),
              itemBuilder: (context, index) {
                if (index == 0 && _historyCursor != null) {
                  return Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: TextButton(
                      key: const Key('chat-load-older-history'),
                      onPressed: _historyLoading ? null : _loadOlderHistory,
                      child: Text(
                        _historyLoading ? 'Loading older…' : 'Load older messages',
                      ),
                    ),
                  );
                }
                final messageIndex = index - (_historyCursor == null ? 0 : 1);
                final m = _messages[messageIndex];
                // Assistant markers are stripped only for display: `m.text`
                // stays raw so GenUI parsing in `_finishGenUiTurn` sees the
                // full turn. Literally typed user text is left untouched.
                final displayed = m.isUser ? m.text : stripMarkers(m.text);
                return Align(
                  alignment: m.isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Card(
                    color: m.isUser
                        ? AppTheme.subtle.withOpacity(0.2)
                        : AppTheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(displayed.isEmpty ? '…' : displayed),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: Key('chat-copy-$messageIndex'),
                              icon: const Icon(Icons.copy_all_outlined, size: 18),
                              tooltip: 'Copy',
                              onPressed: () => Clipboard.setData(
                                ClipboardData(text: displayed),
                              ),
                            ),
                          ),
                          for (final surfaceId in m.surfaceIds)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: _genUi.surfaceWidget(surfaceId),
                            ),
                          if (m.genUiFailed && m.surfaceIds.isEmpty)
                            const Padding(
                              padding: EdgeInsets.only(top: 8),
                              child: Text(
                                'A dynamic widget could not be displayed.',
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(
                error,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (_cue != null)
            Padding(
              key: const Key('emotion-cue'),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Row(
                children: <Widget>[
                  const Icon(Icons.emoji_emotions_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(_cue!.label),
                        Text(
                          'Intensity ${(_cue!.intensity * 100).round()}% · '
                          'seq ${_cue!.seq ?? '?'} · ts ${_cue!.tsMs ?? '?'}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  SizedBox(
                    width: 56,
                    child: LinearProgressIndicator(value: _cue!.intensity),
                  ),
                ],
              ),
            ),
          if (_historyUnavailable)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Text('Chat history unavailable for this session.'),
            ),
          if (_composer.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Wrap(
                spacing: 8,
                children: <Widget>[
                  for (var i = 0; i < _composer.attachments.length; i++)
                    Chip(
                      key: Key('chat-attachment-$i'),
                      label: Text(_composer.attachments[i].url),
                      onDeleted: () => _composer.removeAttachmentAt(i),
                    ),
                ],
              ),
            ),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: TextField(
                      controller: _composer.input,
                      enabled: !sending,
                      decoration: const InputDecoration(hintText: 'Message'),
                      onSubmitted: (_) => _onSubmit(),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    onPressed: _onSubmit,
                    icon: sending
                        ? const Icon(Icons.stop)
                        : const Icon(Icons.send),
                    tooltip: sending ? 'Stop' : 'Send',
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmotionCue {
  const _EmotionCue({
    required this.tag,
    required this.kind,
    required this.intensity,
    required this.actorId,
    this.seq,
    this.tsMs,
  });

  final String tag;
  final String kind;
  final double intensity;
  final String actorId;
  final int? seq;
  final int? tsMs;

  String get label {
    final className = switch (kind) {
      'motion' => 'Motion',
      'vfx' => 'VFX',
      _ => 'Emotion',
    };
    final actor = actorId.isEmpty ? '' : ' · $actorId';
    return '$className cue: $tag$actor';
  }
}

class _ChatMessage {
  const _ChatMessage({
    required this.isUser,
    required this.text,
    this.surfaceIds = const <String>[],
    this.genUiFailed = false,
  });

  factory _ChatMessage.user(String t) => _ChatMessage(isUser: true, text: t);
  factory _ChatMessage.assistant(
    String t, {
    List<String> surfaceIds = const <String>[],
    bool genUiFailed = false,
  }) => _ChatMessage(
    isUser: false,
    text: t,
    surfaceIds: surfaceIds,
    genUiFailed: genUiFailed,
  );

  final bool isUser;
  final String text;
  final List<String> surfaceIds;
  final bool genUiFailed;

  _ChatMessage copyWith({
    String? text,
    List<String>? surfaceIds,
    bool? genUiFailed,
  }) => _ChatMessage(
    isUser: isUser,
    text: text ?? this.text,
    surfaceIds: surfaceIds ?? this.surfaceIds,
    genUiFailed: genUiFailed ?? this.genUiFailed,
  );
}
