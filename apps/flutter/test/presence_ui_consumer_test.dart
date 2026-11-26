// SPDX-License-Identifier: GPL-3.0-or-later

// Widget-level coverage of the stage's daemon-presence readout. Real wire
// frames are decoded by the client's event lane and delivered to the binding
// owned by the widget; no presence, health or connection value is fabricated.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/presence_status_chip.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

final Map<String, dynamic> _healthyCore = <String, dynamic>{
  'app': 'anima-daemon',
  'version': '0.1.0',
  'coreAvailable': true,
  'storeAvailable': true,
  'storeHealth': 'ok',
  'protocol': 'airi-channel/1',
  'sessionCount': 0,
  'messageCount': 0,
};

/// Minimal in-memory transport: frames are delivered explicitly by the test.
class _FakeTransport implements DaemonTransport {
  final StreamController<String> _messages =
      StreamController<String>.broadcast(sync: true);
  final StreamController<Object> _errors = StreamController<Object>.broadcast(sync: true);
  final List<String> sent = <String>[];

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isConnected => true;

  @override
  Future<void> connect(Uri endpoint) async {}

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {}

  @override
  void dispose() {
    _messages.close();
    _errors.close();
  }

  void receive(String frame) => _messages.add(frame);
}

/// Connect a client over a fake transport and complete its auth handshake.
Future<(DaemonClient, _FakeTransport)> _connectedClient() async {
  final fake = _FakeTransport();
  final client = DaemonClient(
    transportFactory: () => fake,
    authTimeout: const Duration(seconds: 2),
    rpcTimeout: const Duration(seconds: 2),
  );
  final connecting = client.connect(
    const ConnectionSettings(authToken: 'tok'),
  );
  await _pump();
  fake.receive('{"type":"auth","ok":true}');
  await _pump();
  final probe = jsonDecode(fake.sent[1]) as Map<String, dynamic>;
  fake.receive(
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': 'core.status',
      'ok': true,
      'data': _healthyCore,
      'id': probe['id'],
    }),
  );
  await connecting;
  return (client, fake);
}

Future<void> _pumpWidget(
  WidgetTester tester, {
  required DaemonClient client,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: PresenceStatusChip(client: client)),
    ),
  );
}

/// The client's connect handshake uses real timers; run it outside Flutter's
/// FakeAsync zone. Wire frames still pass through the real codec and event lane.
Future<(DaemonClient, _FakeTransport)> _widgetClient(WidgetTester tester) async {
  final connected = await tester.runAsync(_connectedClient);
  return connected!;
}

Future<void> _disposeClient(WidgetTester tester, DaemonClient client) async {
  await tester.runAsync(() async => client.dispose());
}

void main() {
  testWidgets('absent payloads show no presence or health values', (
    tester,
  ) async {
    final (client, _) = await _widgetClient(tester);
    addTearDown(() => _disposeClient(tester, client));
    await _pumpWidget(tester, client: client);

    expect(find.byType(PresenceStatusChip), findsOneWidget);
    expect(find.text('Presence'), findsOneWidget);
    expect(find.textContaining('online'), findsNothing);
    expect(find.textContaining('offline'), findsNothing);
    expect(find.textContaining('Core:'), findsNothing);
  });

  testWidgets('real presence and status frames render daemon-supplied values', (
    tester,
  ) async {
    final (client, fake) = await _widgetClient(tester);
    addTearDown(() => _disposeClient(tester, client));
    await _pumpWidget(tester, client: client);

    // Real daemon wire shapes, decoded by the client's event lane exactly as
    // in production (crates/anima-channel fixtures).
    fake.receive(
      '{"type":"event","topic":"status.changed","data":'
      '{"core_available":true,"seq":100,"store_available":true,'
      '"store_health":"ok","ts_ms":1700000000700}}',
    );
    await tester.pump();
    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":7,"state":"online","subject":"user-42",'
      '"ts_ms":1700000000500}}',
    );
    await tester.pump();

    expect(find.text('user-42: online'), findsOneWidget);
    expect(find.text('Core: true, store: true, health: ok'), findsOneWidget);

    // Malformed frames never overwrite a valid value.
    fake.receive(
      '{"type":"event","topic":"status.changed","data":{"store_health":"x"}}',
    );
    await tester.pump();
    expect(find.text('Core: true, store: true, health: ok'), findsOneWidget);
  });

  testWidgets('an unhealthy status frame replaces the previous health', (
    tester,
  ) async {
    final (client, fake) = await _widgetClient(tester);
    addTearDown(() => _disposeClient(tester, client));
    await _pumpWidget(tester, client: client);

    fake.receive(
      '{"type":"event","topic":"status.changed","data":'
      '{"core_available":false,"seq":101,"store_available":false,'
      '"store_health":"unavailable","ts_ms":1700000000800}}',
    );
    await tester.pump();

    expect(
      find.text('Core: false, store: false, health: unavailable'),
      findsOneWidget,
    );
  });

  testWidgets('a disconnected client clears stale daemon values', (
    tester,
  ) async {
    final (client, fake) = await _widgetClient(tester);
    addTearDown(() => _disposeClient(tester, client));
    await _pumpWidget(tester, client: client);

    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":7,"state":"online","subject":"user-42",'
      '"ts_ms":1700000000500}}',
    );
    await tester.pump();
    expect(find.text('user-42: online'), findsOneWidget);

    await tester.runAsync(() async => client.disconnect());
    await tester.pump();

    expect(find.text('user-42: online'), findsNothing);
    expect(find.text('Presence'), findsOneWidget);
  });

  testWidgets('frames for other subjects do not invent a local subject', (
    tester,
  ) async {
    final (client, fake) = await _widgetClient(tester);
    addTearDown(() => _disposeClient(tester, client));
    await _pumpWidget(tester, client: client);

    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":7,"state":"online","subject":"user-42",'
      '"ts_ms":1700000000500}}',
    );
    await tester.pump();

    // Only the daemon-published subject is rendered; no placeholder appears.
    expect(find.text('user-42: online'), findsOneWidget);
    expect(find.textContaining('unknown'), findsNothing);
    expect(find.textContaining('offline'), findsNothing);
  });
}
