// SPDX-License-Identifier: GPL-3.0-or-later

// Round v30 real-execution Dart leg for the vault.status golden. Boots a REAL
// DaemonClient over a ScriptedTransport, replays the UNCHANGED golden payload
// through the production ServerFrame.parse -> RpcReply codec, and feeds it into
// the REAL DataScreen. data_screen.dart is frozen; only the documented
// vaultFilePorts test setter is used.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/data/data_screen.dart';
import 'package:anima_control/features/data/daemon_vault_ports.dart';

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

class _NoopVaultPorts implements VaultFilePorts {
  const _NoopVaultPorts();

  @override
  Future<PlatformFile?> pickJsonl() async => null;

  @override
  Future<Uri?> saveJsonl(String fileName, Uint8List bytes) async =>
      Uri.parse('file:///unused');

  @override
  Future<PlatformFile?> pickZip() async => null;

  @override
  Future<Uri?> saveZip(String fileName, Uint8List bytes) async =>
      Uri.parse('file:///unused');
}

class _Harness {
  _Harness(this.client, this.transport);

  final DaemonClient client;
  final ScriptedTransport transport;
}

/// Connect a real client. Auth + core.status probe use the same handshake as
/// the other golden execution test; `tester.pump()` drains the fake-async
/// microtasks instead of a real-timer `Future.delayed`.
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

  // connect() opts into four event topics. Drain their RPCs too, otherwise
  // their 5s timeout timers survive the test and fail the invariant check.
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

Map<String, dynamic> _request(_Harness harness, String action) {
  for (final frame in harness.transport.sent.reversed) {
    final decoded = jsonDecode(frame) as Map<String, dynamic>;
    if (decoded['action'] == action) return decoded;
  }
  fail('no $action request reached the wire');
}

/// Feed one rpc reply for [action] after the screen has issued it.
void _reply(_Harness harness, String action, Object? data, {bool ok = true}) {
  final id = _request(harness, action)['id'];
  transportFrame(harness, action, data, id, ok);
}

void transportFrame(
  _Harness harness,
  String action,
  Object? data,
  Object? id,
  bool ok,
) {
  final frame = jsonEncode(<String, dynamic>{
    'type': 'rpc',
    'action': action,
    'ok': ok,
    if (ok) 'data': data,
    if (!ok)
      'error': <String, dynamic>{
        'code': 'rpc_handler_error',
        'message': 'vault.status unavailable',
      },
    'id': id,
  });
  harness.transport.receive(frame);
}

int _screenSequence = 0;

