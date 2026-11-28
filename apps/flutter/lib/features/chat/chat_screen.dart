// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as md;

import '../../daemon_client/daemon_client.dart';
import '../../theme/app_theme.dart';
import 'chat_composer_controller.dart';
import 'chat_message_display.dart';
import 'genui_surface_controller.dart';
import '../sessions/sessions_screen.dart';

/// A live turn or a user paste can end with an unterminated code fence.
/// GitHub-flavored markdown would render every following line as code, hiding
/// trailing prose. Close such a fence right after its opener so only genuinely
/// fenced content is treated as code.
String _balanceCodeFences(String text) {
  // Dart's RegExp `.` and `$` do not see a trailing `\r`, so normalize before
  // matching: a `\r\n` fence would otherwise never be recognized.
  var lines = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  // One pass closes a single unterminated fence; a later stray fence only
  // becomes visible once the earlier one is closed. Each pass inserts one
  // line, so the number of passes is bounded by the number of lines.
  for (var pass = 0; pass <= lines.length; pass++) {
    final balanced = _closeFirstUnterminatedFence(lines);
    if (balanced == null) break;
    lines = balanced;
  }
  return lines.join('\n');
}

/// Markdown permits 0-3 leading spaces on any fence line, so only the number
/// of blockquote markers has to match between an opener and its closer.
int _quoteDepth(String prefix) => prefix.split('>').length - 1;

/// Returns [lines] with one synthetic closer inserted, or `null` when every
/// fence is already matched.
List<String>? _closeFirstUnterminatedFence(List<String> lines) {
  // Mirrors markdown 7.3.1's `codeFencePattern`: a backtick info string may
  // not contain backticks, while a tilde info string may contain anything.
  // Leading blockquote markers are part of the prefix so a quoted fence gets
  // a quoted closer.
  final fence = RegExp(
    r'^((?:[ ]{0,3}>[ ]?)*[ ]{0,3})(?:(`{3,})([^`]*)|(~{3,})(.*))$',
  );
  String? opener;
  String? quote;
  var openerLine = -1;

  for (var i = 0; i < lines.length; i++) {
    final match = fence.firstMatch(lines[i]);
    if (match == null) continue;
    final prefix = match.group(1)!;
    final backticks = match.group(2);
    final marker = backticks ?? match.group(4)!;
    final info = (backticks != null ? match.group(3)! : match.group(5)!).trim();
    if (opener == null) {
      opener = marker;
      quote = prefix;
      openerLine = i;
      continue;
    }
    // The parser closes a fence with a bare marker of the same character and
    // at least the opener's length, at the same blockquote depth. Leading
    // spaces are allowed on the closer and must not break the pairing.
    if (info.isEmpty &&
        _quoteDepth(prefix) == _quoteDepth(quote!) &&
        marker.startsWith(opener)) {
      opener = null;
      quote = null;
      openerLine = -1;
    }
  }
  if (opener == null) return null;
  final out = List<String>.of(lines);
  out.insert(openerLine + 1, '$quote$opener');
  return out;
}

/// Minimal chat surface: sends `chat.send` RPCs and renders streamed
/// `token.delta` events. View state only; the daemon owns sessions.
///
/// Draft, send/stop state and `chat.cancel` live in [ChatComposerController];
/// this widget owns the transcript, the delta reconciliation by `message_id`
/// and GenUI rehydration.
class ChatScreen extends StatefulWidget {
  const ChatScreen({
    super.key,
    required this.client,
    this.initialSessionId,
    DateTime Function()? now,
  }) : now = now ?? DateTime.now;

  /// Injected so the double-Enter window can be tested without wall-clock sleeps.
  final DateTime Function() now;

  final DaemonClient client;

  /// When opening a persisted session, its id is replayed via `chat.history`.
  final String? initialSessionId;

  @override
  State<ChatScreen> createState() => ChatScreenState();
}

