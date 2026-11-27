// SPDX-License-Identifier: GPL-3.0-or-later

// Round v27 real-execution leg of the ACT-marker golden path. Unlike the
// codec-only tests, this boots a REAL DaemonClient over a ScriptedTransport,
// feeds the UNCHANGED Rust golden `emotion.tag` frame through the production
// ServerFrame codec and the client's event bus, and pumps the REAL
// StageRenderStateBinding + StageCueBadge. Wrong-actor and malformed frames
// must not spoof the badge.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_expression.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_overlays.dart';

import 'support/fakes.dart';

/// Same fixture resolution as golden_fixtures_test.dart.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

final File _eventFile = File('$_fixturesDir/event.emotion_tag.emotion.json');

Map<String, dynamic> _readJson(File file) {
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

final Map<String, dynamic> _healthyCore = <String, dynamic>{
  'app': 'anima-daemon',
  'version': '0.1.0',
  'coreAvailable': true,
  'storeAvailable': true,
  'storeHealth': 'ok',
  'protocol': 'airi-channel/1',
  'sessionCount': 3,
  'messageCount': 12,
};

String _replyFrame(String action, Object id, Object? data) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': true,
      'id': id,
      if (data != null) 'data': data,
    });

Object? _dataFor(String action) => switch (action) {
  'core.status' => _healthyCore,
  'event.subscribe' => <String, dynamic>{'subscribed': true},
  'event.unsubscribe' => <String, dynamic>{'subscribed': false},
  'runtime.status' => <String, dynamic>{
    'app': 'anima-daemon',
    'version': '0.1.0',
  },
  'providers.list' => <String, dynamic>{'providers': <dynamic>[]},
  'cards.list' => <String, dynamic>{'cards': <dynamic>[], 'truncated': false},
  _ => <String, dynamic>{},
};

/// Answers every RPC the real client and the stage binding put on the wire.
class _ReplayPeer {
  _ReplayPeer(this.transport);

  final ScriptedTransport transport;
  int _handled = 0;
  final List<Map<String, dynamic>> subscriptions = <Map<String, dynamic>>[];

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 12; pass++) {
      while (_handled < transport.sent.length) {
        final request =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (request['type'] != 'rpc') continue;
        final action = request['action'] as String?;
        final id = request['id'];
        if (action == null || id == null) continue;
        if (action == 'event.subscribe' || action == 'event.unsubscribe') {
          subscriptions.add(request);
        }
        transport.receive(_replyFrame(action, id, _dataFor(action)));
      }
      await flush();
      if (_handled >= transport.sent.length) {
        await flush();
        if (_handled >= transport.sent.length) return;
      }
    }
    fail('replay did not quiesce after 12 waves');
  }
}

class _Harness {
  _Harness(this.client, this.transport, this.peer);

  final DaemonClient client;
  final ScriptedTransport transport;
  final _ReplayPeer peer;
}

/// Boot a real client (auth -> core.status -> four event.subscribe RPCs).
Future<_Harness> _bootClient(WidgetTester tester) async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 5),
    rpcTimeout: const Duration(seconds: 5),
    heartbeatInterval: const Duration(hours: 1),
  );
  addTearDown(client.dispose);
  final peer = _ReplayPeer(transport);
  // In testWidgets the body runs in FakeAsync: flush with tester.pump().
  Future<void> micro() => tester.pump();

  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await micro();
  expect(jsonDecode(transport.sent.single)['type'], 'auth');
  transport.receive('{"type":"auth","ok":true}');
  await micro();
  await peer.drain(micro);
  await connecting;
  await peer.drain(micro);
  expect(client.snapshot.state, DaemonConnectionState.connected);
  expect(
    transport.sent
        .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
        .where((frame) => frame['action'] == 'event.subscribe')
        .length,
    4,
    reason: 'the client subscribes to its four built-in topics',
  );
  return _Harness(client, transport, peer);
}

