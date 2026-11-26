// SPDX-License-Identifier: GPL-3.0-or-later

// Hermetic coverage for the bundled third-party notice screen.
//
// The screen is a thin reader over assets declared in
// `apps/flutter/pubspec.yaml`. This test proves the real `rootBundle` path is
// what feeds the reader: it opens `GPL-3.0-or-later.txt` through the tile and
// asserts verbatim license text reaches the screen. No network, no daemon
// client, no platform channel and no filesystem reads by the test itself; the
// only bytes involved are the ones `flutter test` serves from the declared
// asset bundle.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/about/about_screen.dart';

void main() {
  testWidgets('opens the bundled GPL notice text from rootBundle', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: ThirdPartyNoticesScreen()),
    );

    // The license tile is the entry point; the notice list itself renders the
    // asset directory so a wrong path would be visible here too.
    expect(find.text('Third-party notices'), findsOneWidget);
    expect(
      find.textContaining('assets/notices/LICENSES'),
      findsWidgets,
    );

    await tester.tap(find.text('GPL-3.0-or-later.txt'));
    await tester.pumpAndSettle();

    // Verbatim opening of the bundled license text. A tautology or a stubbed
    // bundle cannot produce this string.
    // SelectableText renders the whole text in one widget, so findsWidgets
    // tolerates the split-render form without weakening the phrase match.
    expect(find.textContaining('GNU GENERAL PUBLIC LICENSE'), findsWidgets);
    expect(find.textContaining('Version 3, 29 June 2007'), findsWidgets);
  });
}