/// Public so the navigation shell can call [reload] when the chat tab is
/// activated. The daemon owns sessions; this only re-reads its view caches.
class ChatScreenState extends State<ChatScreen> {
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
  final ScrollController _scrollController = ScrollController();
  static const double _bottomSlop = 16.0;
  // Sampled before a transcript mutation: by the time the post-frame callback
  // runs the content has grown, so geometry can no longer tell us whether the
  // user was pinned to the bottom when the append began.
  bool _isAtBottom = true;
  StreamSubscription<DaemonStatus>? _statusSub;
  void Function()? _unsubscribeEvent;
  int _contextReadGeneration = 0;
  int _historyReadGeneration = 0;
  int _metadataReadGeneration = 0;
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
  // Wall-clock of the first plain Enter in double-enter mode. Reset on send so
  // a later single Enter cannot inherit the previous turn's timestamp.
  int _lastComposerEnterMs = 0;

  /// Session the composer currently targets. The shell reads this to bind
  /// stage captions to the active chat session; null means no session yet.
  String? get activeSessionId => _composer.sessionId;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _composer = ChatComposerController(
      client: widget.client,
      sessionId: widget.initialSessionId,
      onMessageCommitted: (text) {
        if (mounted) {
          final pinned = _isAtBottom;
          _followBottomIfPinned(pinned);
          setState(() => _messages.add(_ChatMessage.user(text)));
        }
      },
    );
    _unsubscribeEvent = widget.client.onEvent(_onEvent);
    _wasConnected = widget.client.snapshot.isConnected;
    if (_wasConnected) _requestEmotionEvents();
    // Only a real disconnect -> connected transition counts. The open turn
    // survives a reconnect (same message_id), so it is reconciled against
    // daemon history rather than reset: the terminal frame may have been lost
    // while offline even though the daemon completed the turn.
    _statusSub = widget.client.statusStream.listen((status) {
      final connected = status.state == DaemonConnectionState.connected;
      final regainedConnection = connected && !_wasConnected;
      _wasConnected = connected;
      if (regainedConnection) {
        _requestEmotionEvents();
        unawaited(_reconcileReconnectedTurn());
      }
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
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final p = _scrollController.position;
    _isAtBottom =
        p.pixels + p.viewportDimension >= p.maxScrollExtent - _bottomSlop;
  }

  /// Follow new content only when the user was pinned to the bottom when the
  /// append/finish began. [pinned] is sampled before the rebuild; re-deriving
  /// it from geometry here would see the already-grown content. Recheck the
  /// listener-driven flag instead: a scroll delivered before this callback
  /// clears it and cancels the follow.
  void _followBottomIfPinned(bool pinned) {
    if (!pinned) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      if (!_isAtBottom || !pinned) return;
      _scrollController.jumpTo(_scrollController.position.maxScrollExtent);
    });
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
    if (event.topic == EventTopic.settingsChanged) {
      _reloadOnSettingsChanged(event);
      return;
    }
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
    if (_composer.sessionId == null && sid.isNotEmpty) {
      _composer.sessionId = sid;
    }
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
    // newer turn. A turn closed by history reconciliation is finalized too: a
    // late delta for it must not open a second bubble with partial text.
    // Frames without seq/index (older daemons/fakes) bypass dedup.
    if (mid.isNotEmpty && _finalizedMessageIds.contains(mid)) return;
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
    if (terminal && mid.isNotEmpty) _rememberFinalizedMessage(mid);

