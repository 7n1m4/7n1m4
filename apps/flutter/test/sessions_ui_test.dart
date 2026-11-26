// SPDX-License-Identifier: GPL-3.0-or-later

// Sessions UI breadth: filtering is local presentation over the daemon's
// sessions.list result, and the new-chat action opens a fresh ChatScreen
// without writing session state from the client.

import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';
import 'package:anima_control/features/sessions/sessions_screen.dart';

import 'support/fakes.dart';

class _DeferredReply implements Exception {
  const _DeferredReply(this.future);
  final Future<RpcReply> future;
}

class _SessionsUiClient extends FakeChatClient {
  final List<String> actions = <String>[];
  final List<Map<String, dynamic>?> listPayloads = <Map<String, dynamic>?>[];
  int listCalls = 0;

  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    final handler = onCall;
    if (handler != null) {
      try {
        return handler(action, payload);
      } on _DeferredReply catch (deferred) {
        return await deferred.future;
      }
    }
    if (action == 'sessions.list') {
      listPayloads.add(payload);
      listCalls++;
      final cursor = payload?['cursor'];
      if (cursor != null) {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'sessions': <Map<String, dynamic>>[
              <String, dynamic>{'id': 'gamma', 'title': 'Gamma session'},
            ],
            'truncated': false,
          },
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'alpha', 'title': 'Alpha session'},
            <String, dynamic>{'id': 'beta', 'title': 'Beta session'},
          ],
          'truncated': true,
          'cursor': <String, dynamic>{'updatedAt': 200, 'rowId': 11},
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_SessionsUiClient> _pump(tester) async {
  final client = _SessionsUiClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: SessionsScreen(client: client))),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

void main() {
  testWidgets('filter narrows sessions by title and id', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('sessions-filter')),
      'Beta',
    );
    await tester.pump();

    expect(find.widgetWithText(ListTile, 'Alpha session'), findsNothing);
    expect(find.widgetWithText(ListTile, 'Beta session'), findsOneWidget);
  });

  testWidgets('a filter with no matches reports no matches', (tester) async {
    await _pump(tester);
    await tester.enterText(
      find.byKey(const Key('sessions-filter')),
      'missing',
    );
    await tester.pump();

    expect(find.text('No sessions match the filter'), findsOneWidget);
  });

  testWidgets('new chat opens a blank ChatScreen without a delete RPC', (
    tester,
  ) async {
    final client = await _pump(tester);
    tester.widget<IconButton>(find.byKey(const Key('sessions-new-chat'))).onPressed!();
    await tester.pumpAndSettle();

    expect(find.byType(ChatScreen), findsOneWidget);
    expect(client.actions, isNot(contains('sessions.delete')));
  });
  testWidgets('truncated sessions list offers a load-more page', (
    tester,
  ) async {
    final client = await _pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    final more = find.byKey(const Key('sessions-load-more'));
    expect(more, findsOneWidget);

    tester.widget<TextButton>(more).onPressed!();
    await tester.pump();
    await tester.pump();

    expect(client.listPayloads.last?['cursor'],
        <String, dynamic>{'updatedAt': 200, 'rowId': 11});
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Gamma session'), findsOneWidget);
    expect(more, findsNothing);
  });

  testWidgets('older sessions append after newer rows', (tester) async {
    final client = await _pump(tester);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    tester.widget<TextButton>(find.byKey(const Key('sessions-load-more'))).onPressed!();
    await tester.pump();
    await tester.pump();
    await tester.pump();
    final titles = tester.widgetList<ListTile>(find.byType(ListTile))
        .map((tile) => (tile.title as Text).data)
        .toList();
    expect(titles.indexOf('Alpha session'), lessThan(titles.indexOf('Gamma session')));
    expect(client.listCalls, 2);
  });

  testWidgets('a refresh during load-more discards the stale page', (tester) async {
    final client = await _pump(tester);
    final oldPage = Completer<RpcReply>();
    client.onCall = (action, payload) {
      if (action == 'sessions.list' && payload?['cursor'] != null) {
        throw _DeferredReply(oldPage.future);
      }
      client.actions.add(action);
      client.listPayloads.add(payload);
      client.listCalls++;
      if (action == 'core.status' || action == 'vault.status') {
        return RpcReply(action: action, ok: true, data: <String, dynamic>{});
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 'alpha', 'title': 'Alpha session'},
          ],
          'truncated': true,
        },
      );
    };
    addTearDown(() {
      if (!oldPage.isCompleted) {
        oldPage.complete(const RpcReply(action: 'sessions.list', ok: true, data: <String, dynamic>{}));
      }
    });
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    tester.widget<TextButton>(find.byKey(const Key('sessions-load-more'))).onPressed!();
    await tester.pump();
    unawaited(
      tester.widget<RefreshIndicator>(find.byType(RefreshIndicator)).onRefresh!(),
    );
    await tester.pump();
    oldPage.complete(RpcReply(
      action: 'sessions.list',
      ok: true,
      data: <String, dynamic>{
        'sessions': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'gamma', 'title': 'Gamma session'},
        ],
        'truncated': false,
      },
    ));
    await tester.pump();
    await tester.pump();

    expect(find.widgetWithText(ListTile, 'Gamma session'), findsNothing);
  });
}
