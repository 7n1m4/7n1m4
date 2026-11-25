// SPDX-License-Identifier: GPL-3.0-or-later

// Card metadata (liked/bookmarked) is the only card verb surface wired in
// Flutter. The CRUD stub banner must stay; these tests drive the production
// cards screen and the real DaemonClient wrappers (through `call`, which every
// typed wrapper uses) so they fail if either surface disappears.

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
    if (action == 'cards.list' || action == 'cards.get') {
      final card = <String, dynamic>{'id': 'card-1', 'name': 'Card One'};
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          if (action == 'cards.list')
            'cards': <Map<String, dynamic>>[card]
          else
            'card': card,
        },
      );
    }
    if (action == 'cards.metadata' || action == 'cards.metadata.set') {
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
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'card-1',
          'liked': liked,
          'bookmarked': bookmarked,
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_RecordingCardsClient> _pump(tester) async {
  final client = _RecordingCardsClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: CardsScreen(client: client)),
    ),
  );
  await tester.pump();
  return client;
}

Future<void> _openCard(tester) async {
  await tester.tap(find.widgetWithText(ListTile, 'Card One'));
  await tester.pumpAndSettle();
}

Future<void> _toggle(tester, String label) async {
  await tester.tap(find.widgetWithText(CheckboxListTile, label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('card detail reads metadata through the real client wrapper', (
    tester,
  ) async {
    final client = await _pump(tester);

    await _openCard(tester);

    final read = client.calls
        .where((c) => c.action == 'cards.metadata')
        .toList();
    expect(read, hasLength(1));
    expect(read.single.payload, <String, dynamic>{'id': 'card-1'});
    expect(find.widgetWithText(CheckboxListTile, 'Liked'), findsOneWidget);
    expect(find.widgetWithText(CheckboxListTile, 'Bookmarked'), findsOneWidget);
  });

  testWidgets('toggling liked writes explicit liked + bookmarked flags', (
    tester,
  ) async {
    final client = await _pump(tester);
    await _openCard(tester);

    await _toggle(tester, 'Liked');

    final setCall = client.calls.firstWhere(
      (c) => c.action == 'cards.metadata.set',
    );
    expect(setCall.payload, <String, dynamic>{
      'id': 'card-1',
      'liked': true,
      'bookmarked': false,
    });
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Liked'),
          )
          .value,
      isTrue,
    );
  });

  testWidgets('toggling bookmark writes the current liked flag', (tester) async {
    final client = await _pump(tester);
    await _openCard(tester);
    await _toggle(tester, 'Liked');

    await _toggle(tester, 'Bookmarked');

    final setCalls =
        client.calls.where((c) => c.action == 'cards.metadata.set').toList();
    expect(setCalls.last.payload, <String, dynamic>{
      'id': 'card-1',
      'liked': true,
      'bookmarked': true,
    });
  });

  testWidgets('cards.metadata.set failure surfaces the error and keeps state',
      (tester) async {
    final client = await _pump(tester);
    client.setFails = true;
    await _openCard(tester);

    await _toggle(tester, 'Liked');

    expect(find.text('actions off'), findsOneWidget);
    expect(
      tester
          .widget<CheckboxListTile>(
            find.widgetWithText(CheckboxListTile, 'Liked'),
          )
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
