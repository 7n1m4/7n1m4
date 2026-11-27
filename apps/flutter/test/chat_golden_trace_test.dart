// SPDX-License-Identifier: GPL-3.0-or-later

// Dart leg of the shared chat streaming trace fixture. The same JSON envelope
// is locked by crates/anima-channel/tests/interaction_chat_trace.rs, so the
// Dart codec must derive the same request/reply/event values from the same
// bytes. This is a strict codec-level trace assertion (no widget pump):
// this first cross-language lane proves the wire seam, not ChatScreen state.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

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
    expect(frames.length, 5, reason: 'trace must hold exactly 5 frames');

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
      ServerFrameKind.event,
    ], reason: 'request -> ack -> two text deltas + empty terminal');

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

    // Frames 2/3/4: token.delta events on the message declared by the ack.
    // The terminal is the distinct EMPTY-delta frame 4, not the text at 3.
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
    final middle = deltas[1];
    final terminal = deltas[2];
    for (var i = 0; i < deltas.length; i++) {
      expect(deltas[i]['session_id'], 'sess-abc', reason: 'delta $i');
      expect(deltas[i]['message_id'], 'msg-1', reason: 'delta $i');
    }
    expect(
      deltas.where((d) => d['final'] == true).length,
      1,
      reason: 'exactly one terminal token.delta frame',
    );
    expect(partial['delta'], isNotEmpty);
    expect(middle['delta'], isNotEmpty);
    expect(terminal['delta'], isEmpty, reason: 'terminal delta must be empty');

    expect(partial['delta'], 'Hello');
    expect(partial['index'], 0);
    expect(partial['seq'], 5);
    expect(partial['ts_ms'], 1700000000900);
    expect(partial['final'], isFalse);
    expect(partial.containsKey('reason'), isFalse);

    expect(middle['delta'], ' world');
    expect(middle['index'], 1);
    expect(middle['seq'], 6);
    expect(middle['ts_ms'], 1700000000950);
    expect(
      middle['final'],
      isFalse,
      reason: 'the middle frame must not be final',
    );
    expect(middle.containsKey('reason'), isFalse);

    expect(terminal['index'], 2);
    expect(terminal['seq'], 7);
    expect(terminal['ts_ms'], 1700000001000);
    expect(
      terminal['final'],
      isTrue,
      reason: 'the terminal frame must be last',
    );
    expect(terminal['reason'], 'complete');
  });

  testWidgets(
    'chat.send token.delta trace renders one finalized assistant bubble',
    (tester) async {
      final file = File('$_fixturesDir/trace.chat.send.token_delta.json');
      final fixture =
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      final frames = (fixture['frames'] as List).cast<Map<String, dynamic>>();

      final client = FakeChatClient();
      addTearDown(client.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatScreen(client: client)),
        ),
      );
      await tester.pumpAndSettle();

      // Anti-vacuous baseline: no assistant bubble before the trace is replayed.
      expect(find.byType(Card), findsNothing);
      expect(find.text('Hello world'), findsNothing);

      // Frame 1 is the ack echoing the fixture's string id "t1"; DaemonClient
      // correlates pending calls by int id only (daemon_client.dart:575), so it
      // would be dropped. FakeChatClient bypasses transport/auth entirely, so
      // the three token.delta events go straight to the onEvent listener.
      // Frames 2 and 3 are text deltas with final:false — the bubble accumulates
      // but is NOT finalized by either one.
      expect(frames[2]['data']['final'], isFalse);
      client.emitEvent(GatewayEventFrame.fromJson(frames[2]));
      await tester.pump();
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('Hello world'), findsNothing);
      expect(find.byType(Card), findsOneWidget);

      expect(frames[3]['data']['final'], isFalse);
      client.emitEvent(GatewayEventFrame.fromJson(frames[3]));
      await tester.pump();
      expect(find.text('Hello world'), findsOneWidget);
      expect(
        find.byType(Card),
        findsOneWidget,
        reason: 'no new bubble mid-turn',
      );

      // Frame 4 is the daemon's distinct EMPTY-delta final:true marker. It
      // finalizes the already-complete text; it does not append any text.
      expect(frames[4]['data']['delta'], isEmpty);
      expect(frames[4]['data']['final'], isTrue);
      client.emitEvent(GatewayEventFrame.fromJson(frames[4]));
      await tester.pumpAndSettle();

      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Hello'), findsNothing);
      expect(find.text(' world'), findsNothing);

      // Post-terminal replay rejection: a forged non-final frame for the same
      // message with a HIGHER seq/index must be dropped by the finalized-id
      // guard, never reopening the bubble with leaked text.
      client.emitEvent(
        GatewayEventFrame.fromJson({
          'type': 'event',
          'topic': 'token.delta',
          'data': {
            'session_id': 'sess-abc',
            'message_id': 'msg-1',
            'delta': 'LEAK-AFTER-FINAL',
            'index': 3,
            'final': false,
            'seq': 8,
            'ts_ms': 1700000001100,
          },
        }),
      );
      await tester.pumpAndSettle();
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Hello world'), findsOneWidget);
      expect(find.text('Hello worldLEAK-AFTER-FINAL'), findsNothing);
    },
  );
}
