// SPDX-License-Identifier: GPL-3.0-or-later

// Hermetic coverage for the About screen's official links and build-info card.
// The launcher and build-define lookup are injected, so no browser, platform
// channel, or compiled-in define is touched: the assertions prove that
// AboutScreen renders the sections, each tap hands the exact canonical URL to
// url_launcher, and the card shows the supplied stamps or bundled fallback.

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
    expect(find.text('Build info'), findsOneWidget);
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

  testWidgets('build info renders the injected --dart-define values', (
    WidgetTester tester,
  ) async {
    // Supplied through the injectable lookup, not read from the production
    // constants: a card that ignores the defines cannot render these stamps.
    const Map<String, String> stamped = <String, String>{
      'BRANCH': 'feature/build-stamp',
      'COMMIT': '0c0ffee1',
      'BUILT_ON': '2026-11-26T03:04:05Z',
    };

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutBuildInfoCard(
            lookup: (String name) => stamped[name] ?? '',
          ),
        ),
      ),
    );

    // Expected strings are pinned as literals, independently of `stamped`.
    expect(find.text('Branch: feature/build-stamp'), findsOneWidget);
    expect(find.text('Commit: 0c0ffee1'), findsOneWidget);
    expect(find.text('Built on: 2026-11-26T03:04:05Z'), findsOneWidget);
  });

  testWidgets('blank defines fall back to bundled values', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: AboutBuildInfoCard(lookup: _blankDefine)),
      ),
    );

    // Pinned literally, not derived from production's bundled fallback.
    expect(find.text('Branch: unspecified'), findsOneWidget);
    expect(find.text('Commit: unspecified'), findsOneWidget);
    expect(
      find.text('Built on: bundled build (no --dart-define values)'),
      findsOneWidget,
    );
  });

  testWidgets('each blank define falls back on its own', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AboutBuildInfoCard(
            lookup: (String name) => name == 'COMMIT' ? '  deadbeef  ' : '  ',
          ),
        ),
      ),
    );

    expect(find.text('Branch: unspecified'), findsOneWidget);
    expect(find.text('Commit: deadbeef'), findsOneWidget);
    expect(
      find.text('Built on: bundled build (no --dart-define values)'),
      findsOneWidget,
    );
  });
}

String _blankDefine(String name) => '';
