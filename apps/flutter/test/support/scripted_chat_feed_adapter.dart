// SPDX-License-Identifier: GPL-3.0-or-later

// Test/dev-only producer for the UI-owned chat feed seam. Every frame below is
// already decoded; this adapter never builds, parses or mints a wire envelope,
// and it has no dependency on the quarantined transport seam.

import 'dart:async';

import 'package:anima_control/features/chat/feed/chat_feed_event.dart';
import 'package:anima_control/features/chat/feed/chat_feed_port.dart';

/// Deterministic pre-decoded script: 1, 2, a jump to 4 (3 missing), then a
/// replay of 3. Ordered payloads concatenate to "Hello brave world!".
class ScriptedChatFeedAdapter implements ChatFeedPort {
  static const List<ChatFeedFrame> script = <ChatFeedFrame>[
    ChatFeedFrame(seq: 1, text: 'Hello '),
    ChatFeedFrame(seq: 2, text: 'brave '),
    ChatFeedFrame(seq: 4, text: '!'),
    ChatFeedFrame(seq: 3, text: 'world'),
  ];

  // Synchronous delivery keeps each emitted frame observable by a single pump.
  final StreamController<ChatFeedEvent> _controller =
      StreamController<ChatFeedEvent>(sync: true);

  int _cursor = 0;
  bool _closed = false;

  @override
  Stream<ChatFeedEvent> get events => _controller.stream;

  /// Hands over the next scripted frame. Returns false once the script is done.
  bool emitNext() {
    if (_cursor >= script.length) return false;
    _controller.add(script[_cursor++]);
    return true;
  }

  /// Hands over an arbitrary decoded frame, for injecting failure-mode cases.
  void emit(ChatFeedEvent event) => _controller.add(event);

  /// Injects a terminal error, for testing terminal state handling.
  void fail(Object error) => _controller.addError(error);

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}
