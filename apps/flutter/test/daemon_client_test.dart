// SPDX-License-Identifier: GPL-3.0-or-later

// End-to-end handshake tests with an in-memory fake transport. No socket, no
// daemon, no Flutter binding required.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';

import 'support/fakes.dart';

Future<void> _pump() => Future<void>.delayed(Duration.zero);

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

class FakeTransport implements DaemonTransport {
  Uri? connectedEndpoint;
  final StreamController<String> _messages =
      StreamController<String>.broadcast();
  final StreamController<Object> _errors = StreamController<Object>.broadcast();
  final List<String> sent = <String>[];
  bool connected = false;

  @override
  Stream<String> get messages => _messages.stream;

  @override
  Stream<Object> get errors => _errors.stream;

  @override
  bool get isConnected => connected;

  @override
  Future<void> connect(Uri endpoint) async {
    connectedEndpoint = endpoint;
    connected = true;
  }

  @override
  void send(String frame) => sent.add(frame);

  @override
  Future<void> close() async {
    connected = false;
  }

  @override
  void dispose() {
    _messages.close();
    _errors.close();
  }

  void receive(String frame) => _messages.add(frame);

  void fail(Object error) => _errors.add(error);
}

void main() {
  test('configured CA path reaches the CA-aware transport factory', () async {
    String? capturedCa;
    final fake = FakeTransport();
    final client = DaemonClient(
      caAwareTransportFactory: ({String? caCertPath}) {
        capturedCa = caCertPath;
        return fake;
      },
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    await client.connect(
      const ConnectionSettings(
        host: 'lan.example',
        authToken: 'tok',
        caCertPath: '/tmp/gateway-ca.pem',
      ),
    );
    await _pump();
    expect(fake.connectedEndpoint!.scheme, 'wss');
    expect(capturedCa, '/tmp/gateway-ca.pem');
  });

  test('auth is the first frame, then core.status is probed', () async {
    final fake = FakeTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'tok'),
    );
    await _pump();

    expect(fake.sent, hasLength(1));
    expect(jsonDecode(fake.sent.first), <String, dynamic>{
      'type': 'auth',
      'authToken': 'tok',
    });
    expect(client.snapshot.state, DaemonConnectionState.authenticating);

    fake.receive('{"type":"auth","ok":true}');
    await _pump();

    expect(fake.sent, hasLength(2));
    final probe = jsonDecode(fake.sent[1]) as Map<String, dynamic>;
    expect(probe['type'], 'rpc');
    expect(probe['action'], 'core.status');
    expect(probe['id'], isA<int>());

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

    expect(client.snapshot.state, DaemonConnectionState.connected);
    expect(client.snapshot.core?.app, 'anima-daemon');
    expect(client.snapshot.core?.isHealthy, isTrue);
  });

  test(
    'auth rejection yields a terminal failed state with a clear reason',
    () async {
      final fake = FakeTransport();
      final client = DaemonClient(
        transportFactory: () => fake,
        authTimeout: const Duration(seconds: 2),
        rpcTimeout: const Duration(seconds: 2),
      );
      addTearDown(client.dispose);

      final connecting = client.connect(
        const ConnectionSettings(authToken: 'bad'),
      );
      await _pump();
      fake.receive(
        '{"type":"error","error":{"code":"invalid_token","message":"invalid token"}}',
      );
      await connecting;

      expect(client.snapshot.state, DaemonConnectionState.failed);
      expect(client.snapshot.error?.code, 'invalid_token');
      expect(fake.sent, hasLength(1)); // no RPC attempted before auth succeeds
    },
  );

  test('disconnect is explicit and does not reconnect', () async {
    final fake = FakeTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

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

    await client.disconnect();
    await _pump();

    expect(client.snapshot.state, DaemonConnectionState.disconnected);
    expect(client.snapshot.core, isNull);
    expect(fake.connected, isFalse);
    expect(
      client.call('runtime.ping'),
      throwsA(
        isA<DaemonClientException>().having(
          (e) => e.kind,
          'kind',
          DaemonFailureKind.notConnected,
        ),
      ),
    );
  });

  test('event frames reach the hook; client re-subscribes to token.delta after auth', () async {
    final fake = FakeTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    GatewayEventFrame? seen;
    final unsubscribe = client.onEvent((event) => seen = event);
    addTearDown(unsubscribe);

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

    fake.receive(
      '{"type":"event","topic":"status.changed","data":{"store_health":"ok"}}',
    );
    await _pump();

    expect(seen?.topic, EventTopic.statusChanged);
    final subscriptions = fake.sent
        .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
        .where((frame) => frame['action'] == 'event.subscribe')
        .toList();
    expect(subscriptions, hasLength(1));
    expect(subscriptions.first['payload'], <String, dynamic>{
      'topics': <String>['token.delta'],
    });
  });

  test('a reconnect re-subscribes on the fresh authenticated socket', () async {
    final transports = <FakeTransport>[];
    final client = DaemonClient(
      transportFactory: () {
        final transport = FakeTransport();
        transports.add(transport);
        return transport;
      },
      reconnectPolicy: const ReconnectPolicy(
        initialDelay: Duration(milliseconds: 10),
      ),
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'tok'),
    );
    await _pump();
    final first = transports.single;
    first.receive('{"type":"auth","ok":true}');
    await _pump();
    final probe = jsonDecode(first.sent[1]) as Map<String, dynamic>;
    first.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'core.status',
        'ok': true,
        'data': _healthyCore,
        'id': probe['id'],
      }),
    );
    await connecting;

    // Drop the authenticated socket; subscriptions are per-socket, so the
    // fresh peer must opt in again.
    first.fail(const TransportClosed());
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(transports, hasLength(2), reason: 'a fresh transport was opened');
    final fresh = transports.last;
    fresh.receive('{"type":"auth","ok":true}');
    await _pump();
    final freshProbe = jsonDecode(fresh.sent[1]) as Map<String, dynamic>;
    fresh.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'core.status',
        'ok': true,
        'data': _healthyCore,
        'id': freshProbe['id'],
      }),
    );
    await _pump();

    final subscriptions = transports
        .expand((transport) => transport.sent)
        .map((frame) => jsonDecode(frame) as Map<String, dynamic>)
        .where((frame) => frame['action'] == 'event.subscribe')
        .toList();
    expect(subscriptions, hasLength(2), reason: 'one per authenticated socket');
  });

  test('authenticated client pings on its heartbeat interval', () async {
    final fake = FakeTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
      heartbeatInterval: const Duration(milliseconds: 10),
    );
    addTearDown(client.dispose);

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

    // The daemon reaps a peer that sends nothing for DEAD_PEER_TTL (75 s), so
    // an authenticated client must keep the link warm without user activity.
    await Future<void>.delayed(const Duration(milliseconds: 45));
    final pings = fake.sent.where((f) => f.contains('"ping"')).length;
    expect(pings, greaterThanOrEqualTo(2));

    await client.disconnect();
    final afterDisconnect = fake.sent.length;
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(
      fake.sent.length,
      afterDisconnect,
      reason: 'heartbeat stops on disconnect',
    );
  });

  test('heartbeat does not start before authentication', () async {
    final fake = FakeTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
      heartbeatInterval: const Duration(milliseconds: 10),
    );
    addTearDown(client.dispose);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'tok'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 45));

    // Only the auth frame may be on the wire while unauthenticated.
    expect(fake.sent, hasLength(1));
    expect(jsonDecode(fake.sent.single)['type'], 'auth');

    fake.receive(
      '{"type":"error","error":{"code":"invalid_token","message":"no"}}',
    );
    await connecting;
  });

  // --- Verb wrappers (chat.cancel + completeness rows) ---------------------

  Future<(DaemonClient, FakeTransport)> connectedClient() async {
    final fake = FakeTransport();
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

  Map<String, dynamic> lastRequest(FakeTransport fake) =>
      jsonDecode(fake.sent.last) as Map<String, dynamic>;

  void reply(
    FakeTransport fake,
    Map<String, dynamic> request,
    Object? data, {
    bool ok = true,
  }) {
    fake.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': request['action'],
        'ok': ok,
        if (data != null) 'data': data,
        if (!ok)
          'error': <String, dynamic>{
            'code': 'rpc_error',
            'message': 'verb failed',
          },
        'id': request['id'],
      }),
    );
  }

  test(
    'cancelChat sends chat.cancel with session_id and reads cancelled',
    () async {
      final (client, fake) = await connectedClient();
      addTearDown(client.dispose);

      final pending = client.cancelChat('s1');
      final request = lastRequest(fake);
      expect(request['action'], 'chat.cancel');
      expect(request['payload'], <String, dynamic>{'session_id': 's1'});

      reply(fake, request, <String, dynamic>{'cancelled': true});
      expect(await pending, isTrue);
    },
  );

  test(
    'cancelChat surfaces a failed rpc reply as DaemonClientException',
    () async {
      final (client, fake) = await connectedClient();
      addTearDown(client.dispose);

      final pending = client.cancelChat('s1');
      reply(fake, lastRequest(fake), null, ok: false);
      await expectLater(
        pending,
        throwsA(
          isA<DaemonClientException>().having(
            (e) => e.kind,
            'kind',
            DaemonFailureKind.rpc,
          ),
        ),
      );
    },
  );

  test('list verbs decode their data arrays', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final cases =
        <(Future<List<Map<String, dynamic>>> Function(), String, String)>[
          (() => client.stmmList(), 'stmm.list', 'summaries'),
          (() => client.journalSearch(), 'journal.search', 'entries'),
          (() => client.cardsList(), 'cards.list', 'cards'),
          (() => client.sessionsList(), 'sessions.list', 'sessions'),
        ];
    for (final (invoke, action, key) in cases) {
      final pending = invoke();
      final request = lastRequest(fake);
      expect(request['action'], action);
      reply(fake, request, <String, dynamic>{
        key: <Map<String, dynamic>>[
          <String, dynamic>{'id': 'x'},
        ],
      });
      final rows = await pending;
      expect(rows, hasLength(1));
      expect(rows.first['id'], 'x');
    }
  });

  test('scalar verbs decode their reply fields', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    Future<T> run<T>(
      String action,
      Future<T> Function() invoke,
      Object? data,
      Object? expected,
    ) async {
      final pending = invoke();
      final request = lastRequest(fake);
      expect(request['action'], action);
      reply(fake, request, data);
      final value = await pending;
      expect(value, expected);
      return value;
    }

    await run(
      'journal.append',
      () => client.journalAppend('hi'),
      <String, dynamic>{'id': 'e1'},
      'e1',
    );
    await run('retrieval.status', client.retrievalStatus, <String, dynamic>{
      'available': true,
    }, true);
    await run('vault.status', client.vaultStatus, <String, dynamic>{
      'available': true,
      'stats': <String, dynamic>{'memory': <String, dynamic>{'summaries': 1}},
    }, <String, dynamic>{
      'available': true,
      'stats': <String, dynamic>{'memory': <String, dynamic>{'summaries': 1}},
    });
    await run(
      'sessions.export',
      () => client.sessionsExport('s1'),
      <String, dynamic>{'jsonl': '{}\n'},
      '{}\n',
    );
    // A missing session is a successful `false`, not an exception.
    await run(
      'sessions.delete',
      () => client.sessionsDelete('gone'),
      <String, dynamic>{'deleted': false},
      false,
    );
    expect(lastRequest(fake)['payload'], <String, dynamic>{
      'sessionId': 'gone',
    });
    await run(
      'sessions.delete',
      () => client.sessionsDelete('s1'),
      <String, dynamic>{'deleted': true},
      true,
    );
    expect(lastRequest(fake)['payload'], <String, dynamic>{'sessionId': 's1'});
    await run(
      'cards.get',
      () => client.cardsGet('c1'),
      <String, dynamic>{
        'card': <String, dynamic>{'id': 'c1'},
        'id': 'c1',
      },
      <String, dynamic>{'id': 'c1'},
    );

    for (final (action, invoke) in <(String, Future<void> Function())>[
      ('stmm.rebuild', client.stmmRebuild),
    ]) {
      final pending = invoke();
      final request = lastRequest(fake);
      expect(request['action'], action);
      reply(fake, request, <String, dynamic>{'ok': true});
      await pending;
    }

    final importing = client.cardsImport(card: <String, dynamic>{'id': 'c1'});
    final importRequest = lastRequest(fake);
    expect(importRequest['action'], 'cards.import');
    reply(fake, importRequest, <String, dynamic>{
      'id': 'c1',
      'name': 'One',
      'renamed': false,
    });
    final imported = await importing;
    expect(imported.id, 'c1');
  });

  test('card verbs send the fixed payloads and decode their replies', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    // cards.list pages with an explicit limit.
    final listing = client.cardsList(limit: 5);
    final listRequest = lastRequest(fake);
    expect(listRequest['action'], 'cards.list');
    expect(listRequest['payload'], <String, dynamic>{'limit': 5});
    reply(fake, listRequest, <String, dynamic>{
      'cards': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'c1', 'name': 'One'},
      ],
      'truncated': false,
    });
    expect((await listing).single['name'], 'One');

    // cards.create sends {name, document} and reads {id, name}.
    final document = <String, dynamic>{
      'name': 'One',
      'spec': 'chara_card_v2',
      'data': <String, dynamic>{'description': 'first'},
    };
    final creating = client.cardsCreate(document);
    final createRequest = lastRequest(fake);
    expect(createRequest['action'], 'cards.create');
    expect(createRequest['payload'], <String, dynamic>{
      'name': 'One',
      'document': document,
    });
    reply(fake, createRequest, <String, dynamic>{'id': 'c1', 'name': 'One'});
    final created = await creating;
    expect(created.id, 'c1');
    expect(created.name, 'One');
    expect(created.updated, isFalse);

    // cards.update sends {id, document} and requires updated:true.
    final updating = client.cardsUpdate('c1', <String, dynamic>{
      ...document,
      'data': <String, dynamic>{'description': 'second'},
    });
    final updateRequest = lastRequest(fake);
    expect(updateRequest['action'], 'cards.update');
    expect(updateRequest['payload'], <String, dynamic>{
      'id': 'c1',
      'document': <String, dynamic>{
        ...document,
        'data': <String, dynamic>{'description': 'second'},
      },
    });
    reply(fake, updateRequest, <String, dynamic>{
      'id': 'c1',
      'name': 'One',
      'updated': true,
    });
    final updated = await updating;
    expect(updated.updated, isTrue);
    expect(updated.id, 'c1');

    // cards.update without updated:true is a protocol error, not a false save.
    final lying = client.cardsUpdate('c1', document);
    reply(fake, lastRequest(fake), <String, dynamic>{
      'id': 'c1',
      'name': 'One',
      'updated': false,
    });
    await expectLater(
      lying,
      throwsA(
        isA<DaemonClientException>().having(
          (e) => e.kind,
          'kind',
          DaemonFailureKind.protocol,
        ),
      ),
    );

    // cards.import sends {card} (or {pngBase64}) and reads {id, name, renamed}.
    final importing = client.cardsImport(card: document);
    final importRequest = lastRequest(fake);
    expect(importRequest['action'], 'cards.import');
    expect(importRequest['payload'], <String, dynamic>{'card': document});
    reply(fake, importRequest, <String, dynamic>{
      'id': 'c2',
      'name': 'One (2)',
      'renamed': true,
    });
    final imported = await importing;
    expect(imported.id, 'c2');
    expect(imported.name, 'One (2)');
    expect(imported.renamed, isTrue);

    final importingPng = client.cardsImport(pngBase64: 'aGk=');
    final pngRequest = lastRequest(fake);
    expect(pngRequest['payload'], <String, dynamic>{'pngBase64': 'aGk='});
    reply(fake, pngRequest, <String, dynamic>{
      'id': 'c3',
      'name': 'Three',
      'renamed': false,
    });
    expect((await importingPng).name, 'Three');

    // cards.delete sends {id}; a missing card is a successful false.
    final deleting = client.cardsDelete('gone');
    final deleteRequest = lastRequest(fake);
    expect(deleteRequest['action'], 'cards.delete');
    expect(deleteRequest['payload'], <String, dynamic>{'id': 'gone'});
    reply(fake, deleteRequest, <String, dynamic>{'deleted': false});
    expect(await deleting, isFalse);

    final deletingExisting = client.cardsDelete('c1');
    reply(fake, lastRequest(fake), <String, dynamic>{'deleted': true});
    expect(await deletingExisting, isTrue);
  });

  test(
    'cards.import without a card or png is rejected before the wire',
    () async {
      final (client, fake) = await connectedClient();
      addTearDown(client.dispose);

      await expectLater(
        client.cardsImport(),
        throwsA(
          isA<DaemonClientException>().having(
            (e) => e.kind,
            'kind',
            DaemonFailureKind.protocol,
          ),
        ),
      );
      expect(
        fake.sent,
        hasLength(3),
        reason: 'auth + core.status + event.subscribe',
      );
    },
  );

  test(
    'chat.history decodes bare and wrapped payloads; rpc failure throws',
    () async {
      final (client, fake) = await connectedClient();
      addTearDown(client.dispose);

      final bare = client.chatHistory('s1');
      final bareRequest = lastRequest(fake);
      expect(bareRequest['action'], 'chat.history');
      expect(bareRequest['payload'], <String, dynamic>{'session_id': 's1'});
      reply(fake, bareRequest, <Object>[
        <String, dynamic>{'role': 'user', 'content': 'hi'},
      ]);
      expect(await bare, hasLength(1));

      final wrapped = client.chatHistory('s1');
      reply(fake, lastRequest(fake), <String, dynamic>{
        'messages': <Object>[
          <String, dynamic>{'role': 'assistant', 'content': 'yo'},
        ],
      });
      expect((await wrapped).single['content'], 'yo');

      final failing = client.chatHistory('s1');
      reply(fake, lastRequest(fake), null, ok: false);
      await expectLater(failing, throwsA(isA<DaemonClientException>()));
    },
  );

  test('settings.get decodes the JSON string; settings.set round-trips the section', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final reading = client.settingsGet('general');
    final getRequest = lastRequest(fake);
    expect(getRequest['action'], 'settings.get');
    expect(getRequest['payload'], <String, dynamic>{'section': 'general'});
    reply(fake, getRequest, <String, dynamic>{
      'section': 'general',
      'settings': '{"language":"en","remoteSyncEnabled":false}',
    });
    expect(await reading, <String, dynamic>{
      'language': 'en',
      'remoteSyncEnabled': false,
    });

    final writing = client.settingsSet('general', <String, dynamic>{
      'language': 'ja',
    });
    final setRequest = lastRequest(fake);
    expect(setRequest['action'], 'settings.set');
    expect(setRequest['payload']['section'], 'general');
    reply(fake, setRequest, <String, dynamic>{'ok': true});
    expect(await writing, isTrue);
  });

  test('providersModels decodes the reply and rejects a non-map payload', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final ok = client.providersModels('p1');
    final okRequest = lastRequest(fake);
    expect(okRequest['action'], 'providers.models');
    expect(okRequest['payload'], <String, dynamic>{'providerId': 'p1'});
    reply(fake, okRequest, <String, dynamic>{
      'providerId': 'p1',
      'models': <Map<String, dynamic>>[<String, dynamic>{'id': 'm1'}],
    });
    final decoded = await ok;
    expect(decoded.$1, 'p1');
    expect(decoded.$2, hasLength(1));
    expect(decoded.$2.first['id'], 'm1');

    // A non-map data payload is a protocol error, not a cast crash.
    final malformed = client.providersModels('p1');
    reply(fake, lastRequest(fake), <Object>['not', 'a', 'map']);
    await expectLater(
      malformed,
      throwsA(
        isA<DaemonClientException>().having(
          (e) => e.kind,
          'kind',
          DaemonFailureKind.protocol,
        ),
      ),
    );
  });

  // --- Vault archive and history media scrub verbs -------------------------

  test('vaultArchiveCollect sends allowed domains and decodes the reply', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final pending = client.vaultArchiveCollect(<String>['chats', 'memory']);
    final request = lastRequest(fake);
    expect(request['action'], 'vault.archive.collect');
    expect(request['payload'], <String, dynamic>{'domains': <String>['chats', 'memory']});
    reply(fake, request, <String, dynamic>{
      'archive': 'YWJj',
      'bytes': 3,
      'domains': <String>['chats', 'memory'],
    });
    final archive = await pending;
    expect(archive.archive, 'YWJj');
    expect(archive.bytes, 3);
    expect(archive.domains, <String>['chats', 'memory']);

    // Provider configuration carries credentials and must never cross the wire.
    expect(
      client.vaultArchiveCollect(<String>['providers']),
      throwsA(isA<DaemonClientException>()),
    );
    expect(
      fake.sent.map((f) => jsonDecode(f) as Map<String, dynamic>).where(
        (f) => f['action'] == 'vault.archive.collect',
      ).length,
      1,
      reason: 'no request reached the socket',
    );
  });

  test('vaultArchiveInspect decodes metadata only and refuses failed replies', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final pending = client.vaultArchiveInspect('YWJj');
    final request = lastRequest(fake);
    expect(request['action'], 'vault.archive.inspect');
    expect(request['payload'], <String, dynamic>{'archive': 'YWJj'});
    reply(fake, request, <String, dynamic>{
      'format': 'airi-vault',
      'version': 1,
      'createdAt': 1700000000000,
      'includesSecrets': false,
      'domains': <Map<String, dynamic>>[
        <String, dynamic>{'domain': 'chats', 'sessions': 1},
      ],
      'sessionCount': 1,
      'messageCount': 2,
      'companionNames': <String>['no-name-should-be-rendered'],
    });
    final report = await pending;
    expect(report.format, 'airi-vault');
    expect(report.version, 1);
    expect(report.createdAt, 1700000000000);
    expect(report.includesSecrets, isFalse);
    expect(report.sessionCount, 1);
    expect(report.messageCount, 2);
    expect(report.companionCount, 1);
    expect(report.domains.single['domain'], 'chats');

    final failing = client.vaultArchiveInspect('YWJj');
    reply(fake, lastRequest(fake), null, ok: false);
    await expectLater(
      failing,
      throwsA(
        isA<DaemonClientException>().having(
          (e) => e.kind,
          'kind',
          DaemonFailureKind.rpc,
        ),
      ),
    );
  });

  test('vaultArchiveApply and sessionsMediaScrub decode gated replies', () async {
    final (client, fake) = await connectedClient();
    addTearDown(client.dispose);

    final applying = client.vaultArchiveApply('YWJj');
    final applyRequest = lastRequest(fake);
    expect(applyRequest['action'], 'vault.archive.apply');
    expect(applyRequest['payload'], <String, dynamic>{'archive': 'YWJj'});
    reply(fake, applyRequest, <String, dynamic>{
      'sessionsInserted': 1,
      'sessionsSkipped': 2,
      'messagesInserted': 3,
      'messagesSkipped': 4,
      'summariesInserted': 5,
      'journalEntriesInserted': 6,
      'applied': <String>['chats', 'memory'],
      'notApplied': <String>['characters'],
    });
    final applied = await applying;
    expect(applied.sessionsInserted, 1);
    expect(applied.sessionsSkipped, 2);
    expect(applied.messagesInserted, 3);
    expect(applied.messagesSkipped, 4);
    expect(applied.summariesInserted, 5);
    expect(applied.journalEntriesInserted, 6);
    expect(applied.applied, <String>['chats', 'memory']);
    expect(applied.notApplied, <String>['characters']);

    final scrubbing = client.sessionsMediaScrub(createBackup: true);
    final scrubRequest = lastRequest(fake);
    expect(scrubRequest['action'], 'sessions.media.scrub');
    expect(scrubRequest['payload'], <String, dynamic>{'createBackup': true});
    reply(fake, scrubRequest, <String, dynamic>{
      'imagesFound': 2,
      'bytesExtracted': 128,
      'sessionsScanned': 1,
      'backupPath': '/tmp/backup.zip',
    });
    final scrubbed = await scrubbing;
    expect(scrubbed.imagesFound, 2);
    expect(scrubbed.bytesExtracted, 128);
    expect(scrubbed.sessionsScanned, 1);
    expect(scrubbed.backupPath, '/tmp/backup.zip');

    // A denial of a gated verb is an exception, never a successful zero report.
    final denied = client.sessionsMediaScrub(createBackup: false);
    reply(fake, lastRequest(fake), null, ok: false);
    await expectLater(
      denied,
      throwsA(
        isA<DaemonClientException>().having(
          (e) => e.kind,
          'kind',
          DaemonFailureKind.rpc,
        ),
      ),
    );
  });

  // --- Event subscribers and pre-auth transport recovery -------------------

  test('event listeners are independent and unsubscribe cleanly', () async {
    final fake = ScriptedTransport();
    final client = DaemonClient(
      transportFactory: () => fake,
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    final first = <GatewayEventFrame>[];
    final second = <GatewayEventFrame>[];
    final unsubscribeFirst = client.onEvent(first.add);
    client.onEvent(second.add);

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

    fake.receive(
      '{"type":"event","topic":"status.changed","data":{"store_health":"ok"}}',
    );
    await _pump();
    expect(first, hasLength(1));
    expect(second, hasLength(1));

    unsubscribeFirst();
    fake.receive(
      '{"type":"event","topic":"status.changed","data":{"store_health":"ok"}}',
    );
    await _pump();
    expect(first, hasLength(1), reason: 'unsubscribed listener stays quiet');
    expect(second, hasLength(2), reason: 'other listener keeps receiving');
  });

  test('a transport failure before auth retries on a fresh socket', () async {
    final transports = <ScriptedTransport>[];
    final client = DaemonClient(
      transportFactory: () {
        final transport = ScriptedTransport(
          connectError: transports.isEmpty ? const TransportClosed() : null,
        );
        transports.add(transport);
        return transport;
      },
      reconnectPolicy: const ReconnectPolicy(
        initialDelay: Duration(milliseconds: 10),
      ),
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    await client.connect(const ConnectionSettings(authToken: 'tok'));
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(transports, hasLength(2), reason: 'pre-auth transport errors retry');
    final fresh = transports.last;
    fresh.receive('{"type":"auth","ok":true}');
    await _pump();
    final probe = jsonDecode(fresh.sent[1]) as Map<String, dynamic>;
    fresh.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'core.status',
        'ok': true,
        'data': _healthyCore,
        'id': probe['id'],
      }),
    );
    await _pump();
    expect(client.snapshot.state, DaemonConnectionState.connected);
  });

  test('an auth rejection before auth is terminal and not retried', () async {
    var opened = 0;
    final fake = ScriptedTransport();
    final client = DaemonClient(
      transportFactory: () {
        opened++;
        return fake;
      },
      reconnectPolicy: const ReconnectPolicy(
        initialDelay: Duration(milliseconds: 10),
      ),
      authTimeout: const Duration(seconds: 2),
      rpcTimeout: const Duration(seconds: 2),
    );
    addTearDown(client.dispose);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'bad'),
    );
    await _pump();
    fake.receive(
      '{"type":"error","error":{"code":"invalid_token","message":"invalid token"}}',
    );
    await connecting;
    await Future<void>.delayed(const Duration(milliseconds: 40));

    expect(opened, 1, reason: 'a bad token is not retried');
    expect(client.snapshot.state, DaemonConnectionState.failed);
    expect(client.snapshot.error?.code, 'invalid_token');
  });
}
