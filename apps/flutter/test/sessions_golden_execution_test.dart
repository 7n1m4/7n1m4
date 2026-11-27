// SPDX-License-Identifier: GPL-3.0-or-later

// Round v29 real-execution leg of the sessions golden fixtures. The Rust leg
// (crates/anima-daemon/src/session_execution_tests.rs) drives the REAL daemon
// sessions handlers against a real store; this leg boots a REAL DaemonClient
// over a ScriptedTransport, replays the UNCHANGED golden replies through the
// production ServerFrame codec, and pumps the REAL SessionsScreen through
// list -> import -> delete -> repeat delete. No screen or client production
// code is edited, and no reply is hand-built as a ServerFrame.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/sessions/sessions_screen.dart';

import 'support/fakes.dart';

/// Same fixture resolution as the other golden replay tests.
final String _fixturesDir = () {
  final fromRepoRoot = Directory('crates/anima-channel/fixtures/golden');
  if (fromRepoRoot.existsSync()) return fromRepoRoot.path;
  final fromApp = Directory('../../crates/anima-channel/fixtures/golden');
  if (fromApp.existsSync()) return fromApp.path;
  final fromScript = Directory('../crates/anima-channel/fixtures/golden');
  if (fromScript.existsSync()) return fromScript.path;
  fail('golden fixtures directory not found');
}();

Map<String, dynamic> _read(String name) {
  final file = File('$_fixturesDir/$name');
  if (!file.existsSync()) fail('fixture not found: ${file.path}');
  return jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
}

String _replyFrame(String action, Object id, Object? data) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': true,
      'id': id,
      'data': data,
    });

/// Valid snapshot body for `parse_snapshot` (crates/anima-core/src/sessions.rs).
/// Its revision is the golden import sentinel, so the production codec's reply
/// and the text typed into the screen agree on one number.
const String _snapshot =
    '{"type":"session","session":{"id":"sess-v29-imported","title":"Round v29 imported","created_at":1700000000000,"updated_at":1700000000123,"metadata":{}}}\n'
    '{"type":"message","message":{"id":"m-v29-1","session_id":"sess-v29-imported","role":"user","content":"real execution","created_at":1,"metadata":{}}}\n';

const String _seedId = 'sess-v29-seed';
const String _importedId = 'sess-v29-imported';

Map<String, dynamic> _row(String id, String title) => <String, dynamic>{
  'id': id,
  'title': title,
  'created_at': 1700000000000,
  'updated_at': 1700000000123,
};

/// Answers every RPC the boot probe and SessionsScreen put on the wire. Golden
/// reply payloads are fed through ServerFrame.parse before reaching the
/// transport, so the production codec is on the path for each replayed reply.
class _SessionsGoldenPeer {
  _SessionsGoldenPeer(
    this.transport, {
    required this.coreGolden,
    required this.vaultGolden,
    required this.subscribeGolden,
    required this.importGolden,
    required this.deleteGolden,
    required this.deleteRequestGolden,
  });

  final ScriptedTransport transport;
  final Map<String, dynamic> coreGolden;
  final Map<String, dynamic> vaultGolden;
  final Map<String, dynamic> subscribeGolden;
  final Map<String, dynamic> importGolden;
  final Map<String, dynamic> deleteGolden;
  final Map<String, dynamic> deleteRequestGolden;