Future<_Harness> _pumpScreen(WidgetTester tester) async {
  // The archive tiles live far down a lazily-built ListView; a tall surface
  // forces every tile to be built so the finders can see all four domains.
  tester.view.physicalSize = const Size(1200, 4000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final harness = await _connect(tester);
  // A distinct key forces a fresh State (and a fresh initState -> _load) for
  // every scenario; without it Flutter reuses the previous DataScreen State.
  await tester.pumpWidget(
    MaterialApp(
      home: DataScreen(
        key: ValueKey<int>(_screenSequence++),
        client: harness.client,
      ),
    ),
  );
  return harness;
}

/// Exact stat rows are plain ListTiles (archive tiles are CheckboxListTiles).
Iterable<Element> _statElements(WidgetTester tester, String title) => find
    .byWidgetPredicate(
      (widget) =>
          widget is ListTile &&
          widget.runtimeType == ListTile &&
          widget.title is Text &&
          (widget.title as Text).data == title &&
          widget.trailing is Text,
      skipOffstage: false,
    )
    .evaluate();

String? _statValue(WidgetTester tester, String title) {
  final elements = _statElements(tester, title).toList();
  expect(elements, hasLength(1), reason: 'exactly one $title stat row');
  final trailing = elements.single.widget as ListTile;
  final value = trailing.trailing;
  return value is Text ? value.data : null;
}

void _expectNoStats(WidgetTester tester) {
  for (final title in [
    'Chat sessions',
    'Chat messages',
    'Summaries',
    'Journal entries',
  ]) {
    expect(
      _statElements(tester, title),
      isEmpty,
      reason: '$title must not render without vault stats',
    );
  }
  expect(find.text('128 B', skipOffstage: false), findsNothing);
  expect(find.text('1 KB', skipOffstage: false), findsNothing);
  expect(find.text('512 B', skipOffstage: false), findsNothing);
}

void main() {
  late VaultFilePorts previous;

  setUp(() {
    previous = vaultFilePorts;
    vaultFilePorts = const _NoopVaultPorts();
  });

  tearDown(() {
    vaultFilePorts = previous;
  });

  testWidgets(
    'golden vault.status replays through the codec into the real DataScreen',
    (tester) async {
      final golden = _read('vault_status.reply.json');
      final harness = await _pumpScreen(tester);

      // The screen issued the verb, and the golden is decoded by production code.
      final vaultRequest = _request(harness, 'vault.status');
      final frame = jsonEncode(<String, dynamic>{
        'type': 'rpc',
        'action': 'vault.status',
        'ok': true,
        'data': golden,
        'id': vaultRequest['id'],
      });
      final parsed = ServerFrame.parse(frame);
      expect(parsed.parseError, isNull);
      expect(parsed.kind, ServerFrameKind.rpc);
      expect(parsed.reply, isNotNull);
      expect(
        parsed.reply!.data,
        golden,
        reason: 'unchanged golden survives the production codec',
      );
      harness.transport.receive(frame);

      await tester.pump();
      _reply(harness, 'sessions.list', <String, dynamic>{
        'sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();

      // Availability and every stat leaf come from the golden, not from a fake.
      final available = tester.widget<ListTile>(
        find.byKey(const Key('data-vault-available')),
      );
      expect((available.trailing! as Text).data, 'yes');
      expect(_statValue(tester, 'Chat sessions'), '3');
      expect(_statValue(tester, 'Chat messages'), '15');
      expect(_statValue(tester, 'Summaries'), '2');
      expect(_statValue(tester, 'Journal entries'), '7');

      // Archive domain tiles exist for the daemon's allowlist only.
      for (final domain in ['characters', 'chats', 'memory', 'backgrounds']) {
        expect(
          find.byKey(Key('data-archive-domain-$domain'), skipOffstage: false),
          findsOneWidget,
          reason: '$domain must be offered as an archive domain',
        );
      }
      expect(
        find.byKey(
          const Key('data-archive-domain-providers'),
          skipOffstage: false,
        ),
        findsNothing,
        reason:
            'providers carries credentials and must never be an archive domain',
      );
      expect(find.text('Providers', skipOffstage: false), findsNothing);

      // Byte sizes shown on the tiles are the golden's, through _reportedBytes.
      for (final entry in {
        'characters': '128 B',
        'chats': '1 KB',
        'memory': '512 B',
      }.entries) {
        final tile = tester.widget<CheckboxListTile>(
          find.byKey(
            Key('data-archive-domain-${entry.key}'),
            skipOffstage: false,
          ),
        );
        expect((tile.secondary! as Text).data, entry.value);
      }
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  testWidgets(
    'unavailable, malformed and failed vault replies never render stats',
    (tester) async {
      // (a) Honest unavailable reply: no stats object to render.
      var harness = await _pumpScreen(tester);
      _reply(harness, 'vault.status', <String, dynamic>{'available': false});
      await tester.pump();
      _reply(harness, 'sessions.list', <String, dynamic>{
        'sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();
      final available = tester.widget<ListTile>(
        find.byKey(const Key('data-vault-available')),
      );
      expect((available.trailing! as Text).data, 'no');
      _expectNoStats(tester);

      // (b) Malformed payload: a string is not an object, so vaultStatus() is null.
      harness = await _pumpScreen(tester);
      _reply(harness, 'vault.status', 'not-an-object');
      await tester.pump();
      _reply(harness, 'sessions.list', <String, dynamic>{
        'sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();
      _expectNoStats(tester);

      // (c) Malformed stats shape: stats must be a map, never a bare string.
      harness = await _pumpScreen(tester);
      _reply(harness, 'vault.status', <String, dynamic>{
        'available': true,
        'stats': 'nope',
      });
      await tester.pump();
      _reply(harness, 'sessions.list', <String, dynamic>{
        'sessions': <dynamic>[],
      });
      await tester.pumpAndSettle();
      _expectNoStats(tester);

      // (d) An rpc failure is surfaced as an error and still renders no stats.
      harness = await _pumpScreen(tester);
      _reply(harness, 'vault.status', null, ok: false);
      // _load aborts on the DaemonClientException, so no sessions.list verb is
      // issued in this scenario; only drain the frames the screen actually sent.
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('data-error'), skipOffstage: false),
        findsOneWidget,
      );
      _expectNoStats(tester);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
