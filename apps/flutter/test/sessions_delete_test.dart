// SPDX-License-Identifier: GPL-3.0-or-later

// Sessions delete: the screen confirms before deleting, reports both the
// "deleted" and the idempotent "already gone" outcomes, and refreshes the list
// from sessions.list afterwards.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/sessions/sessions_screen.dart';

import 'support/fakes.dart';

class _RecordingDeleteClient extends FakeChatClient {
  final List<String> actions = <String>[];
  final List<String> deleted = <String>[];
  bool alreadyGone = false;
  bool deleteFails = false;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    actions.add(action);
    if (action == 'sessions.delete') {
      deleted.add((payload?['sessionId'] as String?) ?? '');
      if (deleteFails) {
        return const RpcReply(
          action: 'sessions.delete',
          ok: false,
          error: RpcError(code: 'actions_disabled', message: 'actions off'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'deleted': !alreadyGone},
      );
    }
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 's1', 'title': 'first'},
          ],
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_RecordingDeleteClient> _pump(tester) async {
  final client = _RecordingDeleteClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: SessionsScreen(client: client)),
    ),
  );
  await tester.pump();
  return client;
}

void main() {
  testWidgets('cancel leaves the session alone', (tester) async {
    final client = await _pump(tester);

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();

    expect(client.deleted, isEmpty);
    expect(find.textContaining('Deleted session'), findsNothing);
  });

  testWidgets('confirm deletes and refreshes sessions.list', (tester) async {
    final client = await _pump(tester);
    final listCallsBefore = client.actions
        .where((a) => a == 'sessions.list')
        .length;

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump();

    expect(client.deleted, <String>['s1']);
    expect(find.text('Deleted session s1'), findsOneWidget);
    expect(
      client.actions.where((a) => a == 'sessions.list').length,
      greaterThan(listCallsBefore),
    );
  });

  testWidgets('a missing session is reported without claiming a delete', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.alreadyGone = true;

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump();

    expect(client.deleted, <String>['s1']);
    expect(find.text('Session s1 was already gone'), findsOneWidget);
    expect(find.textContaining('Deleted session'), findsNothing);
  });

  testWidgets('a failed delete surfaces the daemon error', (tester) async {
    final client = await _pump(tester);
    client.deleteFails = true;

    await tester.tap(find.byTooltip('Delete session'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pump();
    await tester.pump();

    expect(find.text('actions off'), findsOneWidget);
    expect(find.textContaining('Deleted session'), findsNothing);
  });
}