  /// Every emitted rpc request frame, in wire order.
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  /// Daemon-side session table the real `sessions.list` replies are built from.
  final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
    _row(_seedId, 'Round v29 seed'),
  ];

  int _handled = 0;
  int _deletes = 0;

  List<String> get actions => requests
      .where((frame) => frame['type'] == 'rpc')
      .map((frame) => frame['action'] as String)
      .toList(growable: false);

  int get deletes => _deletes;

  /// Put a stale client-side row back after a successful delete: the screen
  /// must treat the daemon's idempotent `deleted:false` as success too. The
  /// Rust leg proves that second delete really returns `false` from the handler.
  void restoreStaleRow() => rows.add(_row(_importedId, 'Round v29 imported'));

  Future<void> drain(Future<void> Function() flush) async {
    for (var pass = 0; pass < 16; pass++) {
      while (_handled < transport.sent.length) {
        final decoded =
            jsonDecode(transport.sent[_handled++]) as Map<String, dynamic>;
        if (decoded['type'] != 'rpc') continue;
        final action = decoded['action'] as String?;
        final id = decoded['id'];
        if (action == null || id == null) continue;
        requests.add(decoded);
        final data = _dataFor(action, decoded['payload']);
        // Production codec, not a test-side ServerFrame assignment.
        final parsed = ServerFrame.parse(_replyFrame(action, id, data));
        expect(parsed.parseError, isNull, reason: '$action reply must parse');
        expect(parsed.kind, ServerFrameKind.rpc, reason: '$action kind');
        expect(parsed.reply!.action, action, reason: '$action echo');
        expect(parsed.reply!.ok, isTrue, reason: '$action ok');
        transport.receive(jsonEncode(parsed.raw));
      }
      await flush();
      if (_handled >= transport.sent.length) {
        await flush();
        if (_handled >= transport.sent.length) return;
      }
    }
    fail('sessions golden replay did not quiesce after 16 waves');
  }

  Object? _dataFor(String action, Object? payload) {
    switch (action) {
      case 'core.status':
        return coreGolden;
      case 'vault.status':
        return vaultGolden;
      case 'event.subscribe':
        return subscribeGolden;
      case 'sessions.list':
        return <String, dynamic>{
          'sessions': List<Map<String, dynamic>>.from(rows),
          'truncated': false,
        };
      case 'sessions.import':
        rows.add(_row(_importedId, 'Round v29 imported'));
        return importGolden;
      case 'sessions.delete':
        _deletes++;
        final id =
            (payload as Map<String, dynamic>?)?['sessionId'] as String? ?? '';
        rows.removeWhere((row) => row['id'] == id);
        // First delete is the golden `deleted:true`; the repeat delete reports
        // the real handler's idempotent `deleted:false` (proved in Rust).
        return _deletes == 1
            ? deleteGolden
            : <String, dynamic>{'deleted': false};
      default:
        return <String, dynamic>{};
    }
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _scrollToTop(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, 4000));
  await tester.pumpAndSettle();
}

/// ListView builds only visible children: bring the session rows back into the
/// tree before asserting on a row (status text lives at the top of the list).
Future<void> _scrollToList(WidgetTester tester) async {
  await tester.drag(find.byType(ListView), const Offset(0, -900));
  await tester.pumpAndSettle();
}

Finder _deleteButton(String title) => find.descendant(
  of: find.widgetWithText(ListTile, title),
  matching: find.byTooltip('Delete session'),
);

