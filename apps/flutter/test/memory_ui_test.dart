// SPDX-License-Identifier: GPL-3.0-or-later

// Memory UI breadth: journal search must call the real daemon verb, kind
// filtering is presentation-only over the returned entries, and the
// default-off account/manifest surfaces must never fabricate data from a
// daemon that has no auth or manifest RPC.

import 'dart:async';

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
  bool echoSearchQuery = false;
  Duration? searchDelay;

  /// Query-keyed held replies. A `journal.search` for a keyed query returns
  /// that future, letting a test complete stale/fresh replies in any order.
  /// The empty-query load passes through the normal fake path unchanged.
  final Map<String, Completer<RpcReply>> heldSearches =
      <String, Completer<RpcReply>>{};
  final List<({String action, Map<String, dynamic>? payload})> deletes =
      <({String action, Map<String, dynamic>? payload})>[];

  // settingsGet is overridden by FakeChatClient, so record the verb here too;
  // the super call still honors deferredSettings for held-reply tests.
  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    calls.add((
      action: 'settings.get',
      payload: <String, dynamic>{'section': section},
    ));
    return super.settingsGet(section);
  }

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
            'memory': <String, dynamic>{'summaries': 1, 'journalEntries': 2},
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
      final held = heldSearches[payload?['query'] as String? ?? ''];
      if (held != null) return held.future;
      // Hold the call open so tests can observe the in-flight `_busy` UI.
      if (searchDelay != null) await Future<void>.delayed(searchDelay!);
      if (echoSearchQuery) {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'entries': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'echo',
                'kind': 'note',
                'content': 'echo-${payload?['query'] ?? ''}',
              },
            ],
          },
        );
      }
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
    MaterialApp(
      home: Scaffold(body: MemoryScreen(client: client)),
    ),
  );
  await tester.pump();
  await tester.pump();
  return client;
}

