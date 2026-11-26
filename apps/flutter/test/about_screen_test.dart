// SPDX-License-Identifier: GPL-3.0-or-later

// Hermetic coverage for the About screen's official links. The launcher is
// injected, so no browser or platform channel is touched: the assertions prove
// both that AboutScreen renders the section and that each tap hands the exact
// canonical URL to url_launcher.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/about/about_screen.dart';

// Pinned independently of production's `aboutLinks`: a typo in a canonical URL
// must fail this suite, not silently redefine what "correct" means.
const List<({String label, String url})> expectedLinks =
    <({String label, String url})>[
  (
    label: 'Documentation',
    url: 'https://dasilva333.github.io/airi/en/docs/overview/',
  ),
  (
    label: 'Web Stage',
    url: 'https://dasilva333.github.io/airi/web-stage/',
  ),
  (
    label: 'GitHub',
    url: 'https://github.com/dasilva333/airi',
  ),
];

void main() {
  testWidgets('About screen renders the official links section', (
    WidgetTester tester,
  ) async {
    // Give the ListView room to build every tile, not just the viewport slice.
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: AboutScreen())),
    );

    expect(find.text('Links'), findsOneWidget);
    for (final link in expectedLinks) {
      expect(find.text(link.label), findsOneWidget);
      expect(find.text(link.url), findsOneWidget);
    }
  });

  testWidgets('each link launches its exact canonical URL', (
    WidgetTester tester,
  ) async {
    final List<Uri> launched = <Uri>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutLinksSection(
            launch: (Uri url) async {
              launched.add(url);
              return true;
            },
          ),
        ),
      ),
    );

    // Guard the exact set, not just a subset: an extra or missing link must fail.
    expect(find.byType(ListTile), findsNWidgets(expectedLinks.length));

    for (final link in expectedLinks) {
      await tester.tap(find.text(link.label));
      expect(launched, <Uri>[Uri.parse(link.url)]);
      launched.clear();
    }
    expect(launched, isEmpty);
  });
}
