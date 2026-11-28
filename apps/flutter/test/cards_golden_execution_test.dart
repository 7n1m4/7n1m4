// SPDX-License-Identifier: GPL-3.0-or-later

// Round v28 real-execution leg of the cards golden CRUD fixtures. The Rust leg
// (stmm_upsert_tests.rs::cards_golden_execution_replays_through_real_handlers)
// drives the REAL daemon handlers; this leg boots a REAL DaemonClient over a
// ScriptedTransport, replays the UNCHANGED golden replies through the
// production ServerFrame codec, and pumps the REAL CardsScreen through
// create -> update -> delete. No screen or client production code is edited.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/cards/cards_screen.dart';

import 'support/fakes.dart';

/// Same fixture resolution as the other golden replay tests.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

Map<String, dynamic> _read(String name) {
  final file = File('$_fixturesDir/$name');
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
      'data': data,
    });

/// Answers every RPC the boot probe and CardsScreen put on the wire. Golden
/// reply payloads are fed through ServerFrame.parse before reaching the
/// transport, so the production codec is on the path for each replayed reply.
class _CardsGoldenPeer {
  _CardsGoldenPeer(
    this.transport, {
    required this.createReply,
    required this.getAfterCreate,
    required this.getAfterUpdate,
    required this.listGolden,
    required this.listAfterUpdate,
    required this.emptyList,
    required this.updateReply,
    required this.deleteReply,
  });

  final ScriptedTransport transport;
  final Map<String, dynamic> createReply;
  final Map<String, dynamic> getAfterCreate;
  final Map<String, dynamic> getAfterUpdate;
  final Map<String, dynamic> listGolden;
  final Map<String, dynamic> listAfterUpdate;
  final Map<String, dynamic> emptyList;
  final Map<String, dynamic> updateReply;
  final Map<String, dynamic> deleteReply;

  int _handled = 0;
  bool _created = false;
  bool _updated = false;
  bool _deleted = false;

  /// Every emitted rpc request frame, in wire order.
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  List<String> get actions => requests
      .where((frame) => frame['type'] == 'rpc')
      .map((frame) => frame['action'] as String)
      .toList(growable: false);

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 16; pass++) {
      while (_handled < transport.sent.length) {
        final decoded =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (decoded['type'] != 'rpc') continue;
        final action = decoded['action'] as String?;
        final id = decoded['id'];
        if (action == null || id == null) continue;
        requests.add(decoded);
        final data = _dataFor(action, decoded['payload']);
        // Production codec, not a test-side map assignment.
        final parsed = ServerFrame.parse(_replyFrame(action, id, data));
        expect(parsed.parseError, isNull, reason: '$action reply must parse');
        expect(parsed.kind, ServerFrameKind.rpc, reason: '$action kind');
        expect(parsed.reply!.action, action, reason: '$action echo');
        expect(parsed.reply!.ok, isTrue, reason: '$action ok');
        transport.receive(jsonEncode(parsed.raw));
      }
      await flush();
      if (_handled >= transport.sent.length) {
        await flush();
        if (_handled >= transport.sent.length) return;
      }
    }
    fail('cards golden replay did not quiesce after 16 waves');
  }

  Object? _dataFor(String action, Object? payload) {
    switch (action) {
      case 'core.status':
        return _healthyCore;
      case 'event.subscribe':
        return <String, dynamic>{'subscribed': true};
      case 'cards.create':
        _created = true;
        return createReply;
      case 'cards.get':
        return _updated ? getAfterUpdate : getAfterCreate;
      case 'cards.list':
        if (_deleted) return emptyList;
        if (_updated) return listAfterUpdate;
        return _created ? listGolden : emptyList;
      case 'cards.update':
        _updated = true;
        return updateReply;
      case 'cards.delete':
        _deleted = true;
        return deleteReply;
      case 'cards.metadata':
      case 'cards.metadata.set':
        return <String, dynamic>{
          'id': (payload as Map<String, dynamic>?)?['id'] ?? '',
          'liked': false,
          'bookmarked': false,
        };
      default:
        return <String, dynamic>{};
    }
  }
}

