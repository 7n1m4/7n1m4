// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'chat_feed_event.dart';
import 'chat_feed_port.dart';

/// Consumes a [ChatFeedPort], buffering out-of-order frames so the feed is
/// rendered only up to the highest contiguous sequence number.
///
/// The controller never touches the wire: it receives already-decoded frames
/// and derives ordered tokens plus the currently open gap.
class ChatFeedController extends ChangeNotifier {
  ChatFeedController(this._port) {
    _subscription = _port.events.listen(
      _onEvent,
      onError: (Object error, StackTrace stackTrace) => _finish(),
      onDone: _finish,
    );
  }

  /// Largest forward jump accepted in one frame, so gap scanning stays bounded.
  static const int maxForwardJump = 1000;

  final ChatFeedPort _port;
  StreamSubscription<ChatFeedEvent>? _subscription;

  final Map<int, String> _buffer = <int, String>{};
  final List<ChatFeedToken> _ordered = <ChatFeedToken>[];
  int? _nextExpected;
  int? _highWater;
  ChatFeedGap? _gap;
  bool _terminal = false;

  /// Tokens rendered so far, in strict sequence order.
  List<ChatFeedToken> get orderedTokens =>
      List<ChatFeedToken>.unmodifiable(_ordered);

  /// Contiguous text rendered so far; buffered frames past a gap are excluded.
  String get renderedText => _ordered.map((token) => token.text).join();

  /// The open gap, or null while rendering is contiguous or the feed ended.
  ChatFeedGap? get gap => _gap;

  /// Whether the feed ended by error or close; no further frames are accepted.
  bool get isTerminal => _terminal;

  void _onEvent(ChatFeedEvent event) {
    if (_terminal) return;
    // Only decoded frames carry renderable payloads. Malformed frames (no
    // positive sequence, no payload) are dropped before any state changes.
    if (event is! ChatFeedFrame) return;
    final seq = event.seq;
    if (seq < 1 || event.text.isEmpty) return;

    final expected = _nextExpected;
    // Reject implausible jumps before touching _highWater: gap scanning walks
    // every seq up to the high-water mark, so an unbounded jump is a DoS.
    if (seq > (expected ?? 1) + maxForwardJump) return;

    final highWater = _highWater;
    if (highWater == null || seq > highWater) _highWater = seq;

    if (expected == null) {
      _accept(seq, event.text);
      _publish();
      return;
    }

    // Already-rendered or already-buffered seq: a duplicate or a late replay
    // must not fabricate a second token.
    if (seq < expected || _buffer.containsKey(seq)) {
      _publish();
      return;
    }

    if (seq > expected) {
      _buffer[seq] = event.text;
      _publish();
      return;
    }

    // seq == expected: render it, then drain any buffered run that follows.
    _accept(seq, event.text);
    _drainBuffer();
    _publish();
  }

  void _accept(int seq, String text) {
    _ordered.add(ChatFeedToken(seq, text));
    _nextExpected = seq + 1;
  }

  void _drainBuffer() {
    while (true) {
      final expected = _nextExpected;
      if (expected == null) return;
      final buffered = _buffer.remove(expected);
      if (buffered == null) return;
      _accept(expected, buffered);
    }
  }

  void _publish() {
    final expected = _nextExpected;
    final highWater = _highWater;
    if (expected == null || highWater == null || highWater < expected) {
      _gap = null;
    } else {
      final missing = <int>[];
      for (var seq = expected; seq <= highWater; seq++) {
        if (!_buffer.containsKey(seq)) missing.add(seq);
      }
      _gap = missing.isEmpty ? null : ChatFeedGap(missing);
    }
    notifyListeners();
  }

  /// Terminal signal: drop the unresolved gap instead of leaving the indicator
  /// stuck forever. Rendered text is kept, never extended with buffered data.
  void _finish() {
    if (_terminal) return;
    _terminal = true;
    _gap = null;
    _buffer.clear();
    notifyListeners();
  }

  @override
  void dispose() {
    _subscription?.cancel();
    super.dispose();
  }
}
