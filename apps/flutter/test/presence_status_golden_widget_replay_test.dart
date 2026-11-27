// SPDX-License-Identifier: GPL-3.0-or-later

// Round v28 real-execution leg of the presence/status golden path. The SAME
// unchanged Rust golden `presence.changed` / `status.changed` bytes are fed
// through a REAL DaemonClient + ScriptedTransport and the production
// ServerFrame codec, then pumped into the REAL PresenceStatusChip used at
// stage_screen.dart:330. No presence or health value is hand-built for the
// main proof; only the negative (lower-seq / malformed) variants are derived.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/presence_status_chip.dart';

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

final File _onlineFile = File(
  '$_fixturesDir/event.presence_changed.online.json',
);
final File _offlineFile = File(
  '$_fixturesDir/event.presence_changed.offline.json',
);
final File _healthyFile = File(
  '$_fixturesDir/event.status_changed.healthy.json',
);
final File _unhealthyFile = File(
  '$_fixturesDir/event.status_changed.unhealthy.json',
);
final File _coreReplyFile = File('$_fixturesDir/core_status.reply.json');

Map<String, dynamic> _readJson(File file) {
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

String _replyFrame(String action, Object id, Object? data) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': true,
      'id': id,
      if (data != null) 'data': data,
    });

Object? _dataFor(String action) => switch (action) {
  // The golden is the source of truth. Its app='airi-daemon' is used
  // verbatim; the old inline 'anima-daemon' expectation is not restated.
  'core.status' => _readJson(_coreReplyFile),
  'event.subscribe' => <String, dynamic>{'subscribed': true},
  'event.unsubscribe' => <String, dynamic>{'subscribed': false},
  // Mirrors the stale golden identity; unused for this boot path.
  'runtime.status' => <String, dynamic>{
    'app': 'airi-daemon',
    'version': '0.1.0',
  },
  'providers.list' => <String, dynamic>{'providers': <dynamic>[]},
  'cards.list' => <String, dynamic>{'cards': <dynamic>[], 'truncated': false},
  _ => <String, dynamic>{},
};

/// Answers every RPC the real client puts on the wire during boot.
class _ReplayPeer {
  _ReplayPeer(this.transport);

