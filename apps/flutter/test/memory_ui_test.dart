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
  final List<({String action, Map<String, dynamic>? payload})> deletes =
      <({String action, Map<String, dynamic>? payload})>[];

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    calls.add((action: action, payload: payload));
    if (action == 'stmm.delete' || action == 'journal.delete') {
      deletes.add((action: action, payload: payload));
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'deleted': true},
      );
    }
    if (action == 'stmm.upsert') {
      final sentBlocks = (payload?['blocks'] as List?)?.length ?? 0;
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'upserted': sentBlocks},
      );
    }
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
            <String, dynamic>{
              'id': 'summary-1',
              'day': '2026-11-25',
              'content': 'A summary',
            },
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
  testWidgets('memory rows offer delete actions that call the daemon', (
    tester,
  ) async {
    final client = await _pump(tester);

    final summaryDelete = find.byKey(const Key('memory-summary-delete'));
    expect(summaryDelete, findsOneWidget);
    tester.widget<IconButton>(summaryDelete).onPressed!();
    await tester.pump();
    await tester.pump();
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed!();
    await tester.pump();
    await tester.pump();

    final entryDelete = find.byKey(const Key('memory-entry-delete'));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    tester.widget<IconButton>(entryDelete.first).onPressed!();
    await tester.pump();
    await tester.pump();
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete')).onPressed!();
    await tester.pump();
    await tester.pump();

    expect(client.deletes.map((d) => d.action), <String>[
      'stmm.delete',
      'journal.delete',
    ]);
    expect(client.deletes.first.payload, <String, dynamic>{'id': 'summary-1'});
    expect(client.deletes.last.payload, <String, dynamic>{'id': 'e1'});
  });

  testWidgets('summary form saves a real block through stmm.upsert', (
    tester,
  ) async {
    final client = await _pump(tester);
    await _scrollTo(tester, const Key('memory-summary-content'));
    await tester.enterText(
      find.byKey(const Key('memory-summary-content')),
      '  Reviewed session notes  ',
    );
    await tester.enterText(
      find.byKey(const Key('memory-summary-day')),
      '2026-11-26',
    );
    tester
        .widget<FilledButton>(find.byKey(const Key('memory-summary-save')))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    final upserts = client.calls
        .where((c) => c.action == 'stmm.upsert')
        .toList();
    expect(upserts, hasLength(1));
    final blocks = upserts.single.payload!['blocks'] as List<dynamic>;
    expect(blocks, hasLength(1));
    final block = blocks.single as Map<String, dynamic>;
    expect(block['day'], '2026-11-26');
    expect(block['content'], 'Reviewed session notes');
    expect(block['id'], startsWith('flutter-summary-2026-11-26-'));
    expect(block['sourceSessionIds'], isEmpty);
    expect(block['tokenEstimate'], isA<int>());
    expect(block['createdAt'], isA<int>());
  });

  testWidgets('summary form rejects an invalid day before any RPC', (
    tester,
  ) async {
    final client = await _pump(tester);
    await _scrollTo(tester, const Key('memory-summary-content'));
    await tester.enterText(
      find.byKey(const Key('memory-summary-content')),
      'A summary',
    );
    await tester.enterText(
      find.byKey(const Key('memory-summary-day')),
      '26-11-2026',
    );
    tester
        .widget<FilledButton>(find.byKey(const Key('memory-summary-save')))
        .onPressed!();
    await tester.pump();

    expect(client.calls.where((c) => c.action == 'stmm.upsert'), isEmpty);
    expect(find.textContaining('YYYY-MM-DD'), findsWidgets);
  });
}