    // The delta always lands on the open bubble: a genuinely new turn starts
    // a new assistant bubble, a terminal frame finishes the visible turn.
    // Sample the pin before the rebuild grows/changes the transcript.
    final newTurn =
        mid.isNotEmpty && _activeMessageId != null && _activeMessageId != mid;
    final firstTurn = !_assistantStreaming;
    final pinned = _isAtBottom;
    if (firstTurn || newTurn || terminal) _followBottomIfPinned(pinned);
    setState(() {
      // _messages.last is the open assistant bubble (the chat.send ack never
      // appends a message), so the delta text is written there.
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

  /// The event carries no values, only the changed section. Re-read the caches
  /// that section feeds; unrelated sections are none of this screen's business.
  void _reloadOnSettingsChanged(GatewayEventFrame event) {
    if (!mounted) return;
    final section = event.data['section'];
    if (section is! String) return;
    switch (section) {
      case 'cards':
        unawaited(reload());
      case 'chat':
      case 'chat-provider':
        unawaited(_composer.loadContextSettings());
    }
  }

  /// Re-read daemon-owned context and the open session's transcript. Called on
  /// chat-tab activation and on a relevant `settings.changed`; every read is
  /// generation-guarded so an older reply cannot overwrite a newer one.
  Future<void> reload() async {
    if (!mounted) return;
    // A streamed turn owns the last bubble; replaying history mid-turn would
    // overwrite it with already-persisted turns. Context is safe to refresh.
    if (_assistantStreaming) {
      await _loadContext();
      return;
    }
    await Future.wait<void>(<Future<void>>[_loadContext(), _loadHistory()]);
  }

  /// A lost terminal frame leaves Stop latched and a partial assistant bubble
  /// open although the daemon already persisted the completed turn. Re-read
  /// history once on reconnect and close the turn only when the page confirms
  /// the just-sent user turn now has a full assistant reply. This repairs view
  /// state only: message ids and the streaming contract stay daemon-owned.
  Future<void> _reconcileReconnectedTurn() async {
    final sid = _composer.sessionId;
    if (sid == null || sid.isEmpty) return;
    final startedStreaming = _assistantStreaming;
    final startedMid = _activeMessageId;
    final startedComposing = _composer.isComposing;
    final startedCount = _messages.length;
    if (!startedStreaming && !startedComposing) return;
    final sentText = _lastUserText();
    if (sentText == null || sentText.trim().isEmpty) return;

    final generation = ++_historyReadGeneration;
    ListPage<Map<String, dynamic>> page;
    try {
      page = await widget.client.chatHistoryPage(sid);
    } on Object {
      return; // An unreadable history says nothing about a live turn.
    }
    final unchanged = _transcriptUnchanged(
      generation: generation,
      sid: sid,
      streaming: startedStreaming,
      mid: startedMid,
      composing: startedComposing,
      messageCount: startedCount,
    );
    final turns = page.items;
    // Pair by row order, not content: an older identical user turn must not
    // answer the current one. Rows are oldest-first within the newest page.
    final userIndex = _lastHistoryUserIndex(turns);
    if (userIndex < 0 || turns[userIndex]['content'] != sentText) return;
    final persisted = _assistantAfter(turns, userIndex);
    final content = persisted?['content'];
    if (content is! String || content.trim().isEmpty) return;
    final historyId = persisted!['id'];
    final hasHistoryId = historyId is String && historyId.isNotEmpty;

    // A replayed terminal can land mid-read: its empty delta either opens a
    // blank bubble or leaves an existing partial one open. Fill that bubble
    // with the persisted reply instead of appending a second one.
    final openIndex = _lastAssistantIndex() ?? -1;
    if (!unchanged) {
      final isLastAssistant =
          openIndex >= 0 && openIndex == _messages.length - 1;
      final blankReplay =
          _messages.length == startedCount + 1 &&
          isLastAssistant &&
          _messages[openIndex].text.isEmpty;
      // Partial text was already on screen: the terminal adds no bubble.
      final partialReplay =
          _messages.length == startedCount &&
          isLastAssistant &&
          hasHistoryId &&
          historyId == startedMid &&
          _finalizedMessageIds.contains(historyId) &&
          _messages[openIndex].text.trim().isNotEmpty;
      final replayIsThisTurn =
          !hasHistoryId || _finalizedMessageIds.contains(historyId);
      if (!_readStillCurrent(generation, sid) ||
          _assistantStreaming ||
          _composer.isComposing ||
          !(blankReplay || partialReplay) ||
          !replayIsThisTurn) {
        return;
      }
    }

    final mid = _activeMessageId;
    if (mid != null && mid.isNotEmpty && !_finalizedMessageIds.contains(mid)) {
      _rememberFinalizedMessage(mid);
    }
    // The history row carries the same id as token.delta, so a late replay of
    // this turn is dropped by the finalized-id check before it opens a bubble.
    if (hasHistoryId && !_finalizedMessageIds.contains(historyId)) {
      _rememberFinalizedMessage(historyId);
    }
    final pinned = _isAtBottom;
    _followBottomIfPinned(pinned);
    setState(() {
      if (!unchanged || (startedStreaming && openIndex >= 0)) {
        // Replace the partial (or replay-opened blank) bubble in place.
        _messages[openIndex] = _messages[openIndex].copyWith(text: content);
      } else {
        _messages.add(_ChatMessage.assistant(content));
      }
      _assistantStreaming = false;
      _activeMessageId = null;
      _deltaBuffer.clear();
    });
    _composer.finishTurn();
    // GenUI rehydration is the same background parse a live final uses.
    unawaited(_finishGenUiTurn());
  }

  /// Last user bubble: the text the in-flight turn was sent with.
  String? _lastUserText() {
    for (var i = _messages.length - 1; i >= 0; i--) {
      if (_messages[i].isUser) return _messages[i].text;
    }
    return null;
  }

  /// Newest user row in a history page (rows are oldest-first).
  int _lastHistoryUserIndex(List<Map<String, dynamic>> turns) {
    for (var i = turns.length - 1; i >= 0; i--) {
      if (turns[i]['role'] == 'user') return i;
    }
    return -1;
  }

  /// Assistant row strictly after [userIndex]: only that can answer the turn.
  Map<String, dynamic>? _assistantAfter(
    List<Map<String, dynamic>> turns,
    int userIndex,
  ) {
    Map<String, dynamic>? newest;
    int newestAt = -1;
    for (var i = userIndex + 1; i < turns.length; i++) {
      final turn = turns[i];
      if (turn['role'] != 'assistant') continue;
      final raw = turn['createdAt'];
      final at = raw is int ? raw : -1;
      if (at >= newestAt) {
        newest = turn;
        newestAt = at;
      }
    }
    return newest;
  }

  void _rememberFinalizedMessage(String mid) {
    _finalizedMessageIds.add(mid);
    _finalizedMessageOrder.add(mid);
    if (_finalizedMessageOrder.length > 200) {
      final oldest = _finalizedMessageOrder.removeAt(0);
      _finalizedMessageIds.remove(oldest);
      _lastTokenSeq.remove(oldest);
      _lastTokenIndex.remove(oldest);
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
    // A reload or session switch can replace the transcript while the parse
    // is in flight. Both bump _historyReadGeneration; the session check also
    // catches a switch that did not need a history read.
    final generation = _historyReadGeneration;
    final sid = _composer.sessionId;
    final turn = await _parseGenUi(output);
    if (!_readStillCurrent(generation, sid) ||
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
    final pinned = _isAtBottom;
    _followBottomIfPinned(pinned);
    setState(() {
      _assistantStreaming = false;
      _activeMessageId = null;
      _deltaBuffer.clear();
    });
  }

  /// The composer's two-state button: Stop while a turn is open, Send
  /// otherwise (`WhisperComposerBar.onSubmit`).
  void _onSubmit() {
    // Any send (button, keyboard or a failed retry) clears a pending
    // double-Enter window so a later single Enter cannot commit a turn.
    _lastComposerEnterMs = 0;
    if (_composer.showStop) {
      unawaited(_stop());
      return;
    }
    unawaited(_composer.handleSend());
  }

  /// Composer key routing, mirroring `basic-text-area.vue:onKeyDown`.
  ///
  /// The enclosing [Focus] sees keys before `DefaultTextEditingShortcuts`, so
  /// [KeyEventResult.handled] suppresses the text field's default newline /
  /// cursor action while `ignored` lets it insert a newline.
  bool _handleComposerKey(KeyEvent event) {
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowUp) return _composer.recallPrevious();
    if (key == LogicalKeyboardKey.arrowDown) return _composer.recallNext();
    if (key != LogicalKeyboardKey.enter &&
        key != LogicalKeyboardKey.numpadEnter) {
      return false;
    }
    // A held Enter must not re-enter onSubmit: the first send makes the
    // button a Stop button, so a repeat would cancel the turn just started.
    if (event is KeyRepeatEvent) return false;

    // Any valid composing range means the IME owns Enter (the confirm
    // keystroke), matching `KeyboardEvent.isComposing` in the TS composer.
    final composing = _composer.input.value.composing;
    if (composing.isValid) return false;
    // This Flutter SDK's KeyEvent has no modifier getters, so the modifier
    // state comes from the keyboard (the TS reference reads it per event).
    // Shift+Enter is always a newline, in every send mode.
    final keyboard = HardwareKeyboard.instance;
    if (keyboard.isShiftPressed) return false;

    final hasPrimaryModifier =
        keyboard.isControlPressed || keyboard.isMetaPressed;
    final isPlainEnter = !hasPrimaryModifier;
    final mode = _composer.sendMode;
    final now = widget.now().millisecondsSinceEpoch;

    if (mode == ChatComposerController.defaultSendMode && isPlainEnter) {
      _onSubmit();
      return true;
    }
    if (mode == 'ctrl-enter' && hasPrimaryModifier) {
      _onSubmit();
      return true;
    }
    if (mode == 'double-enter' && isPlainEnter) {
      if (now - _lastComposerEnterMs <= 350) {
        _lastComposerEnterMs = 0;
        _onSubmit();
        return true;
      }
      _lastComposerEnterMs = now;
    }
    return false;
  }

  /// Replay prior turns when a session is opened. Missing history (empty
  /// session) and an unregistered/failing `chat.history` are both non-fatal:
  /// the user can still chat, the screen just starts empty.
  Future<void> _loadHistory() async {
    final sid = _composer.sessionId;
    if (sid == null || sid.isEmpty) return;
    // Only bump once there is a read to guard: a sessionless reload must not
    // invalidate an in-flight GenUI parse for the still-empty transcript.
    final generation = ++_historyReadGeneration;
    final startedStreaming = _assistantStreaming;
    final startedMid = _activeMessageId;
    final startedComposing = _composer.isComposing;
    final startedCount = _messages.length;
    bool stillCurrent() => _transcriptUnchanged(
      generation: generation,
      sid: sid,
      streaming: startedStreaming,
      mid: startedMid,
      composing: startedComposing,
      messageCount: startedCount,
    );
    try {
      final page = await widget.client.chatHistoryPage(sid);
      final messages = await Future.wait(page.items.map(_messageFromHistory));
      if (!stillCurrent()) return;
      setState(() {
        _messages
          ..clear()
          ..addAll(messages.toList());
        _historyCursor = page.nextCursor;
        _historyUnavailable = false;
      });
    } on DaemonClientException {
      if (!stillCurrent()) return;
      setState(() => _historyUnavailable = true);
    }
  }

  /// True only while the generation/session that started a read still owns
  /// the transcript. Reloads and session switches bump the generation; a
  /// switch also changes the session id even when no history read is needed.
  bool _readStillCurrent(int generation, String? sid) =>
      mounted &&
      generation == _historyReadGeneration &&
      _composer.sessionId == sid;

  /// Also refuse a late read result when a send or stream mutated the
  /// transcript while its RPC and GenUI parses were in flight.
  bool _transcriptUnchanged({
    required int generation,
    required String? sid,
    required bool streaming,
    required String? mid,
    required bool composing,
    required int messageCount,
  }) =>
      _readStillCurrent(generation, sid) &&
      _assistantStreaming == streaming &&
      _activeMessageId == mid &&
      _composer.isComposing == composing &&
      _messages.length == messageCount;

  /// Append the next (older) history page ahead of the loaded transcript.
  Future<void> _loadOlderHistory() async {
    final sid = _composer.sessionId;
    final cursor = _historyCursor;
    if (sid == null || sid.isEmpty || cursor == null || _historyLoading) {
      return;
    }
    final generation = _historyReadGeneration;
    setState(() => _historyLoading = true);
    try {
      final page = await widget.client.chatHistoryPage(sid, cursor: cursor);
      // Older turns go above the current transcript; newest pages are loaded
      // first, so they are prepended in their existing oldest-first order.
      final messages = await Future.wait(page.items.map(_messageFromHistory));
      if (!_readStillCurrent(generation, sid)) return;
      final existing = _messages.toList();
      final older = messages.toList();
      // Prepending grows the content above the viewport. Capture the current
      // geometry before the rebuild, then shift the offset by that growth so
      // the same rows stay under the user's eyes (history.vue loadMore).
      final controller = _scrollController;
      final hadClient = controller.hasClients;
      final oldExtent = hadClient ? controller.position.maxScrollExtent : 0.0;
      final oldOffset = hadClient ? controller.offset : 0.0;
      setState(() {
        _historyCursor = page.nextCursor;
        _messages
          ..clear()
          ..addAll(older)
          ..addAll(existing);
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_readStillCurrent(generation, sid) || !controller.hasClients) {
          return;
        }
        final delta = controller.position.maxScrollExtent - oldExtent;
        if (delta > 0) controller.jumpTo(oldOffset + delta);
      });
    } on DaemonClientException catch (e) {
      if (_readStillCurrent(generation, sid)) {
        setState(() => _contextError = e.message);
      }
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _loadContext() async {
    final generation = ++_contextReadGeneration;
    try {
      final results = await Future.wait<List<Map<String, dynamic>>>(
        <Future<List<Map<String, dynamic>>>>[
          widget.client.sessionsList(),
          widget.client.cardsList(),
        ],
      );
      if (!mounted || generation != _contextReadGeneration) return;
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
      if (!mounted || generation != _contextReadGeneration) return;
      setState(
        () => _contextError = e is DaemonClientException
            ? e.message
            : 'Could not load chat context: $e',
      );
    }
  }

  Future<void> _loadCardMetadata(String? id) async {
    final generation = ++_metadataReadGeneration;
    if (id == null || id.isEmpty) {
      if (mounted && generation == _metadataReadGeneration) {
        setState(() {
          _cardMetadata = null;
          _metadataError = null;
          _metadataBusy = false;
        });
      }
      return;
    }
    if (mounted && generation == _metadataReadGeneration) {
      setState(() {
        _metadataBusy = true;
        _metadataError = null;
      });
    }
    try {
      final data = await widget.client.cardsMetadata(id);
      if (!mounted || generation != _metadataReadGeneration) return;
      setState(() {
        _cardMetadata = data;
        _metadataBusy = false;
      });
    } on DaemonClientException catch (e) {
      if (!mounted || generation != _metadataReadGeneration) return;
      setState(() {
        _metadataError = e.message;
        _metadataBusy = false;
      });
    } on Object catch (e) {
      if (!mounted || generation != _metadataReadGeneration) return;
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
    ++_historyReadGeneration;
    _lastComposerEnterMs = 0;
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
    final rawCreatedAt = turn['createdAt'];
    // DateTime throws on out-of-range epochs; malformed history must not
    // break the build. Daemon stamps positive ms, so bound to that range.
    const maxEpochMs = 8640000000000000;
    final createdAt =
        rawCreatedAt is int && rawCreatedAt > 0 && rawCreatedAt <= maxEpochMs
        ? rawCreatedAt
        : null;
    if (turn['role'] == 'user') {
      return _ChatMessage.user(text, createdAt: createdAt);
    }
    // Persisted assistant turns are already final: parse their full text so
    // replayed sessions show the same dynamic widgets as a live turn.
    final parsed = await _parseGenUi(text);
    return _ChatMessage.assistant(
      parsed.text,
      surfaceIds: parsed.surfaceIds,
      genUiFailed: parsed.failed,
      createdAt: createdAt,
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
                        key: const Key('chat-manage-sessions'),
                        leading: const Icon(Icons.settings_outlined),
                        title: const Text('Manage sessions'),
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
              controller: _scrollController,
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
                        _historyLoading
                            ? 'Loading older…'
                            : 'Load older messages',
                      ),
                    ),
                  );
                }
                final messageIndex = index - (_historyCursor == null ? 0 : 1);
                final m = _messages[messageIndex];
                // Assistant markers are stripped only for display: `m.text`
                // stays raw so GenUI parsing in `_finishGenUiTurn` sees the
                // full turn. Both sides get display-only fence balancing;
                // literally typed user text is never rewritten in storage.
                final displayed = _balanceCodeFences(
                  m.isUser ? m.text : stripMarkers(m.text),
                );
                return Align(
                  alignment: m.isUser
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Card(
                    color: m.isUser
                        ? AppTheme.subtle.withValues(alpha: 0.2)
                        : AppTheme.surface,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          MarkdownBody(
                            data: displayed.isEmpty ? '…' : displayed,
                            extensionSet: md.ExtensionSet.gitHubFlavored,
                            // Assistant text is untrusted: never fetch remote
                            // images from it (IP leak / tracking / probing).
                            imageBuilder: (_, __, alt) => Text(alt ?? ''),
                          ),
                          // Only history turns carry a createdAt; streamed and
                          // just-sent bubbles stay timestamp-free.
                          if (m.createdAt != null)
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                // The app declares only Locale('en'); intl has
                                // no bare 'en' date data, so use the format the
                                // Vue reference uses for en-US.
                                DateFormat.jm('en_US').format(
                                  DateTime.fromMillisecondsSinceEpoch(
                                    m.createdAt!,
                                  ),
                                ),
                                key: Key('chat-timestamp-$messageIndex'),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                            ),
                          Align(
                            alignment: Alignment.centerRight,
                            child: IconButton(
                              key: Key('chat-copy-$messageIndex'),
                              icon: const Icon(
                                Icons.copy_all_outlined,
                                size: 18,
                              ),
                              tooltip: 'Copy source',
                              // Copy the source, not the fence-balanced
                              // display: synthetic closers are not authored
                              // by the model (or the user).
                              onPressed: () => Clipboard.setData(
                                ClipboardData(
                                  text: m.isUser
                                      ? m.text
                                      : stripMarkers(m.text),
                                ),
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
                    // Local Focus so recall keys are consumed only while the
                    // composer has focus and a later generic Shortcuts/Focus
                    // wrapper can still compose around it.
                    child: Focus(
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent &&
                            event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        return _handleComposerKey(event)
                            ? KeyEventResult.handled
                            : KeyEventResult.ignored;
                      },
                      child: TextField(
                        controller: _composer.input,
                        enabled: !sending,
                        maxLines: null,
                        decoration: const InputDecoration(hintText: 'Message'),
                      ),
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
    this.createdAt,
  });

  factory _ChatMessage.user(String t, {int? createdAt}) =>
      _ChatMessage(isUser: true, text: t, createdAt: createdAt);
  factory _ChatMessage.assistant(
    String t, {
    List<String> surfaceIds = const <String>[],
    bool genUiFailed = false,
    int? createdAt,
  }) => _ChatMessage(
    isUser: false,
    text: t,
    surfaceIds: surfaceIds,
    genUiFailed: genUiFailed,
    createdAt: createdAt,
  );

  final bool isUser;
  final String text;
  final List<String> surfaceIds;
  final bool genUiFailed;
  final int? createdAt;

  _ChatMessage copyWith({
    String? text,
    List<String>? surfaceIds,
    bool? genUiFailed,
  }) => _ChatMessage(
    isUser: isUser,
    text: text ?? this.text,
    surfaceIds: surfaceIds ?? this.surfaceIds,
    genUiFailed: genUiFailed ?? this.genUiFailed,
    createdAt: createdAt,
  );
}
