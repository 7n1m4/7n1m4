// SPDX-License-Identifier: GPL-3.0-or-later

// UI-owned, immutable value objects for the chat feed. They describe already
// decoded frames and derived render state; nothing here builds, parses or
// mints a wire envelope.

/// Base marker for values that flow through the UI-owned chat feed seam.
sealed class ChatFeedEvent {
  const ChatFeedEvent();
}

/// One already-decoded, numbered frame carrying a token payload.
class ChatFeedFrame extends ChatFeedEvent {
  const ChatFeedFrame({
    required this.seq,
    required this.text,
    this.isFinal = false,
  });

  final int seq;
  final String text;
  final bool isFinal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatFeedFrame &&
          other.seq == seq &&
          other.text == text &&
          other.isFinal == isFinal;

  @override
  int get hashCode => Object.hash(seq, text, isFinal);

  @override
  String toString() =>
      'ChatFeedFrame(seq: $seq, text: $text, isFinal: $isFinal)';
}

/// A token placed at its ordered position in the rendered feed.
class ChatFeedToken extends ChatFeedEvent {
  const ChatFeedToken(this.seq, this.text);

  final int seq;
  final String text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ChatFeedToken && other.seq == seq && other.text == text;

  @override
  int get hashCode => Object.hash(seq, text);

  @override
  String toString() => 'ChatFeedToken(seq: $seq, text: $text)';
}

/// Missing sequence numbers blocking contiguous rendering of the feed.
class ChatFeedGap extends ChatFeedEvent {
  ChatFeedGap(Iterable<int> missingSeqs)
    : _missingSeqs = List<int>.unmodifiable(missingSeqs.toList()..sort());

  final List<int> _missingSeqs;

  /// Sorted, unmodifiable snapshot of the missing sequence numbers.
  List<int> get missingSeqs => _missingSeqs;

  /// Whether the gap is currently blocking rendering.
  bool get isOpen => _missingSeqs.isNotEmpty;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ChatFeedGap) return false;
    if (other._missingSeqs.length != _missingSeqs.length) return false;
    for (var i = 0; i < _missingSeqs.length; i++) {
      if (other._missingSeqs[i] != _missingSeqs[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(_missingSeqs);

  @override
  String toString() => 'ChatFeedGap(missingSeqs: $_missingSeqs)';
}
