// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/settings_catalog.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

class _HydrationClient extends FakeChatClient {
  _HydrationClient({required this.runtimeStatus, required this.failProviders, this.throwOnCall = false});

  final Map<String, dynamic> runtimeStatus;
  final bool failProviders;
  final bool throwOnCall;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (throwOnCall) throw const DaemonClientException(kind: DaemonFailureKind.notConnected, message: 'offline');
    if (action == 'providers.list') {
      if (failProviders) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'unavailable', message: 'providers unavailable'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'providers': <Map<String, dynamic>>[
            <String, dynamic>{
              'id': 'openai',
              'kind': 'openai',
              'model': 'gpt-test',
              'baseUrl': 'https://example.invalid',
              'enabled': true,
              'updatedAt': 1,
            },
          ],
        },
      );
    }
    if (action == 'runtime.status') {
      return RpcReply(action: action, ok: true, data: runtimeStatus);
    }
    return super.call(action, payload: payload);
  }
}

void main() {
  test('curated topology matches the canonical root-to-area ordering', () {
    expect(
      settingsCatalogTopology.orderedChildren('hub').map((node) => node.id).toList(),
      <String>[
        'area-card',
        'area-models',
        'area-scene',
        'area-memory',
        'area-modules',
        'area-providers',
        'area-data',
        'area-system',
        'area-stage',
        'area-docs',
        'area-about',
      ],
    );
    expect(resolveSettingsPath(settingsCatalogTopology, 'missing'), <String>['hub']);
    expect(resolveSettingsPath(settingsCatalogTopology, 'sys-general'), <String>['hub', 'area-system', 'sys-general']);
    expect(settingsCatalogTopology.orderedChildren('area-modules').map((node) => node.label).toList(), isNot(contains('Artistry (Deprecated)')));
  });

  testWidgets('catalog-driven hub renders all visible top-level areas', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(height: 1200, child: SettingsScreen(client: client, onOpenConnections: () {}))),
    ));
    await tester.pumpAndSettle();

    final visible = settingsCatalogTopology.orderedChildren('hub').where((n) => n.visible).toList();
    expect(visible.map((n) => n.label), containsAll(<String>['AIRI Card Editor','System Preferences','About AIRI']));
    for (final node in visible.take(7)) {
      expect(find.byWidgetPredicate((w) => w is Text && w.data == node.label), findsOneWidget);
    }
    expect(find.text('Artistry (Deprecated)'), findsNothing);
  });

  testWidgets('provider-backed settings hydrate from daemon reads and fall back cleanly', (tester) async {
    final connected = _HydrationClient(
      runtimeStatus: <String, dynamic>{
        'app': 'anima-daemon',
        'version': 'test-version',
        'pid': 42,
        'uptimeSeconds': 9,
        'protocol': 'test-protocol',
      },
      failProviders: false,
    );
    addTearDown(connected.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(height: 1200, child: SettingsScreen(client: connected, onOpenConnections: () {}))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Runtime: anima-daemon test-version'), findsOneWidget);
    expect(find.text('Providers: 1 enabled'), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    final disconnected = _HydrationClient(
      runtimeStatus: const <String, dynamic>{},
      throwOnCall: true,
      failProviders: true,
    );
    addTearDown(disconnected.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SizedBox(height: 1200, child: SettingsScreen(client: disconnected, onOpenConnections: () {}))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Runtime: unavailable'), findsOneWidget);
    expect(find.text('Providers: unavailable'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('AIRI Card Editor'), findsOneWidget);
  });
}