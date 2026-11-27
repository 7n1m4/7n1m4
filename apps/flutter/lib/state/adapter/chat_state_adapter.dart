// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:anima_control/daemon_client/protocol.dart';
import '../../transport/stream_cursor.dart';
import '../../transport/chat_transport_adapter.dart';

/// Reducer that applies the ratified wire decisions (D1-D3) to an already-decoded
/// event stream: daemon-authoritative seq/epoch, wipe + resync on any
/// discontinuity, no partial rendering, terminal drops the gap indicator.
class ChatStateAdapter {
  ChatStateAdapter(this._transport) {
    _sub = _transport.events.listen(_onFrame);
  }

  final ChatTransportAdapter _transport;
  StreamSubscription<GatewayEventFrame>? _sub;

  StreamCursor _cursor = StreamCursor.initial();
  final List<Object> _buffer = <Object>[];
  bool _gap = false;

  StreamCursor get cursor => _cursor;
  bool get hasGap => _gap;
  List<Object> get buffer => List<Object>.unmodifiable(_buffer);

  void _onFrame(GatewayEventFrame frame) {
    final incoming = _parseCursor(frame);
    // Terminal signal drops any unresolved gap indicator (D3).
    final terminal = _isTerminal(frame);
    if (terminal) {
      _gap = false;
    }

    if (incoming == null) {
      _buffer.add(frame);
      return;
    }

    // First observed frame establishes the cursor.
    if (!_cursor.hasPosition) {
      _cursor = incoming;
      _buffer.add(frame);
      return;
    }

    // Epoch mismatch => wipe local buffer + full snapshot (D2).
    if (incoming.epoch != _cursor.epoch) {
      _wipe();
      _cursor = incoming;
      unawaited(_transport.requestResync());
      _buffer.add(frame);
      return;
    }

    final currentSeq = _cursor.seq;
    final incomingSeq = incoming.seq!;
    if (currentSeq == null) {
      _cursor = incoming;
      _buffer.add(frame);
      return;
    }

    // Regression or gap => wipe + full resync; never render partial (D1/D3).
    if (incomingSeq <= currentSeq || incomingSeq != currentSeq + 1) {
      if (incomingSeq > currentSeq + 1) {
        _gap = true;
      }
      _wipe();
      unawaited(_transport.requestResync(fromSeq: currentSeq));
      if (!terminal) {
        _gap = incomingSeq > currentSeq + 1;
      } else {
        _gap = false;
      }
      _buffer.add(frame);
      return;
    }

    _cursor = incoming;
    _buffer.add(frame);
    if (terminal) _gap = false;
  }

  StreamCursor? _parseCursor(GatewayEventFrame frame) {
    final data = frame.data;
    final cursorMap = data['cursor'];
    int? epoch;
    int? seq;
    if (cursorMap is Map<String, dynamic>) {
      final e = cursorMap['epoch'];
      final s = cursorMap['seq'];
      if (e is int) epoch = e;
      if (s is int) seq = s;
    } else {
      final e = data['epoch'];
      final s = data['seq'];
      if (e is int) epoch = e;
      if (s is int) seq = s;
    }
    if (epoch == null || seq == null) return null;
    return StreamCursor.initial(epoch: epoch).next(seq);
  }

  bool _isTerminal(GatewayEventFrame frame) {
    final data = frame.data;
    if (data['terminal'] == true || data['done'] == true || data['final'] == true) {
      return true;
    }
    return false;
  }

  void _wipe() {
    _buffer.clear();
  }

  Future<void> dispose() async {
    await _sub?.cancel();
    await _transport.close();
  }
}
