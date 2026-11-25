// SPDX-License-Identifier: GPL-3.0-or-later

// Sessions import must surface all four SessionImportReply statuses honestly:
// only `applied` is a success and triggers a sessions.list refresh;
// duplicate/older/conflict are reported as not-applied.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/sessions/sessions_screen.dart';

import 'support/fakes.dart';

// Contract: crates/anima-core/src/sessions.rs `parse_snapshot`.
const _validSnapshot =
    '{"type":"session","session":{"id":"s1","title":"t","created_at":1,"updated_at":1,"metadata":{}}}\n'
    '{"type":"message","message":{"id":"m1","session_id":"s1","role":"user","content":"hi","created_at":1,"metadata":{}}}\n';

class _RecordingSessionsClient extends FakeChatClient {
  final List<String> actions = <String>[];
  String importStatus = 'applied';
  bool importFails = false;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    actions.add(action);
    if (action == 'sessions.import') {
      if (importFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: RpcError(code: 'actions_disabled', message: 'actions off'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'status': importStatus, 'revision': 7},
      );
    }
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'sessions': <Map<String, dynamic>>[]},
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_RecordingSessionsClient> _pump(tester) async {
  final client = _RecordingSessionsClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: SessionsScreen(client: client))));
  await tester.pump();
  return client;
}

void main() {
  testWidgets('applied status claims success and refreshes sessions.list',
      (tester) async {
    final client = await _pump(tester);

    await tester.enterText(
        find.widgetWithText(TextField, 'JSONL snapshot'), _validSnapshot);
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Import'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    expect(find.text('Imported snapshot (revision 7)'), findsOneWidget);
    expect(
      client.actions.where((a) => a == 'sessions.list').length,
      greaterThanOrEqualTo(2),
    );
  });

  for (final status in <String>['duplicate', 'older', 'conflict']) {
    testWidgets('$status status is reported without claiming success',
        (tester) async {
      final client = await _pump(tester);
      client.importStatus = status;

      await tester.enterText(
          find.widgetWithText(TextField, 'JSONL snapshot'), _validSnapshot);
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Import'))
          .onPressed!();
      await tester.pump();

      expect(find.textContaining('Imported snapshot'), findsNothing);
      final listCalls =
          client.actions.where((a) => a == 'sessions.list').length;
      expect(listCalls, 1); // only the initial load, no refresh after reject
    });
  }

  testWidgets('import RPC failure surfaces the daemon error', (tester) async {
    final client = await _pump(tester);
    client.importFails = true;

    // malformed body rejected by daemon parser; only RPC error path exercised
    await tester.enterText(
        find.widgetWithText(TextField, 'JSONL snapshot'), '{"a":1}');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Import'))
        .onPressed!();
    await tester.pumpAndSettle();

    expect(find.text('actions off'), findsOneWidget);
    expect(find.textContaining('Imported snapshot'), findsNothing);
  });
}
