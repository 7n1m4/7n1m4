// SPDX-License-Identifier: GPL-3.0-or-later

// Deterministic source check plus widget taps: every catalog node the user
// can see must reach a real destination; hidden tiles must not be routed.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/settings_catalog.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

const _router = 'lib/features/settings/settings_screen.dart';

void main() {
  test('every visible catalog node has a router case', () {
    final source = File(_router).readAsStringSync();
    final catalogMethod = RegExp(r'_openCatalogNode\s*\([^)]*\)\s*(?:async\s*)?\{')
        .firstMatch(source);
    expect(catalogMethod, isNotNull, reason: '_openCatalogNode switch is present');
    final catalogStart = catalogMethod!.start;
    final catalogEnd = source.indexOf('\n  }', catalogStart);
    final catalogSwitch = catalogEnd == -1
        ? source.substring(catalogStart)
        : source.substring(catalogStart, catalogEnd);
    final handled = RegExp(r"case '(area-[a-z-]+|sys-[a-z-]+)':")
        .allMatches(catalogSwitch)
        .map((match) => match.group(1))
        .toSet();
    final visible = settingsCatalogTopology.nodesById.values
        .where((node) => node.visible && node.id != settingsCatalogTopology.rootId);
    for (final node in visible) {
      // Visible nodes are tiles (a case) or inline settings cards (a scroll
      // target in the same router).
      expect(handled, contains(node.id), reason: '${node.id} is visible');
    }
    for (final node in settingsCatalogTopology.nodesById.values
        .where((node) => !node.visible && node.id.startsWith('area-'))) {
      expect(handled, isNot(contains(node.id)), reason: '${node.id} is hidden');
    }
  });

  testWidgets('routing every visible catalog tile has a behavior', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final client = FakeChatClient()
      ..onCall = (action, payload) {
        if (action == 'settings.get' || action == 'core.status' || action == 'vault.status') {
          return RpcReply(action: action, ok: true, data: <String, dynamic>{'settings': <String, dynamic>{}});
        }
        if (action == 'sessions.list' || action == 'stmm.list' || action == 'journal.search' ||
            action == 'cards.list' || action == 'providers.models' ||
            action == 'retrieval.status' || action == 'runtime.status' || action == 'providers.list') {
          return RpcReply(action: action, ok: true, data: <String, dynamic>{});
        }
        throw StateError('unexpected action $action');
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: SettingsScreen(client: client, onOpenConnections: () {})),
    ));
    await tester.pumpAndSettle();

    final destinations = <String, String>{
      'AIRI Card Editor': 'Cards',
      'Memory Systems': 'Memory',
      'Companion Connectors': 'Companion Connectors',
      'Inference Providers': 'Providers',
      'Sessions': 'Sessions',
      'Data Management': 'Data',
    };

    for (final entry in destinations.entries) {
      // Every tile must be a real ListTile with a non-null tap handler.
      final tile = tester.widgetList<ListTile>(find.widgetWithText(ListTile, entry.key))
          .where((widget) => widget.onTap != null);
      expect(tile, hasLength(1), reason: '${entry.key} tile is tappable');

      final finder = find.widgetWithText(ListTile, entry.key).last;
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();

      expect(find.text(entry.value), findsWidgets, reason: '${entry.key} destination');
      await tester.tap(find.byIcon(Icons.arrow_back).last);
      await tester.pumpAndSettle();
    }
  });
}
