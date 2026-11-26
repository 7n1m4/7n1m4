// SPDX-License-Identifier: GPL-3.0-or-later

// Real event frames feed the typed daemon hooks and the client-local state.
// No fabricated payloads: every assertion comes from a decoded wire frame.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/presence_event_state.dart';

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
      StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
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

void main() {
  test('presence.changed frame updates typed hook state', () async {
    final (client, fake) = await _connectedClient();
    addTearDown(client.dispose);

    final state = PresenceEventState();
    addTearDown(state.dispose);
    final binding = PresenceEventStateBinding(client: client, state: state);
    addTearDown(binding.dispose);

    final payloads = <PresenceChangedData>[];
    final unsubscribe = client.onPresenceChanged(payloads.add);
    addTearDown(unsubscribe);

    // Real daemon wire shape: crates/anima-channel/fixtures/golden/
    // event.presence_changed.online.json — decoded through the frame codec
    // before it reaches the hook, exactly like the client's event lane.
    const text =
        '{"type":"event","topic":"presence.changed","data":'
        '{"seq":7,"state":"online","subject":"user-42",'
        '"ts_ms":1700000000500}}';
    final frame = ServerFrame.parse(text);
    expect(frame.kind, ServerFrameKind.event);
    expect(frame.event!.topic, EventTopic.presenceChanged);
    fake.receive(text);
    await _pump();


    expect(payloads, hasLength(1));
    expect(payloads.single, isA<PresenceChangedData>());
    final parsed = payloads.single;
    expect(parsed.subject, 'user-42');
    expect(parsed.state, 'online');
    expect(parsed.seq, 7);
    expect(parsed.tsMs, 1700000000500);

    expect(state.snapshot.presenceOf('user-42'), isNotNull);
    expect(state.snapshot.presenceOf('user-42')!.state, 'online');
    expect(state.snapshot.presenceOf('user-42')!.seq, 7);
    expect(state.snapshot.coreHealth, isNull);
  });

  test('status.changed frame updates typed hook state', () async {
    final (client, fake) = await _connectedClient();
    addTearDown(client.dispose);

    final state = PresenceEventState();
    addTearDown(state.dispose);
    final binding = PresenceEventStateBinding(client: client, state: state);
    addTearDown(binding.dispose);

    final statuses = <StatusChangedData>[];
    final unsubscribe = client.onStatusChanged(statuses.add);
    addTearDown(unsubscribe);

    // Real daemon wire shape: event.status_changed.healthy.json
    const text =
        '{"type":"event","topic":"status.changed","data":'
        '{"core_available":true,"seq":100,"store_available":true,'
        '"store_health":"ok","ts_ms":1700000000700}}';
    final frame = ServerFrame.parse(text);
    expect(frame.event!.topic, EventTopic.statusChanged);
    fake.receive(text);
    await _pump();

    expect(statuses, hasLength(1));
    expect(statuses.single.coreAvailable, isTrue);


    final health = state.snapshot.coreHealth;
    expect(health, isNotNull);
    expect(health!.coreAvailable, isTrue);
    expect(health.storeAvailable, isTrue);
    expect(health.storeHealth, 'ok');
    expect(health.seq, 100);
    expect(health.tsMs, 1700000000700);
    expect(state.snapshot.presenceBySubject, isEmpty);

    // event.status_changed.unhealthy.json
    fake.receive(
      '{"type":"event","topic":"status.changed","data":'
      '{"core_available":false,"seq":101,"store_available":false,'
      '"store_health":"unavailable","ts_ms":1700000000800}}',
    );
    await _pump();
    expect(state.snapshot.coreHealth!.storeHealth, 'unavailable');
    expect(state.snapshot.coreHealth!.seq, 101);
  });

  test('missing or malformed payloads leave state empty', () async {
    final (client, fake) = await _connectedClient();
    addTearDown(client.dispose);

    final state = PresenceEventState();
    addTearDown(state.dispose);
    final binding = PresenceEventStateBinding(client: client, state: state);
    addTearDown(binding.dispose);

    fake.receive(
      '{"type":"event","topic":"status.changed","data":{"store_health":"ok"}}',
    );
    await _pump();
    expect(state.snapshot.isEmpty, isTrue);
    expect(state.snapshot.coreHealth, isNull);

    fake.receive(
      '{"type":"event","topic":"presence.changed","data":{"state":"online"}}',
    );
    await _pump();
    expect(state.snapshot.isEmpty, isTrue);
    expect(state.snapshot.presenceOf('user-42'), isNull);
  });

  test('stale payloads are dropped; no lip_sync.rms claim is made', () async {
    final (client, fake) = await _connectedClient();
    addTearDown(client.dispose);

    final state = PresenceEventState();
    addTearDown(state.dispose);
    final binding = PresenceEventStateBinding(client: client, state: state);
    addTearDown(binding.dispose);

    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":8,"state":"offline","subject":"user-42",'
      '"ts_ms":1700000000600}}',
    );
    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":7,"state":"online","subject":"user-42",'
      '"ts_ms":1700000000500}}',
    );
    // lip_sync.rms is client-generated; no daemon publication is consumed.
    fake.receive(
      '{"type":"event","topic":"lip_sync.rms","data":'
      '{"actor_id":"a","level":0.5,"seq":9,"ts_ms":1700000000900}}',
    );
    await _pump();

    expect(state.snapshot.presenceOf('user-42')!.state, 'offline');
    expect(state.snapshot.presenceOf('user-42')!.seq, 8);
    expect(state.snapshot.coreHealth, isNull);

    binding.dispose();
    fake.receive(
      '{"type":"event","topic":"presence.changed","data":'
      '{"seq":9,"state":"online","subject":"user-42",'
      '"ts_ms":1700000001000}}',
    );
    await _pump();
    expect(state.snapshot.presenceOf('user-42')!.seq, 8);
  });
}
