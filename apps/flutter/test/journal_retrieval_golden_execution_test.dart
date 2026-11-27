// SPDX-License-Identifier: GPL-3.0-or-later

// Round v31 real-execution Dart leg for the journal/retrieval golden trace.
// Boots a REAL DaemonClient over a ScriptedTransport, replays the unchanged
// golden through the production ServerFrame.parse -> RpcReply codec, and feeds
// it into the FROZEN MemoryScreen. No screen or production code is edited.

import 'dart:convert';
import 'dart:io';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/memory/memory_screen.dart';

import 'support/fakes.dart';

/// Same fixture resolution as vault_status_golden_execution_test.dart.
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

/// The `payload` / `data` body of golden trace [frame].
Map<String, dynamic> _body(
  Map<String, dynamic> fixture,
  int frame,
  String key,
) =>
    ((fixture['frames'] as List)[frame] as Map<String, dynamic>)[key]
        as Map<String, dynamic>;

class _Harness {
  _Harness(this.client, this.transport);

  final DaemonClient client;
  final ScriptedTransport transport;
}

/// Connect a real client: auth + core.status probe + event.subscribe drain.
Future<_Harness> _connect(WidgetTester tester) async {
  final transport = ScriptedTransport();
  final client = DaemonClient(
    transportFactory: () => transport,
    authTimeout: const Duration(seconds: 5),
    rpcTimeout: const Duration(seconds: 5),
  );
  addTearDown(client.dispose);

  final connecting = client.connect(const ConnectionSettings(authToken: 'tok'));
  await tester.pump();
  transport.receive('{"type":"auth","ok":true}');
  await tester.pump();
  final probe = jsonDecode(transport.sent[1]) as Map<String, dynamic>;
  expect(probe['action'], 'core.status');
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
        'sessionCount': 0,
        'messageCount': 0,
      },
      'id': probe['id'],
    }),
  );
  await tester.pump();
  await connecting;

  // Drain the four event.subscribe RPCs issued by connect().
  final subscribeIds = <Object?>[];
  for (final frame in transport.sent) {
    final decoded = jsonDecode(frame) as Map<String, dynamic>;
    if (decoded['action'] == 'event.subscribe') subscribeIds.add(decoded['id']);
  }
  for (final id in subscribeIds) {
    transport.receive(
      jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'event.subscribe',
        'ok': true,
        'data': <String, dynamic>{'ok': true},
        'id': id,
      }),
    );
  }
  await tester.pump();
  return _Harness(client, transport);
}

/// Newest request frame sent for [action].
Map<String, dynamic> _request(_Harness harness, String action) {
  for (final frame in harness.transport.sent.reversed) {
    final decoded = jsonDecode(frame) as Map<String, dynamic>;
    if (decoded['action'] == action) return decoded;
  }
  fail('no $action request reached the wire');
}

/// Feed an rpc reply for the outstanding [action] through the production codec.
void _reply(_Harness harness, String action, Object? data) {
  final id = _request(harness, action)['id'];
  final frame = jsonEncode(<String, dynamic>{
    'type': 'rpc',
    'action': action,
    'ok': true,
    'data': data,
    'id': id,
  });
  final parsed = ServerFrame.parse(frame);
  expect(parsed.parseError, isNull);
  expect(parsed.kind, ServerFrameKind.rpc);
  expect(parsed.reply, isNotNull);
  expect(
    parsed.reply!.data,
    data,
    reason: 'unchanged golden survives the codec',
  );
  harness.transport.receive(frame);
}

/// Feed the five load verbs MemoryScreen._load issues, in order.
Future<void> _feedLoad(
  WidgetTester tester,
  _Harness harness, {
  required Object? retrievalData,
  required Object? vaultData,
  required Object? stmmData,
  required Object? journalData,
  required Object? settingsData,
}) async {
  await tester.pump();
  _reply(harness, 'vault.status', vaultData);
  await tester.pump();
  _reply(harness, 'stmm.list', stmmData);
  await tester.pump();
  _reply(harness, 'journal.search', journalData);
  await tester.pump();
  _reply(harness, 'retrieval.status', retrievalData);
  await tester.pump();
  _reply(harness, 'settings.get', settingsData);
  await tester.pumpAndSettle();
}