Future<void> _scrollTo(tester, Key key) async {
  await tester.scrollUntilVisible(
    find.byKey(key),
    500.0,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('search calls journal.search with the entered query', (
    tester,
  ) async {
    final client = await _pump(tester);
    await _scrollTo(tester, const Key('memory-search'));
    await tester.enterText(find.byKey(const Key('memory-search')), 'milestone');
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    final search = client.calls.where((c) => c.action == 'journal.search').last;
    expect(search.payload, <String, dynamic>{
      'query': 'milestone',
      'limit': 50,
    });
  });

  testWidgets('kind filter hides entries without changing daemon results', (
    tester,
  ) async {
    await _pump(tester);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -600));
    await tester.pumpAndSettle();
    final dropdown = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
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
    tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!
        .jumpTo(0);
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
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
        .onPressed!();
    await tester.pump();
    await tester.pump();

    final entryDelete = find.byKey(const Key('memory-entry-delete'));
    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();
    await tester.pumpAndSettle();
    tester.widget<IconButton>(entryDelete.first).onPressed!();
    await tester.pump();
    await tester.pump();
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
        .onPressed!();
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

  testWidgets(
    'debounces typing: journal.search fires after the delay without pressing Search',
    (tester) async {
      final client = await _pump(tester);
      await _scrollTo(tester, const Key('memory-search'));
      await tester.enterText(
        find.byKey(const Key('memory-search')),
        'milestone',
      );
      // No Search button press: only the trailing debounce can issue this verb.
      await tester.pump(const Duration(milliseconds: 350));

      final searches = client.calls
          .where((c) => c.action == 'journal.search')
          .toList();
      expect(searches.last.payload, <String, dynamic>{
        'query': 'milestone',
        'limit': 50,
      });
    },
  );

  testWidgets(
    'debounces rapid edits: one journal.search carrying the final query',
    (tester) async {
      final client = await _pump(tester);
      await _scrollTo(tester, const Key('memory-search'));
      final field = find.byKey(const Key('memory-search'));
      // Three edits inside the debounce window: each must cancel the pending
      // timer so only the final query is ever sent to the daemon.
      await tester.enterText(field, 'mil');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'mile');
      await tester.pump(const Duration(milliseconds: 100));
      await tester.enterText(field, 'milestones');
      await tester.pump(const Duration(milliseconds: 400));

      final searches = client.calls
          .where(
            (c) =>
                c.action == 'journal.search' &&
                (c.payload?['query'] as String?)?.isNotEmpty == true,
          )
          .toList();
      expect(searches, hasLength(1));
      expect(searches.single.payload, <String, dynamic>{
        'query': 'milestones',
        'limit': 50,
      });
    },
  );

  testWidgets(
    'dispose before the debounce fires issues no new journal.search',
    (tester) async {
      final client = await _pump(tester);
      await _scrollTo(tester, const Key('memory-search'));
      await tester.enterText(
        find.byKey(const Key('memory-search')),
        'milestone',
      );
      final before = client.calls
          .where((c) => c.action == 'journal.search')
          .length;

      // Replace the tree before 300ms elapses; dispose() must cancel the timer.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 350));

      final after = client.calls
          .where((c) => c.action == 'journal.search')
          .length;
      expect(after, before);
      expect(find.byKey(const Key('memory-search')), findsNothing);
    },
  );

  testWidgets(
    'explicit Search mid-debounce issues exactly one journal.search',
    (tester) async {
      final client = await _pump(tester);
      await _scrollTo(tester, const Key('memory-search'));
      await tester.enterText(
        find.byKey(const Key('memory-search')),
        'milestone',
      );
      // The button supersedes the pending timer instead of duplicating it.
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
          .onPressed!();
      await tester.pump(const Duration(milliseconds: 400));

      final searches = client.calls
          .where(
            (c) =>
                c.action == 'journal.search' &&
                (c.payload?['query'] as String?)?.isNotEmpty == true,
          )
          .toList();
      expect(searches, hasLength(1));
      expect(searches.single.payload, <String, dynamic>{
        'query': 'milestone',
        'limit': 50,
      });
    },
  );

  testWidgets('debounced search keeps the search field mounted while busy', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.searchDelay = const Duration(seconds: 2);
    await _scrollTo(tester, const Key('memory-search'));
    final field = find.byKey(const Key('memory-search'));
    await tester.enterText(field, 'mil');
    await tester.pump(const Duration(milliseconds: 350));

    // The debounced call is in flight (_busy == true). The field must stay
    // mounted and keep its typed text instead of being replaced by a spinner.
    expect(field, findsOneWidget);
    expect(tester.widget<TextField>(field).controller!.text, 'mil');
    // The button is disabled while the debounced call is in flight; the
    // spinner itself lives at the top of a lazily built ListView, so check
    // busy via a control next to the field instead.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
          .onPressed,
      isNull,
    );

    // Drain the in-flight response so no async work leaks into other tests.
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
  });

  testWidgets('failed debounced search clears busy and re-enables Search', (
    tester,
  ) async {
    final client = await _pump(tester);
    client.searchFails = true;
    await _scrollTo(tester, const Key('memory-search'));
    await tester.enterText(find.byKey(const Key('memory-search')), 'x');
    await tester.pump(const Duration(milliseconds: 350));
    // Let the failed reply's setState flush into a frame.
    await tester.pump();

    // Busy cleared: the control next to the field is enabled again.
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
          .onPressed,
      isNotNull,
    );

    // Bring the error row and inline spinner slot (top of the lazily built
    // ListView) back into the viewport before asserting on them.
    tester
        .widget<Scrollable>(find.byType(Scrollable).first)
        .controller!
        .jumpTo(0);
    await tester.pump();
    expect(find.textContaining('search failed'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets(
    'a debounce during an in-flight search replays the latest query',
    (tester) async {
      final client = await _pump(tester);
      client.searchDelay = const Duration(seconds: 2);
      client.echoSearchQuery = true;
      await _scrollTo(tester, const Key('memory-search'));
      final field = find.byKey(const Key('memory-search'));
      int searches() =>
          client.calls.where((c) => c.action == 'journal.search').length;

      await tester.enterText(field, 'mil');
      await tester.pump(const Duration(milliseconds: 350));
      expect(searches(), 2); // initial load + first debounced search

      // A second edit lands while the first search is still in flight.
      await tester.enterText(field, 'milestones');
      await tester.pump(const Duration(milliseconds: 350));
      expect(searches(), 2); // not dropped, but not duplicated either

      // First call completes; the pending replay must start a second search.
      await tester.pump(const Duration(seconds: 2));
      final allSearches = client.calls
          .where((c) => c.action == 'journal.search')
          .toList();
      expect(allSearches, hasLength(3));
      expect(allSearches.last.payload, <String, dynamic>{
        'query': 'milestones',
        'limit': 50,
      });

      // Let the replayed call finish and prove the UI shows its result.
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('echo-milestones'),
        500.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(find.text('echo-milestones'), findsOneWidget);
    },
  );

  testWidgets(
    'stale search replies and a reply after dispose cannot overwrite the view',
    (tester) async {
      // A tall surface keeps the whole ListView built, so entry assertions
      // never depend on lazy-build viewport position.
      tester.view.physicalSize = const Size(1000, 3000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final client = _RecordingMemoryClient();
      addTearDown(client.dispose);
      final alpha = Completer<RpcReply>();
      final beta = Completer<RpcReply>();
      final gamma = Completer<RpcReply>();
      client.heldSearches
        ..['alpha'] = alpha
        ..['beta'] = beta
        ..['gamma'] = gamma;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MemoryScreen(client: client)),
        ),
      );
      await tester.pump();
      await tester.pump();
      await _scrollTo(tester, const Key('memory-search'));
      final field = find.byKey(const Key('memory-search'));
      int searchesFor(String query) => client.calls
          .where(
            (c) => c.action == 'journal.search' && c.payload?['query'] == query,
          )
          .length;

      // (1) alpha is dispatched and held in flight.
      await tester.enterText(field, 'alpha');
      await tester.pump(const Duration(milliseconds: 350));
      expect(searchesFor('alpha'), 1);
      expect(alpha.isCompleted, isFalse);

      // (2) beta is typed while alpha is still in flight: it is queued as a
      // pending replay, with no second `journal.search` issued yet.
      await tester.enterText(field, 'beta');
      await tester.pump(const Duration(milliseconds: 350));
      expect(searchesFor('beta'), isZero);

      // (3) alpha's late reply must be dropped. Its content contains 'beta'
      // so the `_visibleEntries` filter cannot hide it — this assertion is
      // only green if the reply is genuinely discarded.
      alpha.complete(
        RpcReply(
          action: 'journal.search',
          ok: true,
          data: <String, dynamic>{
            'entries': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'stale',
                'kind': 'note',
                'content': 'STALE_ALPHA beta',
              },
            ],
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('STALE_ALPHA'), findsNothing);

      // (4) the replayed beta reply is fresh and is shown.
      expect(searchesFor('beta'), 1);
      beta.complete(
        RpcReply(
          action: 'journal.search',
          ok: true,
          data: <String, dynamic>{
            'entries': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'fresh',
                'kind': 'note',
                'content': 'FRESH_BETA beta',
              },
            ],
          },
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('FRESH_BETA beta'), findsOneWidget);

      // (5) a reply completing after dispose must not setState.
      await tester.enterText(field, 'gamma');
      await tester.pump(const Duration(milliseconds: 350));
      expect(searchesFor('gamma'), 1);

      await tester.pumpWidget(const SizedBox.shrink());
      gamma.complete(
        RpcReply(
          action: 'journal.search',
          ok: true,
          data: <String, dynamic>{
            'entries': <Map<String, dynamic>>[
              <String, dynamic>{
                'id': 'gamma',
                'kind': 'note',
                'content': 'GAMMA_AFTER_DISPOSE',
              },
            ],
          },
        ),
      );
      await tester.pump();
      await tester.pump();
    },
  );

  testWidgets('stale search errors are dropped for a newer query', (
    tester,
  ) async {
    // Tall surface keeps the (top-of-list) error row built, so the stale
    // error assertion cannot pass just because the row was never laid out.
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final client = _RecordingMemoryClient();
    addTearDown(client.dispose);
    final alpha = Completer<RpcReply>();
    final beta = Completer<RpcReply>();
    client.heldSearches
      ..['alpha'] = alpha
      ..['beta'] = beta;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MemoryScreen(client: client)),
      ),
    );
    await tester.pump();
    await tester.pump();
    await _scrollTo(tester, const Key('memory-search'));
    final field = find.byKey(const Key('memory-search'));

    // alpha is in flight and held.
    await tester.enterText(field, 'alpha');
    await tester.pump(const Duration(milliseconds: 350));

    // beta is typed (pre-debounce): `_onSearchChanged` already bumped the
    // generation, but no queued replay exists yet to clear the error row.
    await tester.enterText(field, 'beta');
    await tester.pump();

    // alpha fails after beta made it stale. The error must not reach the view.
    alpha.completeError(
      const DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: 'STALE_ALPHA_ERROR',
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('STALE_ALPHA_ERROR'), findsNothing);

    // The still-pending beta debounce issues a fresh, successful search.
    await tester.pump(const Duration(milliseconds: 350));
    expect(
      client.calls.where(
        (c) => c.action == 'journal.search' && c.payload?['query'] == 'beta',
      ),
      hasLength(1),
    );
    beta.complete(
      RpcReply(
        action: 'journal.search',
        ok: true,
        data: <String, dynamic>{
          'entries': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'fresh',
              'kind': 'note',
              'content': 'FRESH_BETA beta',
            },
          ],
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('FRESH_BETA beta'), findsOneWidget);
  });

  testWidgets('dispose during initial load does not setState after dispose', (
    tester,
  ) async {
    final client = _RecordingMemoryClient();
    addTearDown(client.dispose);

    // Hold settings.get open so _load() parks on its last read. Releasing it
    // after dispose forces every post-await setState onto a dead State.
    final held = Completer<Map<String, dynamic>>();
    client.deferredSettings = held;
    addTearDown(() {
      if (!held.isCompleted) {
        held.complete(<String, dynamic>{'remoteSyncEnabled': false});
      }
    });

    final previousOnError = FlutterError.onError;
    final errors = <FlutterErrorDetails>[];
    FlutterError.onError = (details) {
      errors.add(details);
      // Keep the binding's own handler in the chain: it tracks pending
      // exceptions, and dropping it trips an unrelated framework assertion.
      previousOnError?.call(details);
    };
    addTearDown(() => FlutterError.onError = previousOnError);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: MemoryScreen(client: client)),
      ),
    );
    await tester.pump();

    // All five thin-client reads were issued, and the held reply proves
    // _load() is suspended at settings.get rather than skipping a read.
    expect(
      client.calls.map((c) => c.action).toList(),
      containsAllInOrder(<String>[
        'vault.status',
        'stmm.list',
        'journal.search',
        'retrieval.status',
        'settings.get',
      ]),
    );
    expect(held.isCompleted, isFalse);

    await tester.pumpWidget(const SizedBox.shrink());
    held.complete(<String, dynamic>{'remoteSyncEnabled': false});
    await tester.pump();
    await tester.pump();

    // Restore before asserting: flutter_test routes a failed expect() through
    // the binding's own onError handler, which must be active at that point.
    FlutterError.onError = previousOnError;

    expect(
      errors.where(
        (details) => details.exception.toString().contains(
          'setState() called after dispose',
        ),
      ),
      isEmpty,
    );
  });
}
