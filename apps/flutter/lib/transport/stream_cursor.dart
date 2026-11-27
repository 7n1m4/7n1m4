// SPDX-License-Identifier: GPL-3.0-or-later

/// Immutable position in a chat event stream, per ratified wire decisions:
/// daemon-authoritative epoch (u64, increments on restart/session reset) and
/// seq (u64, strictly +1). Epoch mismatch => wipe buffer + full snapshot.
class StreamCursor {
  const StreamCursor._(this.epoch, this.seq);

  /// Cursor before any frame has been observed: epoch 0, no position.
  factory StreamCursor.initial({int epoch = 0}) => StreamCursor._(epoch, null);

  final int epoch;
  final int? seq;

  /// Pure advance: returns a new cursor with the same epoch and [seq].
  StreamCursor next(int seq) => StreamCursor._(epoch, seq);

  /// Whether a position has been recorded yet.
  bool get hasPosition => seq != null;

  /// Highest observed seq, or null before the first frame.
  int? get highWater => seq;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamCursor && other.epoch == epoch && other.seq == seq;

  @override
  int get hashCode => Object.hash(epoch, seq);

  @override
  String toString() => 'StreamCursor(epoch: $epoch, highWater: $seq)';
}

/// Pure, synchronous tracker of forward progress over a chat event stream.
class StreamGapTracker {
  int? _highWater;
  final Set<int> _gaps = <int>{};

  int? get highWater => _highWater;

  Set<int> get gaps => Set<int>.unmodifiable(_gaps);

  void observe(int seq) {
    final current = _highWater;
    if (current == null) {
      _highWater = seq;
      return;
    }
    if (seq <= current) return;
    if (seq == current + 1) {
      _highWater = seq;
      return;
    }
    for (var missing = current + 1; missing < seq; missing++) {
      _gaps.add(missing);
    }
    _highWater = seq;
  }
}