void main() {
  testWidgets(
    'Rust golden sessions execution drives a real DaemonClient and SessionsScreen',
    (tester) async {
      final coreGolden = _read('core_status.reply.json');
      final vaultGolden = _read('vault_status.reply.json');
      final subscribeGolden = _read('event_subscribe.reply.json');
      final importGolden = _read('sessions.import.reply.json');
      final deleteGolden = _read('sessions.delete.reply.json');
      final deleteRequestGolden = _read('sessions.delete.request.json');

      // Every golden reply parses through the production codec unchanged.
      for (final entry in <MapEntry<String, Map<String, dynamic>>>[
        MapEntry<String, Map<String, dynamic>>('core.status', coreGolden),
        MapEntry<String, Map<String, dynamic>>('vault.status', vaultGolden),
        MapEntry<String, Map<String, dynamic>>(
          'event.subscribe',
          subscribeGolden,
        ),
        MapEntry<String, Map<String, dynamic>>('sessions.import', importGolden),
        MapEntry<String, Map<String, dynamic>>('sessions.delete', deleteGolden),
      ]) {
        final parsed = ServerFrame.parse(
          _replyFrame(entry.key, 1, entry.value),
        );
        expect(parsed.parseError, isNull, reason: '${entry.key} golden parse');
        expect(parsed.kind, ServerFrameKind.rpc);
        expect(parsed.reply!.action, entry.key);
        expect(
          parsed.reply!.data,
          entry.value,
          reason: '${entry.key} golden data must survive the production codec',
        );
      }
      final goldenRevision = importGolden['revision'];
      expect(goldenRevision, 1700000000123);
      expect(deleteGolden, <String, dynamic>{'deleted': true});
      // The golden request carries camelCase `sessionId`; the real client must
      // emit that same key, with the live row id bound into it.
      expect(deleteRequestGolden.keys, <String>{'sessionId'});

      final transport = ScriptedTransport();
      final peer = _SessionsGoldenPeer(
        transport,
        coreGolden: coreGolden,
        vaultGolden: vaultGolden,
        subscribeGolden: subscribeGolden,
        importGolden: importGolden,
        deleteGolden: deleteGolden,
        deleteRequestGolden: deleteRequestGolden,
      );
      final client = DaemonClient(
        transportFactory: () => transport,
        authTimeout: const Duration(seconds: 5),
        rpcTimeout: const Duration(seconds: 5),
        heartbeatInterval: const Duration(hours: 1),
      );
      addTearDown(client.dispose);

      // Production handshake: auth -> core.status -> 4x event.subscribe.
      final connecting = client.connect(
        const ConnectionSettings(authToken: 'tok'),
      );
      await tester.pump();
      expect(jsonDecode(transport.sent.single)['type'], 'auth');
      transport.receive('{"type":"auth","ok":true}');
      await tester.pump();
      await peer.drain(() => tester.pump());
      await connecting;
      await peer.drain(() => tester.pump());
      expect(client.snapshot.state, DaemonConnectionState.connected);
      expect(peer.actions.where((a) => a == 'event.subscribe').length, 4);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: SessionsScreen(client: client)),
        ),
      );
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();

      // A real sessions.list reply renders a real row, plus the golden
      // core/vault counts from the handshake replay.
      expect(find.widgetWithText(ListTile, 'Round v29 seed'), findsOneWidget);
      final listCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'sessions.list',
        orElse: () => fail('sessions.list was never emitted'),
      );
      expect(listCall['payload'], <String, dynamic>{'limit': 50});
      expect(find.text('3'), findsWidgets); // core sessionCount / vault chats
      await _scrollToTop(tester);
      expect(find.text('42'), findsOneWidget); // core messageCount

      // Import: the real client emits the typed JSONL snapshot and the screen
      // reports the UNCHANGED golden reply status/revision.
      await tester.enterText(
        find.widgetWithText(TextField, 'JSONL snapshot'),
        _snapshot,
      );
      await _tap(tester, find.widgetWithText(FilledButton, 'Import'));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      final importCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'sessions.import',
        orElse: () => fail('sessions.import was never emitted'),
      );
      expect(importCall['payload'], <String, dynamic>{'jsonl': _snapshot});
      await _scrollToTop(tester);
      expect(
        find.text('Imported snapshot (revision $goldenRevision)'),
        findsOneWidget,
      );
      await _scrollToList(tester);
      expect(
        find.widgetWithText(ListTile, 'Round v29 imported'),
        findsOneWidget,
        reason: 'the applied import must appear after the screens list refresh',
      );

      // Delete: golden `deleted:true`; row disappears after the refresh the
      // screen itself issues, and the real client emits the golden key shape.
      await _tap(tester, _deleteButton('Round v29 imported'));
      expect(find.text('Delete session?'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      expect(find.text('Deleted session $_importedId'), findsOneWidget);
      await _scrollToList(tester);
      expect(find.widgetWithText(ListTile, 'Round v29 imported'), findsNothing);
      final deleteCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'sessions.delete',
        orElse: () => fail('sessions.delete was never emitted'),
      );
      expect(
        (deleteCall['payload'] as Map<String, dynamic>).keys,
        deleteRequestGolden.keys,
        reason: 'the real client must emit the golden delete request shape',
      );
      expect(deleteCall['payload'], <String, dynamic>{
        'sessionId': _importedId,
      });
      expect(
        peer.actions.where((a) => a == 'sessions.list').length,
        greaterThanOrEqualTo(3),
        reason: 'initial load + import refresh + delete refresh',
      );

      // Repeat delete on a stale row: the daemon's idempotent `deleted:false`
      // is reported honestly, never as a fresh deletion.
      peer.restoreStaleRow();
      unawaited(
        tester
            .widget<RefreshIndicator>(find.byType(RefreshIndicator))
            .onRefresh!(),
      );
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      await _scrollToList(tester);
      await _tap(tester, _deleteButton('Round v29 imported'));
      expect(find.text('Delete session?'), findsOneWidget);
      await _tap(tester, find.widgetWithText(FilledButton, 'Delete'));
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();
      await _scrollToTop(tester);
      expect(
        find.text('Session $_importedId was already gone'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Deleted session'),
        findsNothing,
        reason: 'a repeat delete must not claim a fresh deletion',
      );
      await _scrollToList(tester);
      expect(find.widgetWithText(ListTile, 'Round v29 imported'), findsNothing);
      expect(peer.deletes, 2);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