ListTile _row(WidgetTester tester, String label) => tester.widget<ListTile>(
  find.byWidgetPredicate(
    (widget) =>
        widget is ListTile &&
        widget.title is Text &&
        (widget.title as Text).data == label,
  ),
);

void main() {
  testWidgets(
    'golden journal/retrieval frames replay through the codec into the real MemoryScreen',
    (tester) async {
      final journal = _read('trace.journal.retrieval.json');
      final searchPayload = _body(journal, 4, 'payload');
      final searchData = _body(journal, 5, 'data');
      final retrievalTrue = _body(journal, 1, 'data');
      final retrievalFalse = _body(journal, 7, 'data');
      final entry =
          (searchData['entries'] as List).single as Map<String, dynamic>;

      final vaultData = _read('vault_status.reply.json');
      final stmmData = _body(_read('trace.stmm.authority.json'), 1, 'data');
      final settingsData = _read('settings_get.reply.json');

      final harness = await _connect(tester);
      // A tall surface forces the lazily-built journal tiles into the tree.
      tester.view.physicalSize = const Size(1200, 4000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: MemoryScreen(client: harness.client)),
        ),
      );
      await _feedLoad(
        tester,
        harness,
        retrievalData: retrievalTrue,
        vaultData: vaultData,
        stmmData: stmmData,
        journalData: searchData,
        settingsData: settingsData,
      );

      // Initial load: golden availability flag and golden journal row render.
      expect(
        (_row(tester, 'Retrieval available').trailing! as Text).data,
        'true',
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title as Text).data == entry['content'] &&
              widget.subtitle is Text &&
              (widget.subtitle as Text).data == entry['kind'],
          skipOffstage: false,
        ),
        findsOneWidget,
        reason: 'golden entry renders as title/subtitle',
      );

      // Tapping Search emits the golden camelCase query/limit verbatim.
      await tester.scrollUntilVisible(
        find.byKey(const Key('memory-search')),
        500.0,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('memory-search')),
        searchPayload['query'] as String,
      );
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Search'))
          .onPressed!();
      await tester.pump();
      final sent = _request(harness, 'journal.search');
      expect(sent['action'], 'journal.search');
      expect(sent['payload'], searchPayload, reason: 'camelCase wire payload');
      _reply(harness, 'journal.search', searchData);
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ListTile &&
              widget.title is Text &&
              (widget.title as Text).data == entry['content'] &&
              widget.subtitle is Text &&
              (widget.subtitle as Text).data == entry['kind'],
          skipOffstage: false,
        ),
        findsOneWidget,
        reason: 'golden entry still renders as title/subtitle after Search',
      );

      // Anti-vacuous: a second authoritative reply with available:false must
      // flip the row. RefreshIndicator.onRefresh is the documented _load path.
      tester
          .widget<RefreshIndicator>(find.byType(RefreshIndicator))
          .onRefresh!();
      await _feedLoad(
        tester,
        harness,
        retrievalData: retrievalFalse,
        vaultData: vaultData,
        stmmData: stmmData,
        journalData: searchData,
        settingsData: settingsData,
      );
      expect(
        (_row(tester, 'Retrieval available').trailing! as Text).data,
        'false',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'journalAppend and retrievalStatus decode the golden through the real client',
    (tester) async {
      final journal = _read('trace.journal.retrieval.json');
      final appendPayload = _body(journal, 2, 'payload');
      final appendReply = _body(journal, 3, 'data');
      final harness = await _connect(tester);

      final appending = harness.client.journalAppend(
        appendPayload['content'] as String,
        kind: appendPayload['kind'] as String,
      );
      await tester.pump();
      final sent = _request(harness, 'journal.append');
      expect(sent['payload'], appendPayload);
      _reply(harness, 'journal.append', appendReply);
      expect(await appending, appendReply['id']);

      final first = harness.client.retrievalStatus();
      _reply(harness, 'retrieval.status', _body(journal, 1, 'data'));
      expect(await first, isTrue);

      final second = harness.client.retrievalStatus();
      _reply(harness, 'retrieval.status', _body(journal, 7, 'data'));
      expect(await second, isFalse);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
