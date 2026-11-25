// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/settings/settings_catalog.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

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
}