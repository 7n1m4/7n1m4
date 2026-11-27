// SPDX-License-Identifier: GPL-3.0-or-later

// Flutter leg of the STMM authority execution round (v27). Pumps the REAL
// MemoryScreen and drives stmm replies from the eight-frame golden trace via
// FakeChatClient.onCall. The strongest assertion is anti-vacuous: a stale local
// draft is pre-seeded, then the daemon's m1 row must overwrite it.

import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/memory/memory_screen.dart';

import 'support/fakes.dart';

/// Path to the shared Rust golden fixtures directory (same resolution as the
/// codec leg in stmm_golden_trace_test.dart).
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

Map<String, dynamic> _loadFixture() {
  final file = File('$_fixturesDir/trace.stmm.authority.json');
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

/// The reply body (`data`) of golden frame [frame].
Map<String, dynamic> _replyData(Map<String, dynamic> fixture, int frame) {
  final frames = fixture['frames'] as List;
  return (frames[frame] as Map<String, dynamic>)['data']
      as Map<String, dynamic>;
}

Future<(DaemonClient, ScriptedTransport)> _connectedClient() async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 2),
    rpcTimeout: const Duration(seconds: 2),
  );
  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await Future<void>.delayed(Duration.zero);
  transport.receive('{"type":"auth","ok":true}');
  await Future<void>.delayed(Duration.zero);
  final probe = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  transport.receive(
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': 'core.status',
      'ok': true,
      'data': <String, dynamic>{
        'app': 'anima-daemon',
        'version': '0.1.0',
        'coreAvailable': true,
        'storeAvailable': true,
        'storeHealth': 'ok',
        'protocol': 'airi-channel/1',
        'sessionCount': 3,
        'messageCount': 12,
      },
      'id': probe['id'],
    }),
  );
  await connecting;
  return (client, transport);
}

Map<String, dynamic> _lastRequest(ScriptedTransport transport) =>
    jsonDecode(transport.sent.last) as Map<String, dynamic>;

void main() {
  testWidgets(
    'daemon m1 row overwrites a stale local draft and delete cannot resurrect',
    (tester) async {
      final fixture = _loadFixture();
      final m1 = _replyData(fixture, 1);
      final m2 = _replyData(fixture, 3);
      final m3 = _replyData(fixture, 5);
      final m4 = _replyData(fixture, 7);

      // Fixture-derived authority: the daemon row carries token_estimate 3.
      expect(
        (m1['summaries'] as List).single,
        containsPair('token_estimate', 3),
      );

      // Pre-seed a STALE local draft as the widget's first stmm.list view.
      Map<String, dynamic> listReply = <String, dynamic>{
        'summaries': <Map<String, dynamic>>[
          <String, dynamic>{
            'id': 'summary-1',
            'day': '2026-11-25',
            'content': 'Stale client draft',
            'token_estimate': 99,
          },
        ],
      };

      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) {
        switch (action) {
          case 'stmm.list':
            return RpcReply(action: action, ok: true, data: listReply);
          case 'stmm.upsert':
            return RpcReply(action: action, ok: true, data: m2);
          case 'stmm.delete':
            return RpcReply(action: action, ok: true, data: m3);
          case 'stmm.rebuild':
            return RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{},
            );
          case 'vault.status':
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
          case 'journal.search':
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
                ],
              },
            );
          case 'retrieval.status':
            return RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{'available': true},
            );
          case 'settings.get':
            return RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{
                'settings': <String, dynamic>{'remoteSyncEnabled': false},
              },
            );
          default:
            return RpcReply(
              action: action,
              ok: true,
              data: <String, dynamic>{},
            );
        }
      };

      // _pump pattern from memory_ui_test.dart: real MemoryScreen, no edits.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MemoryScreen(client: client)),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(find.text('Stale client draft'), findsOneWidget);

      Future<void> reload() async {
        tester
            .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.build))
            .onPressed!();
        await tester.pumpAndSettle();
      }

      // ListView builds only visible rows; scroll back to the top before
      // asserting the status line and summary header.
      Future<void> scrollToTop() async {
        tester
            .widget<Scrollable>(find.byType(Scrollable).first)
            .controller!
            .jumpTo(0);
        await tester.pumpAndSettle();
      }

      // Replay the daemon m1 row: the authoritative list reply must replace
      // the stale client-side draft on reload.
      listReply = m1;
      await reload();
      expect(
        find.text('A summary'),
        findsOneWidget,
        reason: 'the daemon m1 row must overwrite the stale local draft',
      );
      expect(find.text('Stale client draft'), findsNothing);
      expect(find.text('day 2026-11-25'), findsOneWidget);

      // m2: the golden upsert reply is {'upserted': 1} -> widget status text.
      expect(m2['upserted'], 1);
      await tester.scrollUntilVisible(
        find.byKey(const Key('memory-summary-save')),
        500.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('memory-summary-content')),
        'A summary',
      );
      await tester.enterText(
        find.byKey(const Key('memory-summary-day')),
        '2026-11-25',
      );
      tester
          .widget<FilledButton>(find.byKey(const Key('memory-summary-save')))
          .onPressed!();
      await tester.pumpAndSettle();
      await scrollToTop();
      expect(find.text('Saved 1 summary block'), findsOneWidget);
      expect(
        find.text('A summary'),
        findsOneWidget,
        reason: 'no duplicate row',
      );

      // m3 + m4: delete then re-list must show no summaries, no resurrection.
      expect(m3['deleted'], isTrue);
      await tester.scrollUntilVisible(
        find.byKey(const Key('memory-summary-delete')),
        500.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      tester
          .widget<IconButton>(find.byKey(const Key('memory-summary-delete')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.text('Delete summary?'), findsOneWidget);
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Delete'))
          .onPressed!();
      // Switch to the post-delete golden list BEFORE the widget's internal
      // reload consumes it.
      listReply = m4;
      await tester.pumpAndSettle();
      await scrollToTop();
      expect(find.text('No summaries'), findsOneWidget);
      expect(find.text('A summary'), findsNothing);
      expect(find.text('Stale client draft'), findsNothing);
    },
  );

  test('fixture-derived stmmUpsert chunks 101 blocks at the daemon cap and sums replies', () async {
    final fixture = _loadFixture();
    final frames = fixture['frames'] as List;
    final blocksPayload =
        ((frames[2] as Map<String, dynamic>)['payload']
                as Map<String, dynamic>)['blocks']
            as List;
    final base = blocksPayload.single as Map<String, dynamic>;
    final blocks = List<Map<String, dynamic>>.generate(
      101,
      (i) => <String, dynamic>{...base, 'id': 'summary-$i'},
    );

    final (client, transport) = await _connectedClient();
    addTearDown(client.dispose);

    // Chunking is CLIENT-level (DaemonClient cap 100), not widget-level.
    final pending = client.stmmUpsert(blocks);
    final sizes = <int>[];
    for (var i = 0; i < 2; i++) {
      final request = _lastRequest(transport);
      expect(request['action'], 'stmm.upsert');
      final sent = request['payload']!['blocks'] as List<dynamic>;
      sizes.add(sent.length);
      transport.receive(
        jsonEncode(<String, dynamic>{
          'type': 'rpc',
          'action': 'stmm.upsert',
          'ok': true,
          'data': <String, dynamic>{'upserted': sent.length},
          'id': request['id'],
        }),
      );
      if (i < 1) await Future<void>.delayed(Duration.zero);
    }
    expect(sizes, <int>[100, 1]);
    expect(await pending, 101);
  });
}
