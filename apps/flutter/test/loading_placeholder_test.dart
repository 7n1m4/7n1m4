// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/ui/loading_placeholder.dart';

const Key _shapeKey = ValueKey<String>('placeholder-shape');

Widget _subject({bool disableAnimations = false}) => MediaQuery(
      data: MediaQueryData(disableAnimations: disableAnimations),
      child: const LoadingPlaceholder(
        child: SizedBox(key: _shapeKey, width: 123, height: 87),
      ),
    );

void main() {
  testWidgets('preserves the child shape and announces Loading', (tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _subject())),
    );

    expect(tester.getSize(find.byKey(_shapeKey)), const Size(123, 87));
    expect(find.bySemanticsLabel('Loading'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets('pulses opacity while motion is allowed', (tester) async {
    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: _subject())),
    );

    final FadeTransition transition = tester.widget<FadeTransition>(
      find.descendant(
        of: find.byType(LoadingPlaceholder),
        matching: find.byType(FadeTransition),
      ),
    );
    final double initial = transition.opacity.value;
    await tester.pump(const Duration(milliseconds: 300));
    expect(transition.opacity.value, isNot(equals(initial)));
  });

  testWidgets('reduced motion keeps the placeholder static', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: _subject(disableAnimations: true)),
      ),
    );

    expect(
      find.descendant(
        of: find.byType(LoadingPlaceholder),
        matching: find.byType(FadeTransition),
      ),
      findsNothing,
    );
    // A repeating ticker would stop pumpAndSettle from ever settling.
    await tester.pumpAndSettle();
    final Opacity opacity = tester.widget<Opacity>(
      find.descendant(
        of: find.byType(LoadingPlaceholder),
        matching: find.byType(Opacity),
      ),
    );
    expect(opacity.opacity, 0.7);
    expect(tester.getSize(find.byKey(_shapeKey)), const Size(123, 87));
  });
}
