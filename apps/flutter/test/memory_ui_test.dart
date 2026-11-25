// SPDX-License-Identifier: GPL-3.0-or-later

// Memory UI breadth: journal search must call the real daemon verb, kind
// filtering is presentation-only over the returned entries, and the
// default-off account/manifest surfaces must never fabricate data from a
// daemon that has no auth or manifest RPC.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/memory/memory_screen.dart';

import 'support/fakes.dart';

class _RecordingMemoryClient extends FakeChatClient {
  final List<({String action, Map<String, dynamic>? payload})> calls =
      <({String action, Map<String, dynamic>? payload})>[];
  bool remoteSync = false;
  bool searchFails = false;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    if (action == 'vault.status') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'available': true,
          'stats': <String, dynamic>{
            'memory': <String, dynamic>{
              'summaries': 1,
              'journalEntries': 2,
            },
          },
        },
      );
    }
    if (action == 'stmm.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'summaries': <Map<String, dynamic>>[
            <String, dynamic>{'day': '2026-11-25', 'content': 'A summary'},
          ],
        },
      );
    }
    if (action == 'journal.search') {
      if (searchFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'internal', message: 'search failed'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'e1',
              'kind': 'note',
              'content': 'a quiet note',
            },
            <String, dynamic>{
              'id': 'e2',
              'kind': 'milestone',
              'content': 'a loud milestone',
            },
          ],
        },
      );
    }
    if (action == 'retrieval.status') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'available': true},
      );
    }
    if (action == 'settings.get') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'settings': <String, dynamic>{'remoteSyncEnabled': remoteSync},
        },
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<_RecordingMemoryClient> _pump(tester) async {
  final client = _RecordingMemoryClient();
  addTearDown(client.dispose);
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: MemoryScreen(client: client))),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

Future<void> _scrollTo(tester, Key key) async {
  await tester.scrollUntilVisible(find.byKey(key), 500.0, scrollable: find.byType(Scrollable).first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search calls journal.search with the entered query', (
    tester,
  ) async {
    final client = await _pump(tester);
    await _scrollTo(tester, const Key('memory-search'));
    await tester.enterText(
      find.byKey(const Key('memory-search')),
      'milestone',
    );
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    final search = client.calls
        .where((c) => c.action == 'journal.search')
        .last;
    expect(search.payload, <String, dynamic>{'query': 'milestone', 'limit': 50});
  });

  testWidgets('kind filter hides entries without changing daemon results', (
    tester,
  ) async {
    await _pump(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButton<String>>(find.byType(DropdownButton<String>));
    dropdown.onChanged!('milestone');
    await tester.pump();

    expect(find.text('a quiet note'), findsNothing);
    expect(find.text('a loud milestone'), findsOneWidget);
  });

  testWidgets('failed search surfaces the daemon error', (tester) async {
    final client = await _pump(tester);
    client.searchFails = true;
    await _scrollTo(tester, const Key('memory-search'));
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
        .onPressed!();
    await tester.pumpAndSettle();
    tester.widget<Scrollable>(find.byType(Scrollable).first).controller!.jumpTo(0);
    await tester.pumpAndSettle();
    expect(find.textContaining('search failed'), findsOneWidget);
  });

  testWidgets('auth default-off and manifest status are honest', (
    tester,
  ) async {
    await _pump(tester);
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('memory-auth-status')))
          .subtitle,
      isA<Text>().having((t) => t.data, 'data', 'Disabled (local-only)'),
    );
    expect(
      tester
          .widget<ListTile>(find.byKey(const Key('memory-manifest-status')))
          .subtitle,
      isA<Text>().having(
        (t) => t.data,
        'data',
        'Display model manifest is not available from the daemon.',
      ),
    );
  });
}
