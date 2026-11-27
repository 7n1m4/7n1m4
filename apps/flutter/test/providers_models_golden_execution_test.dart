// SPDX-License-Identifier: GPL-3.0-or-later

// Round v29 real-execution leg for providers.models. The Rust leg
// (gateway_contract_tests.rs::providers_models_golden_execution_replays_through_real_handler)
// drives the REAL ungated handler; this leg boots a REAL DaemonClient over a
// ScriptedTransport, replays the UNCHANGED golden replies through the
// production ServerFrame codec, and pumps the REAL ProvidersScreen. No screen
// or client production code is edited.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/providers/providers_screen.dart';

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

final Map<String, dynamic> _healthyCore = <String, dynamic>{
  'app': 'anima-daemon',
  'version': '0.1.0',
  'coreAvailable': true,
  'storeAvailable': true,
  'storeHealth': 'ok',
  'protocol': 'airi-channel/1',
  'sessionCount': 3,
  'messageCount': 12,
};

const String _secretCanary = 'V29-PROVIDERS-MODELS-SECRET';

String _replyFrame(String action, Object id, Object? data) =>
    jsonEncode(<String, dynamic>{
      'type': 'rpc',
      'action': action,
      'ok': true,
      'id': id,
      'data': data,
    });

/// providers_list.reply.json is scaffolding only (its `kind: openai` is stale
/// versus the real `open-ai-compatible`, and its `updatedAt` is seconds while
/// the repo uses ms). Inject a non-rendered `apiKey` canary onto that row so the
/// "no secret in the widget tree" assertion is meaningful, not vacuous.
Map<String, dynamic> _listWithCanary(Map<String, dynamic> golden) {
  final row = (golden['providers'] as List).first as Map<String, dynamic>;
  return <String, dynamic>{
    'providers': <Map<String, dynamic>>[
      <String, dynamic>{...row, 'apiKey': _secretCanary},
    ],
  };
}

/// Answers every RPC the boot probe and ProvidersScreen put on the wire. Golden
/// reply payloads are fed through ServerFrame.parse before reaching the
/// transport, so the production codec is on the path for each replayed reply.
class _ProvidersGoldenPeer {
  _ProvidersGoldenPeer(
    this.transport, {
    required this.listGolden,
    required this.modelsGolden,
  });

  final ScriptedTransport transport;
  final Map<String, dynamic> listGolden;
  final Map<String, dynamic> modelsGolden;

  /// Every emitted rpc request frame, in wire order.
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];

  int _handled = 0;

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
        // Production codec, not a test-side map assignment.
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
    fail('providers.models golden replay did not quiesce after 16 waves');
  }

  Object? _dataFor(String action, Object? payload) {
    switch (action) {
      case 'core.status':
        return _healthyCore;
      case 'event.subscribe':
        return <String, dynamic>{'subscribed': true};
      case 'settings.get':
        return <String, dynamic>{
          'section': (payload as Map<String, dynamic>?)?['section'] ?? '',
          'settings': '{}',
        };
      case 'providers.list':
        return listGolden;
      case 'providers.models':
        return modelsGolden;
      default:
        return <String, dynamic>{};
    }
  }
}

void main() {
  testWidgets(
    'Rust golden providers.models drives a real DaemonClient and ProvidersScreen',
    (tester) async {
      final modelsGolden = _read('providers.models.reply.json');
      final listGolden = _listWithCanary(_read('providers_list.reply.json'));

      // Every golden reply parses through the production codec unchanged.
      for (final entry in <MapEntry<String, Map<String, dynamic>>>[
        MapEntry<String, Map<String, dynamic>>('providers.list', listGolden),
        MapEntry<String, Map<String, dynamic>>(
          'providers.models',
          modelsGolden,
        ),
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
      // The canary really travelled on the wire; it must not reach the tree.
      expect(jsonEncode(listGolden).contains(_secretCanary), isTrue);

      final transport = ScriptedTransport();
      final peer = _ProvidersGoldenPeer(
        transport,
        listGolden: listGolden,
        modelsGolden: modelsGolden,
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

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ProvidersScreen(client: client)),
        ),
      );
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();

      // The Models button (providers_screen.dart:581-584) drives the real RPC.
      final modelsButton = find.widgetWithText(OutlinedButton, 'Models');
      await tester.drag(find.byType(ListView), const Offset(0, -600));
      await tester.pump();
      await tester.ensureVisible(modelsButton);
      await tester.pumpAndSettle();
      await tester.tap(modelsButton);
      await tester.pump();
      await peer.drain(() => tester.pump());
      await tester.pumpAndSettle();

      // Wire: the real client emitted the exact request payload.
      final modelsCall = peer.requests.firstWhere(
        (frame) => frame['action'] == 'providers.models',
        orElse: () => fail('providers.models was never emitted'),
      );
      expect(modelsCall['payload'], <String, dynamic>{
        'providerId': 'openai',
      }, reason: 'the real DaemonClient must emit the golden provider id');

      // Rendered golden model tiles (providers_screen.dart:593-599).
      expect(find.text('gpt-4o'), findsOneWidget);
      final modelTile = find.widgetWithText(ListTile, 'gpt-4o');
      expect(modelTile, findsOneWidget);
      expect(
        find.descendant(of: modelTile, matching: find.text('openai')),
        findsOneWidget,
        reason: 'golden ownedBy=openai must render as the model subtitle',
      );

      // No injected secret anywhere in the widget tree.
      expect(find.textContaining(_secretCanary), findsNothing);
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
