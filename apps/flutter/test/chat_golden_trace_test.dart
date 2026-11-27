// SPDX-License-Identifier: GPL-3.0-or-later

// Dart leg of the shared chat streaming trace fixture. The same JSON envelope
// is locked by crates/anima-channel/tests/interaction_chat_trace.rs, so the
// Dart codec must derive the same request/reply/event values from the same
// bytes. This is a strict codec-level trace assertion (no widget pump):
// this first cross-language lane proves the wire seam, not ChatScreen state.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

/// Path to the shared Rust golden fixtures directory.
final String _fixturesDir = () {
  // Works when tests are run from the repo root.
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  // Works when tests are run from apps/flutter (flutter test default cwd).
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  // Fallback for IDE runners.
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

void main() {
  test('dart chat trace matches shared fixture', () {
    final file = File('$_fixturesDir/trace.chat.send.token_delta.json');
    if (!file.existsSync()) fail('fixture not found: ${file.path}');
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

    expect(fixture['schema'], 'airi-channel-trace-v1');
    expect(fixture['path'], 'chat.send');
    final frames = fixture['frames'] as List;
    expect(frames.length, 4, reason: 'trace must hold exactly 4 frames');

    // Every frame goes through the real ServerFrame.parse codec.
    final parsed = <ServerFrame>[];
    for (var i = 0; i < frames.length; i++) {
      final frame = ServerFrame.parse(jsonEncode(frames[i]));
      expect(frame.parseError, isNull, reason: 'frame $i failed to parse');
      parsed.add(frame);
    }
    expect(parsed.map((f) => f.kind).toList(), [
      ServerFrameKind.rpc,
      ServerFrameKind.rpc,
      ServerFrameKind.event,
      ServerFrameKind.event,
    ], reason: 'request -> ack -> two deltas');

    // Frame 0: client request. ServerFrame.parse still recognizes the rpc
    // envelope, but the wire shape is RpcRequest (emitted by the client).
    final request = frames[0] as Map<String, dynamic>;
    expect(request['type'], 'rpc');
    expect(request['action'], 'chat.send');
    expect(request['id'], 't1');
    expect(request['payload'], {
      'sessionId': 'sess-abc',
      'content': 'Hello, Anima!',
    });
    expect(
      RpcRequest(
        action: request['action'] as String,
        payload: request['payload'] as Map<String, dynamic>,
        id: request['id'],
      ).toJson(),
      request,
      reason: 'Dart request codec must emit the exact fixture bytes',
    );
    expect(parsed[0].raw['id'], 't1');

    // Frame 1: server ack, echoing id t1 and declaring message msg-1.
    final ack = parsed[1].reply;
    expect(ack, isNotNull);
    expect(ack!.action, 'chat.send');
    expect(ack.ok, isTrue);
    expect(ack.id, 't1', reason: 'rpc id must pass through verbatim');
    expect(ack.data, {
      'sessionId': 'sess-abc',
      'messageId': 'msg-1',
      'accepted': true,
    });

    // Frames 2/3: token.delta events on the message declared by the ack.
    final deltas = <Map<String, dynamic>>[];
    for (var i = 2; i < parsed.length; i++) {
      final event = parsed[i].event;
      expect(event, isNotNull, reason: 'frame $i must be an event');
      expect(event!.topic, EventTopic.tokenDelta, reason: 'frame $i');
      expect(event.rawTopic, 'token.delta', reason: 'frame $i');
      expect(event.id, isNull, reason: 'frame $i');
      deltas.add(event.data);
    }

    final partial = deltas[0];
    final terminal = deltas[1];
    for (var i = 0; i < deltas.length; i++) {
      expect(deltas[i]['session_id'], 'sess-abc', reason: 'delta $i');
      expect(deltas[i]['message_id'], 'msg-1', reason: 'delta $i');
      expect(deltas[i]['delta'], isNotEmpty, reason: 'delta $i');
    }

    expect(partial['delta'], 'Hello');
    expect(partial['index'], 0);
    expect(partial['seq'], 5);
    expect(partial['ts_ms'], 1700000000900);
    expect(partial['final'], isFalse);
    expect(partial.containsKey('reason'), isFalse);

    expect(terminal['delta'], ' world');
    expect(terminal['index'], partial['index'] + 1);
    expect(terminal['seq'], partial['seq'] + 1);
    expect(terminal['ts_ms'], 1700000001000);
    expect(
      terminal['final'],
      isTrue,
      reason: 'the terminal frame must be last',
    );
    expect(terminal['reason'], 'complete');
  });
}
