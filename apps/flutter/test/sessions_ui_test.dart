// SPDX-License-Identifier: GPL-3.0-or-later

// Sessions UI breadth: filtering is local presentation over the daemon's
// sessions.list result, and the new-chat action opens a fresh ChatScreen
// without writing session state from the client.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/chat/chat_screen.dart';
import 'package:anima_control/features/sessions/sessions_screen.dart';

import 'support/fakes.dart';

class _SessionsUiClient extends FakeChatClient {
  final List<String> actions = <String>[];
  final List<Map<String, dynamic>?> listPayloads = <Map<String, dynamic>?>[];
  int listCalls = 0;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    actions.add(action);
    if (action == 'sessions.list') {
      listPayloads.add(payload);
      listCalls++;
      final cursor = payload?['cursor'] as int?;
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

    expect(client.listPayloads.last?['cursor'], 2);
    await tester.drag(find.byType(ListView), const Offset(0, -1000));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Gamma session'), findsOneWidget);
    expect(more, findsNothing);
  });
}
