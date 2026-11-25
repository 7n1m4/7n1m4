// SPDX-License-Identifier: GPL-3.0-or-later

// Chat character context parity: the context bar exposes the daemon-owned
// liked/bookmarked metadata for the selected card through the real
// DaemonClient wrappers (`cards.metadata` / `cards.metadata.set`). The client
// never flips a flag on its own: both flags are always written, and a failed
// write surfaces the daemon error while the shown state stays as the daemon
// last confirmed it.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';

import 'support/fakes.dart';

class _MetadataClient extends FakeChatClient {
  _MetadataClient({this.cards = const <Map<String, dynamic>>[]});

  final List<Map<String, dynamic>> cards;
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  bool liked = false;
  bool bookmarked = false;
  bool setFails = false;
  bool metadataFails = false;
  final Map<String, ({bool liked, bool bookmarked})> byCard =
      <String, ({bool liked, bool bookmarked})>{};
  Completer<void>? metadataGate;
  Completer<void>? setGate;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'sessions': <Map<String, dynamic>>[]},
      );
    }
    if (action == 'cards.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'cards': cards},
      );
    }
    if (action == 'settings.get') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'settings': <String, dynamic>{}},
      );
    }
    if (action == 'cards.metadata' || action == 'cards.metadata.set') {
      if (action == 'cards.metadata.set') {
        if (setFails) {
          return RpcReply(
            action: action,
            ok: false,
            error: const RpcError(
              code: 'actions_disabled',
              message: 'actions off',
            ),
          );
        }
        final gate = setGate;
        if (gate != null) await gate.future;
        liked = payload?['liked'] == true;
        bookmarked = payload?['bookmarked'] == true;
        byCard[(payload?['id'] as String?) ?? 'card-1'] = (
          liked: liked,
          bookmarked: bookmarked,
        );
      } else {
        if (metadataFails) {
          return RpcReply(
            action: action,
            ok: false,
            error: const RpcError(code: 'internal', message: 'metadata gone'),
          );
        }
        final gate = metadataGate;
        if (gate != null) await gate.future;
        final id = (payload?['id'] as String?) ?? 'card-1';
        final stored = byCard[id];
        liked = stored?.liked ?? false;
        bookmarked = stored?.bookmarked ?? false;
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': (payload?['id'] as String?) ?? 'card-1',
          'liked': liked,
          'bookmarked': bookmarked,
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_MetadataClient> _pump(
  WidgetTester tester, {
  List<Map<String, dynamic>> cards = const <Map<String, dynamic>>[
    <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
  ],
}) async {
  final client = _MetadataClient(cards: cards);
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: ChatScreen(client: client)),
    ),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  testWidgets('context bar reads metadata for the selected character', (
    tester,
  ) async {
    final client = await _pump(tester);

    final read = client.calls
        .where((c) => c.action == 'cards.metadata')
        .toList();
    expect(read, hasLength(1));
    expect(read.single.payload, <String, dynamic>{'id': 'card-1'});
    expect(find.byKey(const Key('chat-character-liked')), findsOneWidget);
    expect(find.byKey(const Key('chat-character-bookmarked')), findsOneWidget);
    expect(find.text('Not liked'), findsOneWidget);
  });

  testWidgets('no metadata row without a selected character', (tester) async {
    await _pump(tester, cards: const <Map<String, dynamic>>[]);

    expect(find.byKey(const Key('chat-character-metadata')), findsNothing);
  });

  testWidgets('liking writes both flags explicitly', (tester) async {
    final client = await _pump(tester);

    await tester.tap(find.byKey(const Key('chat-character-liked')));
    await tester.pump();
    await tester.pump();

    final write = client.calls
        .where((c) => c.action == 'cards.metadata.set')
        .single;
    expect(write.payload, <String, dynamic>{
      'id': 'card-1',
      'liked': true,
      'bookmarked': false,
    });
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('chat-character-liked')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('Liked'), findsOneWidget);
  });

  testWidgets('bookmarking keeps the confirmed liked flag', (tester) async {
    final client = await _pump(tester);

    await tester.tap(find.byKey(const Key('chat-character-liked')));
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const Key('chat-character-bookmarked')));
    await tester.pump();
    await tester.pump();

    final writes = client.calls
        .where((c) => c.action == 'cards.metadata.set')
        .toList();
    expect(writes.last.payload, <String, dynamic>{
      'id': 'card-1',
      'liked': true,
      'bookmarked': true,
    });
  });

  testWidgets('a failed write surfaces the error and keeps confirmed state', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.setFails = true;

    await tester.tap(find.byKey(const Key('chat-character-liked')));
    await tester.pump();
    await tester.pump();

    expect(find.text('actions off'), findsOneWidget);
    expect(find.text('Not liked'), findsOneWidget);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('chat-character-liked')))
          .onPressed,
      isNotNull,
      reason: 'the toggle is usable again after the failure',
    );
  });

  testWidgets(
    'a failed metadata read shows the error and no fabricated flags',
    (tester) async {
      final client = _MetadataClient(
        cards: const <Map<String, dynamic>>[
          <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
        ],
      );
      addTearDown(client.dispose);
      client.metadataFails = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ChatScreen(client: client)),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('metadata gone'), findsOneWidget);
      expect(find.byKey(const Key('chat-character-metadata')), findsNothing);
    },
  );

  testWidgets('switching character reloads metadata for the new card', (
    tester,
  ) async {
    final client = _MetadataClient(
      cards: const <Map<String, dynamic>>[
        <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
        <String, dynamic>{'id': 'card-2', 'name': 'Card Two'},
      ],
    );
    addTearDown(client.dispose);
    client.byCard['card-1'] = (liked: true, bookmarked: false);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ChatScreen(client: client)),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Liked'), findsOneWidget);

    await tester.tap(find.byKey(const Key('chat-character-dropdown')));
    await tester.pumpAndSettle();
    final cardTwo = find.text('Card Two');
    expect(cardTwo, findsOneWidget);
    await tester.tap(cardTwo);
    await tester.pump();
    await tester.pump();

    final reads = client.calls
        .where((c) => c.action == 'cards.metadata')
        .toList();
    expect(reads.last.payload, <String, dynamic>{'id': 'card-2'});
    // card-2 has no stored metadata of its own: the daemon's answer replaces
    // card-1's liked flag instead of the client guessing it.
    expect(find.text('Not liked'), findsOneWidget);
    await tester.tap(find.byKey(const Key('chat-character-liked')));
    await tester.pump();
    await tester.pump();
    expect(
      client.calls
          .where((c) => c.action == 'cards.metadata.set')
          .single
          .payload,
      <String, dynamic>{'id': 'card-2', 'liked': true, 'bookmarked': false},
      reason: 'the write targets the newly selected card, not card-1',
    );
  });

  testWidgets('toggles are disabled while a write is in flight', (
    tester,
  ) async {
    final client = await _pump(tester);
    final gate = Completer<void>();
    client.setGate = gate;

    await tester.tap(find.byKey(const Key('chat-character-liked')));
    await tester.pump();

    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('chat-character-liked')))
          .onPressed,
      isNull,
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    gate.complete();
    await tester.pump();
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('chat-character-liked')))
          .onPressed,
      isNotNull,
    );
  });
}
