// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

void main() {
  /// The 24 swatches of `color-presets.json`, in group order, with the exact
  /// OKLCH hue each must write. Mirrors `settings_screen.dart`'s palette so a
  /// rename or a hue drift breaks the test.
  const palette = <({String group, String key, double hue})>[
    (group: 'warm', key: 'crimson', hue: 17.58),
    (group: 'warm', key: 'coral', hue: 16.44),
    (group: 'warm', key: 'tangerine', hue: 41.12),
    (group: 'warm', key: 'marigold', hue: 70.08),
    (group: 'warm', key: 'amber', hue: 86.05),
    (group: 'warm', key: 'lemon', hue: 130.85),
    (group: 'flora', key: 'lime', hue: 131.68),
    (group: 'flora', key: 'emerald', hue: 149.21),
    (group: 'flora', key: 'mint', hue: 162.48),
    (group: 'flora', key: 'jade', hue: 163.23),
    (group: 'flora', key: 'viridian', hue: 184.70),
    (group: 'flora', key: 'teal', hue: 221.72),
    (group: 'ocean', key: 'turquoise', hue: 215.22),
    (group: 'ocean', key: 'cyan', hue: 220.44), // null hex → daemon default
    (group: 'ocean', key: 'cerulean', hue: 262.88),
    (group: 'ocean', key: 'cobalt', hue: 259.81),
    (group: 'ocean', key: 'sapphire', hue: 276.97),
    (group: 'ocean', key: 'denim', hue: 277.12),
    (group: 'bloom', key: 'indigo', hue: 293.01),
    (group: 'bloom', key: 'amethyst', hue: 302.32),
    (group: 'bloom', key: 'violet', hue: 303.90),
    (group: 'bloom', key: 'fuchsia', hue: 322.90),
    (group: 'bloom', key: 'magenta', hue: 0.58),
    (group: 'bloom', key: 'rose', hue: 2.17),
  ];
  const groups = <String>['warm', 'flora', 'ocean', 'bloom'];

  Widget screen(FakeChatClient client) => MaterialApp(
        home: Scaffold(body: SettingsScreen(client: client, onOpenConnections: () {})),
      );

  FilledButton saveButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save theme'));

  /// The settings screen is one lazily built `ListView`; scroll until the
  /// theme card's Save button is painted so its swatches are in the tree.
  Future<void> reveal(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save theme');
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 40 && button.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  testWidgets('24 grouped swatches each apply their hue and turn dynamic off',
      (tester) async {
    final client = FakeChatClient()
      ..settingsToLoad = <String, dynamic>{
        'hue': 12.5,
        'hueDynamic': true,
        'chromaMultiplier': 1.5,
        'dark': true,
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await reveal(tester);

    expect(palette.length, 24);
    for (final group in groups) {
      expect(
        find.byKey(ValueKey<String>('theme-group-$group')),
        findsOneWidget,
        reason: '$group group header',
      );
    }

    for (final swatch in palette) {
      final finder = find.byKey(
        ValueKey<String>('theme-swatch-${swatch.group}-${swatch.key}'),
      );
      expect(finder, findsOneWidget,
          reason: '${swatch.group}/${swatch.key} swatch');
      final button = tester.widget<TextButton>(finder);
      expect(button.onPressed, isNotNull);
      button.onPressed!();
      await tester.pump();

      saveButton(tester).onPressed!();
      await tester.pump();

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['hue'], swatch.hue,
          reason: '${swatch.group}/${swatch.key} hue');
      expect(written['hueDynamic'], isFalse,
          reason: 'choosing any swatch makes the hue manual');
    }
  });

  testWidgets('reset restores daemon defaults and leaves dark mode alone',
      (tester) async {
    final client = FakeChatClient()
      ..settingsToLoad = <String, dynamic>{
        'hue': 293.01,
        'hueDynamic': true,
        'chromaMultiplier': 1.5,
        'dark': false,
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await reveal(tester);

    // Pick a swatch first so the palette is no longer at the default hue.
    tester
        .widget<TextButton>(
          find.byKey(const ValueKey<String>('theme-swatch-bloom-indigo')),
        )
        .onPressed!();
    await tester.pump();

    final reset = find.widgetWithText(TextButton, 'Reset to defaults');
    expect(reset, findsOneWidget);
    tester.widget<TextButton>(reset).onPressed!();
    await tester.pump();

    saveButton(tester).onPressed!();
    await tester.pump();

    final written = client.lastSettingsWritten;
    expect(written, isNotNull);
    expect(written!['hue'], 220.44);
    expect(written['hueDynamic'], isFalse);
    expect(written['chromaMultiplier'], 1.0);
    expect(written['dark'], isFalse,
        reason: 'a palette reset must not flip the brightness choice');
  });
}