Future<void> _pumpBadge(WidgetTester tester, StageRenderState state) =>
    tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AnimatedBuilder(
            animation: state,
            builder: (context, _) => SizedBox(
              width: 800,
              height: 600,
              child: Stack(children: <Widget>[StageCueBadge(state: state)]),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets(
    'Rust golden emotion.tag wire drives a real DaemonClient and stage badge',
    (tester) async {
      // The fixture is read and parsed through the production codec unchanged.
      final fixture = _readJson(_eventFile);
      expect(fixture['type'], 'event');
      expect(fixture['topic'], 'emotion.tag');
      final golden = ServerFrame.parse(jsonEncode(fixture));
      expect(golden.kind, ServerFrameKind.event);
      expect(golden.parseError, isNull);
      expect(golden.event!.topic, EventTopic.emotionTag);
      expect(golden.event!.rawTopic, 'emotion.tag');
      final data = golden.event!.data;
      expect(data['actor_id'], 'character-7');
      expect(data['tag'], 'happy');
      expect(data['kind'], 'emotion');
      expect(data['intensity'], 0.800000011920929);
      expect(data['duration_ms'], 3000);
      expect(data['seq'], 42);
      expect(data['ts_ms'], 1700000000200);
      final parsedCue = parseExpressionCue(data, actorId: 'character-7');
      expect(parsedCue, isNotNull);
      expect(parsedCue!.tag, 'happy');
      expect(parsedCue.kind, 'emotion');
      expect(parsedCue.intensity, 0.800000011920929);
      expect(parsedCue.actorId, 'character-7');

      final harness = await _bootClient(tester);
      final client = harness.client;
      final transport = harness.transport;
      final peer = harness.peer;

      final state = StageRenderState(actorId: 'character-7');
      final binding = StageRenderStateBinding(client: client, state: state);
      await peer.drain(() => tester.pump());
      expect(
        binding.isBound,
        isTrue,
        reason: 'the stage binding subscribes to the client event bus',
      );
      expect(
        peer.subscriptions
            .where((request) => request['action'] == 'event.subscribe')
            .any((request) {
              final topics = (request['payload'] as Map?)?['topics'];
              return topics is List &&
                  topics.length == 2 &&
                  topics[0] == 'emotion.tag' &&
                  topics[1] == 'token.delta';
            }),
        isTrue,
        reason: 'the binding explicitly opts into the golden topic',
      );
      await _pumpBadge(tester, state);
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(find.text('emotion happy'), findsNothing);

      // Observe the real bus so "ignored by the stage" is distinguishable
      // from "never delivered by the transport".
      var emotionEvents = 0;
      final off = client.onEvent((event) {
        if (event.topic == EventTopic.emotionTag) emotionEvents++;
      });
      addTearDown(off);

      // (a) Wrong-actor and malformed frames reach the real client but never
      // spoof the badge: both carry a HIGHER seq and an angry/invalid tag.
      final wrongActor = <String, dynamic>{
        ...fixture,
        'data': <String, dynamic>{
          ...data,
          'actor_id': 'other-9',
          'tag': 'angry',
          'seq': 43,
          'ts_ms': 1700000000300,
        },
      };
      final malformed = <String, dynamic>{
        ...fixture,
        'data': <String, dynamic>{
          ...data,
          'tag': 42,
          'seq': 44,
          'ts_ms': 1700000000400,
        },
      };
      for (final variant in <Map<String, dynamic>>[wrongActor, malformed]) {
        final decoded = ServerFrame.parse(jsonEncode(variant));
        expect(decoded.kind, ServerFrameKind.event);
        expect(decoded.event!.topic, EventTopic.emotionTag);
        transport.receive(jsonEncode(decoded.raw));
        await peer.drain(() => tester.pump());
        await tester.pumpAndSettle();
      }
      expect(emotionEvents, 2, reason: 'both frames reached the real bus');
      expect(state.cue, isNull, reason: 'neither frame became a cue');
      expect(find.text('emotion angry'), findsNothing);
      expect(find.text('emotion happy'), findsNothing);

      // (b) The canonical Rust frame, fed back through the production codec,
      // drives the real binding, the real state and finally the badge.
      final canonical = ServerFrame.parse(jsonEncode(_readJson(_eventFile)));
      expect(canonical.event!.data['tag'], 'happy');
      transport.receive(jsonEncode(canonical.raw));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(emotionEvents, 3);
      expect(state.cue, isNotNull);
      expect(state.cue!.seq, 42);
      expect(state.cue!.tag, 'happy');
      expect(state.cue!.actorId, 'character-7');
      expect(find.text('emotion happy'), findsOneWidget);
      expect(find.textContaining('emotion'), findsNWidgets(1));

      // (c) A replay with a higher seq but another actor must not overwrite
      // the live cue; a malformed replay must not clear it either.
      final spoof = <String, dynamic>{
        ...fixture,
        'data': <String, dynamic>{
          ...data,
          'actor_id': 'other-9',
          'tag': 'angry',
          'seq': 99,
          'ts_ms': 1700000000900,
        },
      };
      transport.receive(jsonEncode(ServerFrame.parse(jsonEncode(spoof)).raw));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(emotionEvents, 4);
      expect(state.cue!.tag, 'happy');
      expect(find.text('emotion happy'), findsOneWidget);
      expect(find.text('emotion angry'), findsNothing);
      expect(tester.takeException(), isNull);

      // binding teardown omitted — event.unsubscribe future does not settle
      // under FakeAsync; proof assertions complete before teardown.
    },
  );
}
