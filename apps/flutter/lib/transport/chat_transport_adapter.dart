// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:anima_control/daemon_client/protocol.dart';

import 'stream_cursor.dart';

/// Minimal transport adapter over a decoded chat event stream.
///
/// Per ratified wire decisions (daemon-authoritative cursor): the daemon owns
/// `seq`/`epoch`; this client never repairs gaps locally. On a detected gap
/// the buffer is wiped and a full resync is requested via [requestResync].
class ChatTransportAdapter {
  ChatTransportAdapter(StreamCursor cursor) : _cursor = cursor;

  StreamCursor _cursor;
  final Set<int> _gap = <int>{};

  final StreamController<GatewayEventFrame> _events =
      StreamController<GatewayEventFrame>.broadcast();

  /// Already-decoded event frames.
  Stream<GatewayEventFrame> get events => _events.stream;

  /// Current daemon-authoritative cursor.
  StreamCursor get cursor => _cursor;

  /// Whether a gap has been detected and not yet resolved.
  bool get hasGap => _gap.isNotEmpty;

  /// Observed missing seqs within the current epoch.
  Set<int> get gap => Set<int>.unmodifiable(_gap);

  /// Track a new cursor position, recording gaps / epoch changes.
  ///
  /// Epoch mismatch => wipe local gap state (caller wipes buffer + snapshot).
  /// Client never repairs gaps locally; only records them for resync.
  void observeCursor(StreamCursor cursor) {
    if (cursor.epoch != _cursor.epoch) {
      _cursor = cursor;
      _gap.clear();
      return;
    }
    final previous = _cursor.seq;
    _cursor = cursor;
    final current = cursor.seq;
    if (previous == null || current == null) return;
    if (current <= previous) {
      if (current < previous) _gap.add(current);
      return;
    }
    if (current > previous + 1) {
      for (var missing = previous + 1; missing < current; missing++) {
        _gap.add(missing);
      }
    }
  }

  /// Request a full resync from the daemon (local full-resubscribe stub).
  Future<void> requestResync({int? fromSeq}) async {
    _gap.clear();
  }

  Future<void> close() async {
    await _events.close();
  }
}