  final ScriptedTransport transport;
  int _handled = 0;

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 12; pass++) {
      while (_handled < transport.sent.length) {
        final request =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (request['type'] != 'rpc') continue;
        final action = request['action'] as String?;
        final id = request['id'];
        if (action == null || id == null) continue;
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
  // dispose() is synchronous (void): it cannot hang the FakeAsync teardown.
  addTearDown(client.dispose);
  final peer = _ReplayPeer(transport);
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

/// Decode the golden bytes with the PRODUCTION codec, exactly as in the client.
ServerFrame _decodeGolden(
  Map<String, dynamic> fixture,
  EventTopic topic,
  String rawTopic,
) {
  final decoded = ServerFrame.parse(jsonEncode(fixture));
  expect(decoded.kind, ServerFrameKind.event);
  expect(decoded.parseError, isNull);
  expect(decoded.event, isNotNull);
  expect(decoded.event!.topic, topic);
  expect(decoded.event!.rawTopic, rawTopic);
  return decoded;
}

Future<void> _feed(
  WidgetTester tester,
  ScriptedTransport transport,
  _ReplayPeer peer,
  ServerFrame frame,
) async {
  transport.receive(jsonEncode(frame.raw));
  await peer.drain(() => tester.pump());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Rust golden presence/status wire drives a real DaemonClient and stage chip',
    (tester) async {
      // The four fixtures are read verbatim and parsed through the codec.
      final onlineFixture = _readJson(_onlineFile);
      final offlineFixture = _readJson(_offlineFile);
      final healthyFixture = _readJson(_healthyFile);
      final unhealthyFixture = _readJson(_unhealthyFile);

      final online = _decodeGolden(
        onlineFixture,
        EventTopic.presenceChanged,
        'presence.changed',
      );
      final offline = _decodeGolden(
        offlineFixture,
        EventTopic.presenceChanged,
        'presence.changed',
      );
      final healthy = _decodeGolden(
        healthyFixture,
        EventTopic.statusChanged,
        'status.changed',
      );
      final unhealthy = _decodeGolden(
        unhealthyFixture,
        EventTopic.statusChanged,
        'status.changed',
      );

      expect(online.event!.data['subject'], 'user-42');
      expect(online.event!.data['state'], 'online');
      expect(online.event!.data['seq'], 7);
      expect(offline.event!.data['state'], 'offline');
      expect(offline.event!.data['seq'], 8);
      expect(healthy.event!.data['core_available'], true);
      expect(healthy.event!.data['store_available'], true);
      expect(healthy.event!.data['store_health'], 'ok');
      expect(healthy.event!.data['seq'], 100);
      expect(unhealthy.event!.data['core_available'], false);
      expect(unhealthy.event!.data['store_health'], 'unavailable');
      expect(unhealthy.event!.data['seq'], 101);

      final harness = await _bootClient(tester);
      final client = harness.client;
      final transport = harness.transport;
      final peer = harness.peer;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: PresenceStatusChip(client: client)),
        ),
      );
      await peer.drain(() => tester.pump());
      expect(find.byType(PresenceStatusChip), findsOneWidget);
      expect(find.text('Presence'), findsOneWidget);
      expect(find.textContaining('user-42:'), findsNothing);
      expect(find.textContaining('Core:'), findsNothing);

      // Observe the REAL bus so "ignored by the chip" is distinguishable from
      // "never delivered by the transport".
      var presenceFrames = 0;
      var statusFrames = 0;
      final off = client.onEvent((event) {
        if (event.topic == EventTopic.presenceChanged) presenceFrames++;
        if (event.topic == EventTopic.statusChanged) statusFrames++;
      });
      addTearDown(off);

      // (a) Canonical golden frames drive the real binding and the chip.
      await _feed(tester, transport, peer, healthy);
      await _feed(tester, transport, peer, online);
      expect(statusFrames, 1);
      expect(presenceFrames, 1);
      expect(find.text('user-42: online'), findsOneWidget);
      expect(find.text('Core: true, store: true, health: ok'), findsOneWidget);

      // (b) Lower-seq replays are dropped even when they carry newer-looking
      // payloads: per-subject presence seq and core-health seq are monotonic.
      final lowerPresence = <String, dynamic>{
        ...onlineFixture,
        'data': <String, dynamic>{
          ...online.event!.data,
          'seq': 6,
          'state': 'offline',
        },
      };
      final lowerStatus = <String, dynamic>{
        ...unhealthyFixture,
        'data': <String, dynamic>{...unhealthy.event!.data, 'seq': 99},
      };
      for (final variant in <Map<String, dynamic>>[
        lowerPresence,
        lowerStatus,
      ]) {
        await _feed(
          tester,
          transport,
          peer,
          _decodeGolden(
            variant,
            variant['topic'] == 'presence.changed'
                ? EventTopic.presenceChanged
                : EventTopic.statusChanged,
            variant['topic'] as String,
          ),
        );
      }
      expect(presenceFrames, 2);
      expect(statusFrames, 2);
      expect(find.text('user-42: online'), findsOneWidget);
      expect(find.text('user-42: offline'), findsNothing);
      expect(find.text('Core: true, store: true, health: ok'), findsOneWidget);
      expect(find.textContaining('unavailable'), findsNothing);

      // (c) Malformed frames reach the bus but never overwrite live state.
      final malformedPresence = <String, dynamic>{
        ...onlineFixture,
        'data': <String, dynamic>{...online.event!.data, 'seq': 9, 'state': 42},
      };
      final malformedStatus = <String, dynamic>{
        ...healthyFixture,
        'data': <String, dynamic>{
          'store_health': 'x',
          'seq': 102,
          'ts_ms': 1700000000900,
        },
      };
      for (final variant in <Map<String, dynamic>>[
        malformedPresence,
        malformedStatus,
      ]) {
        await _feed(
          tester,
          transport,
          peer,
          _decodeGolden(
            variant,
            variant['topic'] == 'presence.changed'
                ? EventTopic.presenceChanged
                : EventTopic.statusChanged,
            variant['topic'] as String,
          ),
        );
      }
      expect(presenceFrames, 3);
      expect(statusFrames, 3);
      expect(find.text('user-42: online'), findsOneWidget);
      expect(find.text('Core: true, store: true, health: ok'), findsOneWidget);
      expect(find.textContaining('unavailable'), findsNothing);

      // (d) The remaining canonical golden frames replace the live values.
      await _feed(tester, transport, peer, offline);
      await _feed(tester, transport, peer, unhealthy);
      expect(presenceFrames, 4);
      expect(statusFrames, 4);
      expect(find.text('user-42: offline'), findsOneWidget);
      expect(find.text('user-42: online'), findsNothing);
      expect(
        find.text('Core: false, store: false, health: unavailable'),
        findsOneWidget,
      );

      // (e) A real disconnect clears the snapshot: stale offline/unhealthy is
      // never shown as current. Disconnect runs outside FakeAsync (real timers)
      // so its transport teardown cannot stall the widget test.
      await tester.runAsync(() async => client.disconnect());
      await tester.pump();
      expect(find.text('user-42: offline'), findsNothing);
      expect(find.textContaining('Core:'), findsNothing);
      expect(find.text('Presence'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // Chip-owned binding disposes synchronously with the widget; no awaited
      // client/binding teardown is added here (see the dispose comment above).
    },
  );
}