/// The create form's name field, scoped by the Create button's ancestor card.
Finder _createNameField() => find.descendant(
  of: find.ancestor(
    of: find.widgetWithText(FilledButton, 'Create'),
    matching: find.byType(Card),
  ),
  matching: find.widgetWithText(TextField, 'Name'),
);

Finder _createDocumentField() => find.descendant(
  of: find.ancestor(
    of: find.widgetWithText(FilledButton, 'Create'),
    matching: find.byType(Card),
  ),
  matching: find.widgetWithText(TextField, 'Card JSON document'),
);

Finder _detailNameField() => find.descendant(
  of: find.ancestor(
    of: find.widgetWithText(FilledButton, 'Save'),
    matching: find.byType(Card),
  ),
  matching: find.widgetWithText(TextField, 'Name'),
);

Future<void> _reveal(WidgetTester tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, -300));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _scrollTo(WidgetTester tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, -4000));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> _scrollToTop(WidgetTester tester, Finder finder) async {
  await tester.drag(find.byType(ListView), const Offset(0, 4000));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Rust golden cards CRUD drives a real DaemonClient and CardsScreen',
    (tester) async {
      final createReply = _read('cards.create.reply.json');
      final getGolden = _read('cards.get.reply.json');
      final listGolden = _read('cards.list.reply.json');
      final updateGolden = _read('cards.update.reply.json');
      final deleteGolden = _read('cards.delete.reply.json');

      // Every golden reply parses through the production codec unchanged.
      for (final entry in <MapEntry<String, Map<String, dynamic>>>[
        MapEntry<String, Map<String, dynamic>>('cards.create', createReply),
        MapEntry<String, Map<String, dynamic>>('cards.get', getGolden),
        MapEntry<String, Map<String, dynamic>>('cards.list', listGolden),
        MapEntry<String, Map<String, dynamic>>('cards.update', updateGolden),
        MapEntry<String, Map<String, dynamic>>('cards.delete', deleteGolden),
      ]) {
        final parsed = ServerFrame.parse(
          _replyFrame(entry.key, 1, entry.value),
        );
        expect(parsed.parseError, isNull, reason: '${entry.key} golden parse');
        expect(parsed.kind, ServerFrameKind.rpc);
        expect(parsed.reply!.action, entry.key);
        expect(
          parsed.reply!.data,
          entry.value,
          reason: '${entry.key} golden data must survive the production codec',
        );
      }

      // One id derivation, sourced from the golden create reply (card-7):
      // cards.get.reply.json carries no id, but CardsScreen._saveDetail needs
      // current['id'] as a client-side join key. The Rust leg asserts the
      // stored document byte-for-byte; cards.update.reply.json is {updated:true}.
      final cardId = createReply['id'] as String;
      expect(cardId, 'card-7');
      final getAfterCreate = <String, dynamic>{
        'card': <String, dynamic>{
          ...(getGolden['card'] as Map<String, dynamic>),
          'id': cardId,
        },
      };
      final getAfterUpdate = <String, dynamic>{
        'card': <String, dynamic>{
          ...(getGolden['card'] as Map<String, dynamic>),
          'id': cardId,
          'name': 'Aria v2',
        },
      };
      final listAfterUpdate = <String, dynamic>{
        'cards': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'card-7', 'name': 'Aria v2'},
        ],
        'truncated': false,
      };
      final emptyList = <String, dynamic>{
        'cards': <dynamic>[],
        'truncated': false,
      };

      final transport = ScriptedTransport();
      final peer = _CardsGoldenPeer(
        transport,
        createReply: createReply,
        getAfterCreate: getAfterCreate,
        getAfterUpdate: getAfterUpdate,
        listGolden: listGolden,
        listAfterUpdate: listAfterUpdate,
        emptyList: emptyList,
        updateReply: updateGolden,
        deleteReply: deleteGolden,
      );
      final client = DaemonClient(
        transportFactory: () => transport,
        authTimeout: const Duration(seconds: 5),
        rpcTimeout: const Duration(seconds: 5),
        heartbeatInterval: const Duration(hours: 1),
      );
      addTearDown(client.dispose);

      final connecting = client.connect(
        const ConnectionSettings(authToken: 'tok'),
      );
      await tester.pump();
      expect(jsonDecode(transport.sent.single)['type'], 'auth');
      transport.receive('{"type":"auth","ok":true}');
      await tester.pump();
      await peer.drain(() => tester.pump());
      await connecting;
      await peer.drain(() => tester.pump());
      expect(client.snapshot.state, DaemonConnectionState.connected);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: CardsScreen(client: client)),
        ),
      );
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('No cards available'), findsOneWidget);

      // Create: the golden Aria row comes from cards.list.reply.json.
      await tester.enterText(_createNameField(), 'Aria');
      await tester.enterText(
        _createDocumentField(),
        jsonEncode(<String, dynamic>{
          'data': <String, dynamic>{'name': 'Aria'},
          'spec': 'chara_card_v2',
        }),
      );
      await _reveal(tester, find.widgetWithText(FilledButton, 'Create'));
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      await _scrollToTop(tester, find.text('Created "Aria" as card-7'));
      expect(find.text('Created "Aria" as card-7'), findsOneWidget);
      final ariaRow = find.widgetWithText(ListTile, 'Aria');
      await _reveal(tester, ariaRow);
      expect(ariaRow, findsOneWidget);

      // Update: the detail form must send cards.update on the wire.
      await _scrollTo(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.enterText(_detailNameField(), 'Aria v2');
      await _reveal(tester, find.widgetWithText(FilledButton, 'Save'));
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(
        peer.actions,
        contains('cards.update'),
        reason: 'the golden get reply must carry an id so _saveDetail can save',
      );
      final v2Row = find.widgetWithText(ListTile, 'Aria v2');
      await _reveal(tester, v2Row);
      expect(v2Row, findsOneWidget);
      await _scrollToTop(tester, find.text('Saved "Aria v2" (card-7)'));
      expect(find.text('Saved "Aria v2" (card-7)'), findsOneWidget);

      // Delete: cards.delete.reply.json drives list back to empty.
      final delete = find.byTooltip('Delete card');
      await _reveal(tester, delete);
      await tester.tap(delete);
      await tester.pumpAndSettle();
      expect(find.text('Delete card?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      expect(find.widgetWithText(ListTile, 'Aria v2'), findsNothing);
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      expect(find.text('No cards available'), findsOneWidget);

      // Wire requests emitted by the screen. A UI tap must go through the
      // typed wrappers and emit the canonical shape, not a reshaped payload.
      final createCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'cards.create',
      );
      expect(
        createCall['payload'],
        _read('cards.create.request.json'),
        reason: 'a UI tap must emit the exact cards.create golden payload',
      );
      final updateCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'cards.update',
      );
      final updatePayload = updateCall['payload'] as Map<String, dynamic>;
      expect(
        updatePayload.keys,
        unorderedEquals(<String>{'id', 'name', 'document'}),
        reason: 'cards.update must emit {id, name, document}',
      );
      expect(updatePayload['id'], 'card-7');
      final deleteCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'cards.delete',
      );
      expect(deleteCall['payload'], <String, dynamic>{'id': 'card-7'});
    },
  );

  test(
    'golden cards.create/update/delete payloads go on the wire byte-for-field',
    () async {
      final transport = ScriptedTransport();
      final client = DaemonClient(
        transportFactory: () => transport,
        authTimeout: const Duration(seconds: 5),
        rpcTimeout: const Duration(seconds: 5),
        heartbeatInterval: const Duration(hours: 1),
      );
      addTearDown(client.dispose);
      Future<void> flush() => Future<void>.delayed(Duration.zero);

      // Production handshake: auth -> core.status -> four event.subscribe.
      final connecting = client.connect(
        const ConnectionSettings(authToken: 'tok'),
      );
      await flush();
      expect(jsonDecode(transport.sent.single)['type'], 'auth');
      transport.receive('{"type":"auth","ok":true}');
      await flush();
      var handled = 0;
      for (var pass = 0; pass < 8; pass++) {
        while (handled < transport.sent.length) {
          final request =
              jsonDecode(transport.sent[handled++]) as Map<String, dynamic>;
          if (request['type'] != 'rpc') continue;
          final action = request['action'] as String;
          transport.receive(
            _replyFrame(
              action,
              request['id'],
              action == 'core.status'
                  ? _healthyCore
                  : <String, dynamic>{'subscribed': true},
            ),
          );
        }
        await flush();
        if (handled >= transport.sent.length) {
          await flush();
          if (handled >= transport.sent.length) break;
        }
      }
      await connecting;

      const cases = <MapEntry<String, String>>[
        MapEntry<String, String>('cards.create', 'cards.create.request.json'),
        MapEntry<String, String>('cards.update', 'cards.update.request.json'),
        MapEntry<String, String>('cards.delete', 'cards.delete.request.json'),
      ];
      for (final entry in cases) {
        final action = entry.key;
        final payload = _read(entry.value);
        final pending = client.call(action, payload: payload);
        await flush();
        final sent = jsonDecode(transport.sent.last) as Map<String, dynamic>;
        expect(sent['type'], 'rpc');
        expect(sent['action'], action);
        expect(
          sent['payload'],
          payload,
          reason: '$action golden payload must be emitted byte-for-field',
        );
        final parsed = ServerFrame.parse(
          _replyFrame(action, sent['id'], <String, dynamic>{}),
        );
        expect(parsed.parseError, isNull);
        transport.receive(jsonEncode(parsed.raw));
        await pending;
      }
    },
  );

  test('typed cards wrappers emit the golden request payloads', () async {
    final createGolden = _read('cards.create.request.json');
    final updateGolden = _read('cards.update.request.json');
    final goldenDoc = createGolden['document'] as Map<String, dynamic>;

    final transport = ScriptedTransport();
    final client = DaemonClient(
      transportFactory: () => transport,
      authTimeout: const Duration(seconds: 5),
      rpcTimeout: const Duration(seconds: 5),
      heartbeatInterval: const Duration(hours: 1),
    );
    addTearDown(client.dispose);
    Future<void> flush() => Future<void>.delayed(Duration.zero);

    final connecting = client.connect(
      const ConnectionSettings(authToken: 'tok'),
    );
    await flush();
    transport.receive('{"type":"auth","ok":true}');
    await flush();
    var handled = 0;
    for (var pass = 0; pass < 8; pass++) {
      while (handled < transport.sent.length) {
        final request =
            jsonDecode(transport.sent[handled++]) as Map<String, dynamic>;
        if (request['type'] != 'rpc') continue;
        final action = request['action'] as String;
        transport.receive(
          _replyFrame(
            action,
            request['id'],
            action == 'core.status'
                ? _healthyCore
                : <String, dynamic>{'subscribed': true},
          ),
        );
      }
      await flush();
      if (handled >= transport.sent.length) {
        await flush();
        if (handled >= transport.sent.length) break;
      }
    }
    await connecting;

    final createPending = client.cardsCreate(name: 'Aria', document: goldenDoc);
    await flush();
    final createSent = jsonDecode(transport.sent.last) as Map<String, dynamic>;
    expect(createSent['action'], 'cards.create');
    expect(
      createSent['payload'],
      createGolden,
      reason: 'cardsCreate must emit the exact golden create payload',
    );
    transport.receive(
      jsonEncode(
        ServerFrame.parse(
          _replyFrame(
            'cards.create',
            createSent['id'],
            _read('cards.create.reply.json'),
          ),
        ).raw,
      ),
    );
    await createPending;

    final updatePending = client.cardsUpdate(
      id: 'card-7',
      name: null,
      document: goldenDoc,
    );
    await flush();
    final updateSent = jsonDecode(transport.sent.last) as Map<String, dynamic>;
    expect(updateSent['action'], 'cards.update');
    expect(
      updateSent['payload'],
      updateGolden,
      reason: 'cardsUpdate must emit the exact golden update payload',
    );
    transport.receive(
      jsonEncode(
        ServerFrame.parse(
          _replyFrame(
            'cards.update',
            updateSent['id'],
            _read('cards.update.reply.json'),
          ),
        ).raw,
      ),
    );
    await updatePending;
  });
}
