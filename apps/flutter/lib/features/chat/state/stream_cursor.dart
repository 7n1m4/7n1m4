// SPDX-License-Identifier: GPL-3.0-or-later

// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
//
// In-memory value objects for tracking a chat event stream's position. Nothing
// here is persisted, and nothing here parses or builds a wire envelope.

/// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
///
/// Immutable, opaque position in a chat event stream. The epoch and high-water
/// mark stay private; [toString] is the only place their values are visible.
class StreamCursor {
  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Cursor before any frame has been observed: epoch 0, no position.
  factory StreamCursor.initial() => StreamCursor._(0, null);

  StreamCursor._(this._epoch, this._highWater);

  final int _epoch;
  final int? _highWater;

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Pure advance: returns a new cursor with the same epoch and [highWater].
  StreamCursor next(int highWater) => StreamCursor._(_epoch, highWater);

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Whether a high-water mark has been recorded yet.
  bool get hasPosition => _highWater != null;

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StreamCursor &&
          other._epoch == _epoch &&
          other._highWater == _highWater;

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  @override
  int get hashCode => Object.hash(_epoch, _highWater);

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Diagnostics only; the private values never escape through a public getter.
  @override
  String toString() => 'StreamCursor(epoch: $_epoch, highWater: $_highWater)';
}

/// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
///
/// Pure, synchronous tracker of forward progress over a chat event stream. It
/// records only the numbers of missing sequence positions; it never buffers,
/// reorders or replays frames.
class StreamGapTracker {
  int? _highWater;
  final Set<int> _gaps = <int>{};

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Highest contiguous sequence number observed, or null before the first one.
  int? get highWater => _highWater;

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Unmodifiable snapshot of the individual missing sequence numbers.
  Set<int> get gaps => Set<int>.unmodifiable(_gaps);

  /// TODO(airi-6anh): UNRATIFIED_WIRE_SEAM — local prep only; no wire contract is ratified.
  ///
  /// Records a forward frame. Late or duplicate frames are ignored.
  // shortcut: gaps are individual seq numbers, not ranges; upgrade only if this ever tracks large jumps.
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
