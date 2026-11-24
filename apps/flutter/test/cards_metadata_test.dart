// SPDX-License-Identifier: GPL-3.0-or-later

// Card metadata (liked/bookmarked) is the only card verb surface wired in
// Flutter. The CRUD stub banner must stay; these tests cover reading metadata,
// toggling both flags via cards.metadata.set, and surfacing RPC failures
// (including allowActions-gated denials) without pretending success.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/cards/cards_screen.dart';

import 'support/fakes.dart';

class _RecordingCardsClient extends FakeChatClient {
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  bool liked = false;
  bool bookmarked = false;
  bool setFails = false;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    if (action == 'cards.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'cards': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
          ],
        },
      );
    }
    if (action == 'cards.get') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'card': <String, dynamic>{'id': 'card-1', 'name': 'Card One'},
        },
      );
    }
    if (action == 'cards.metadata') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'card-1',
          'liked': liked,
          'bookmarked': bookmarked
        },
      );
    }
    if (action == 'cards.metadata.set') {
      if (setFails) {
        return const RpcReply(
          action: 'cards.metadata.set',
          ok: false,
          error: RpcError(code: 'actions_disabled', message: 'actions off'),
        );
      }
      liked = payload?['liked'] == true;
      bookmarked = payload?['bookmarked'] == true;
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'card-1',
          'liked': liked,
          'bookmarked': bookmarked
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }

  @override
  Future<List<Map<String, dynamic>>> cardsList() async {
    final reply = await call('cards.list');
    return (reply.data as Map<String, dynamic>)['cards']
        as List<Map<String, dynamic>>;
  }

  @override
  Future<Map<String, dynamic>?> cardsGet(String id) async {
    final reply = await call('cards.get', payload: <String, dynamic>{'id': id});
    return (reply.data as Map<String, dynamic>)['card'] as Map<String, dynamic>;
  }

  @override
  Future<({String id, bool liked, bool bookmarked})> cardsMetadata(
      String id) async {
    final reply =
        await call('cards.metadata', payload: <String, dynamic>{'id': id});
    final data = reply.data as Map<String, dynamic>;
    return (
      id: data['id'] as String,
      liked: data['liked'] as bool,
      bookmarked: data['bookmarked'] as bool
    );
  }

  @override
  Future<({String id, bool liked, bool bookmarked})> cardsMetadataSet(
    String id, {
    required bool liked,
    required bool bookmarked,
  }) async {
    final reply = await call('cards.metadata.set', payload: <String, dynamic>{
      'id': id,
      'liked': liked,
      'bookmarked': bookmarked,
    });
    if (!reply.ok) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: reply.error?.message ?? 'cards.metadata.set failed',
      );
    }
    final data = reply.data as Map<String, dynamic>;
    return (
      id: data['id'] as String,
      liked: data['liked'] as bool,
      bookmarked: data['bookmarked'] as bool
    );
  }
}

Future<_RecordingCardsClient> _pump(tester) async {
  final client = _RecordingCardsClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: CardsScreen(client: client))));
  await tester.pump();
  return client;
}

Future<void> _openCard(tester) async {
  tester.widget<ListTile>(find.widgetWithText(ListTile, 'Card One')).onTap!();
  await tester.pump();
}

void main() {
  testWidgets('card detail reads metadata from cards.metadata', (tester) async {
    final client = await _pump(tester);

    await _openCard(tester);

    expect(
      client.calls.where((c) => c.action == 'cards.metadata'),
      hasLength(1),
    );
    expect(find.widgetWithText(CheckboxListTile, 'Liked'), findsOneWidget);
  });

  testWidgets('toggling liked writes explicit liked + bookmarked flags',
      (tester) async {
    final client = await _pump(tester);
    await _openCard(tester);

    tester
        .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Liked'))
        .onChanged!(true);
    await tester.pump();

    final setCall =
        client.calls.firstWhere((c) => c.action == 'cards.metadata.set');
    expect(setCall.payload, <String, dynamic>{
      'id': 'card-1',
      'liked': true,
      'bookmarked': false,
    });
  });

  testWidgets('cards.metadata.set failure surfaces the error and keeps state',
      (tester) async {
    final client = await _pump(tester);
    client.setFails = true;
    await _openCard(tester);

    tester
        .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Liked'))
        .onChanged!(true);
    await tester.pump();

    expect(find.text('actions off'), findsOneWidget);
    // The toggle was not applied locally either: no false success.
    expect(
      tester
          .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Liked'))
          .value,
      isFalse,
    );
  });

  testWidgets('CRUD stub banner stays visible', (tester) async {
    await _pump(tester);

    expect(
      find.text('Card management is not available on the local daemon.'),
      findsOneWidget,
    );
  });
}
