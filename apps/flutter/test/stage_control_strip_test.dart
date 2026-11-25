// SPDX-License-Identifier: GPL-3.0-or-later

// Focused, hermetic coverage of the control-strip host state and widget.
// Taps report intent through `onAction`; nothing here contacts a daemon.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/stage_control_strip.dart';
import 'package:anima_control/features/stage/stage_control_strip_state.dart';

void main() {
  group('StageControlStripState', () {
    test('active buttons follow the daemon catalog order', () {
      final state = StageControlStripState();
      expect(state.activeButtons, <String>['stage', 'caption']);
      state.toggle('chat');
      expect(state.activeButtons, <String>['chat', 'stage', 'caption']);
      state.toggle('chat');
      expect(state.activeButtons, <String>['stage', 'caption']);
    });

    test('unknown ids can be toggled but never show in the catalog', () {
      final state = StageControlStripState(enabledButtons: <String>{'bogus'});
      expect(state.isEnabled('bogus'), isTrue);
      expect(state.activeButtons, isEmpty);
    });

    test('collapse and panel state are transient and resettable', () {
      final state = StageControlStripState();
      state.togglePanel('chat');
      expect(state.openPanel, 'chat');
      state.togglePanel('chat');
      expect(state.openPanel, isNull);
      state.toggleCollapsed();
      expect(state.collapsed, isTrue);
      state.setEdge(StageStripEdge.left);
      state.reset();
      expect(state.edge, StageStripEdge.right);
      expect(state.collapsed, isFalse);
      expect(state.openPanel, isNull);
      expect(state.activeButtons, <String>['stage', 'caption']);
    });

    test('settings round-trip camelCase fields and ignore unknown buttons', () {
      final settings = StageControlStripSettings.fromSettings(<String, dynamic>{
        'dockedEdge': 'left',
        'collapsed': true,
        'captionOpen': false,
        'backgroundTint': '#123456',
        'buttons': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'stage', 'enabled': true},
          <String, dynamic>{'id': 'chat', 'enabled': false},
          <String, dynamic>{'id': 'caption', 'enabled': true},
          <String, dynamic>{'id': 'bogus', 'enabled': true},
        ],
      });
      expect(settings.strip.edge, StageStripEdge.left);
      expect(settings.strip.collapsed, isTrue);
      expect(settings.strip.activeButtons, <String>['stage', 'caption']);
      expect(settings.captionStyle.isVisible, isFalse);
      expect(settings.backgroundTint, '#123456');
    });

    test('malformed settings fall back to platform defaults', () {
      final settings = StageControlStripSettings.fromSettings(
        const <String, dynamic>{
          'dockedEdge': 'elsewhere',
          'buttons': <Object>['not a map', 42],
          'backgroundTint': 12,
        },
      );
      expect(settings.strip.edge, StageStripEdge.right);
      expect(settings.strip.activeButtons, <String>['stage', 'caption']);
      expect(settings.backgroundTint, '#171717');
      expect(
        StageControlStripSettings.fromSettings(null).strip.collapsed,
        isFalse,
      );
    });
  });

  group('StageControlStrip widget', () {
    Future<void> pumpStrip(
      WidgetTester tester,
      StageControlStripState state,
      void Function(StageStripAction) onAction,
    ) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageControlStrip(state: state, onAction: onAction),
        ),
      ),
    );

    testWidgets('catalog icons are shown for enabled buttons only', (
      tester,
    ) async {
      await pumpStrip(tester, StageControlStripState(), (_) {});
      expect(find.byIcon(Icons.theater_comedy_outlined), findsOneWidget);
      expect(find.byIcon(Icons.closed_caption_outlined), findsOneWidget);
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      expect(find.byTooltip('stage'), findsOneWidget);
    });

    testWidgets('a tap reports its id without mutating state', (tester) async {
      final state = StageControlStripState();
      final actions = <String>[];
      await pumpStrip(tester, state, (action) => actions.add(action.buttonId));
      await tester.tap(find.byIcon(Icons.theater_comedy_outlined));
      await tester.pump();
      expect(actions, <String>['stage']);
      expect(state.activeButtons, <String>['stage', 'caption']);
    });

    testWidgets('a collapsed strip only reports the expand intent', (
      tester,
    ) async {
      final state = StageControlStripState(collapsed: true);
      final actions = <String>[];
      await pumpStrip(tester, state, (action) => actions.add(action.buttonId));
      expect(find.byIcon(Icons.expand_more), findsOneWidget);
      expect(find.byIcon(Icons.theater_comedy_outlined), findsNothing);
      await tester.tap(find.byIcon(Icons.expand_more));
      await tester.pump();
      expect(actions, <String>['__expand']);
    });

    testWidgets('docked edge places the pill on the requested side', (
      tester,
    ) async {
      final state = StageControlStripState(edge: StageStripEdge.left);
      await pumpStrip(tester, state, (_) {});
      // The strip's own root is the Align; the IconButtons add inner ones.
      final align = tester.widget<Align>(find.byType(Align).first);
      expect(align.alignment, Alignment.centerLeft);
    });

    testWidgets('a custom icon map is honored', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageControlStrip(
              state: StageControlStripState(),
              iconFor: (id) => Icons.star,
              onAction: (_) {},
            ),
          ),
        ),
      );
      expect(find.byIcon(Icons.star), findsNWidgets(2));
      expect(find.byIcon(Icons.theater_comedy_outlined), findsNothing);
    });
  });
}
