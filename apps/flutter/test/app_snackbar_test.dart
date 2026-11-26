// SPDX-License-Identifier: GPL-3.0-or-later

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/ui/app_snackbar.dart';

Widget _subject({String first = 'First', String second = 'Second'}) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (BuildContext context) {
            return Column(
              children: [
                ElevatedButton(
                  onPressed: () => showAppSnackbar(context, first),
                  child: const Text('Show'),
                ),
                ElevatedButton(
                  onPressed: () => showAppSnackbar(context, second),
                  child: const Text('Show again'),
                ),
              ],
            );
          },
        ),
      ),
    );

void main() {
  testWidgets('shows a SnackBar carrying the passed message', (tester) async {
    // Distinct from any literal in production code: a hardcoded message fails.
    await tester.pumpWidget(_subject(first: 'Snapshot stored'));

    await tester.tap(find.text('Show'));
    await tester.pump();

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Snapshot stored'), findsOneWidget);
  });

  testWidgets('a second call replaces the first SnackBar', (tester) async {
    await tester.pumpWidget(_subject());

    await tester.tap(find.text('Show'));
    await tester.pump();

    await tester.tap(find.text('Show again'));
    // Let the outgoing snackbar finish hiding and the replacement appear.
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.text('Second'), findsOneWidget);
    expect(find.text('First'), findsNothing);
  });
}
