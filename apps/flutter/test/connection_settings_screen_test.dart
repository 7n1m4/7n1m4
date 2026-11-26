// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/connection/connection_settings_screen.dart';

void main() {
  Widget screen({required Future<void> Function(ConnectionSettings) onConnect}) =>
      MaterialApp(
        home: Scaffold(
          body: ConnectionSettingsScreen(
            onConnect: onConnect,
            onDisconnect: () async {},
          ),
        ),
      );

  Future<void> connect(WidgetTester tester) async {
    await tester.enterText(find.widgetWithText(TextFormField, 'Auth token'), 'tok');
    // Host's controller has a rebuild listener, so re-entering its value
    // refreshes the form's build-time validators to see the token typed above.
    await tester.enterText(find.widgetWithText(TextFormField, 'Host'), '127.0.0.1');
    // The form is a plain Column (not scrollable); call onPressed directly the
    // same way settings_screen_test.dart does, bypassing off-screen hit-testing.
    tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'Connect'))
        .onPressed!();
    await tester.pumpAndSettle();
  }

  testWidgets('renders an optional CA certificate path field', (tester) async {
    await tester.pumpWidget(screen(onConnect: (_) async {}));

    expect(find.widgetWithText(TextFormField, 'CA certificate path'), findsOneWidget);
    expect(find.textContaining('daemon setup'), findsOneWidget);
  });

  testWidgets('a filled CA path reaches onConnect as caCertPath', (tester) async {
    ConnectionSettings? captured;
    await tester.pumpWidget(screen(onConnect: (settings) async {
      captured = settings;
    }));

    await tester.enterText(
      find.widgetWithText(TextFormField, 'CA certificate path'),
      '/etc/anima/ca.pem',
    );
    await connect(tester);

    expect(captured, isNotNull);
    expect(captured!.caCertPath, '/etc/anima/ca.pem');
  });

  testWidgets('a blank or whitespace-only CA path reaches onConnect as null',
      (tester) async {
    final captured = <ConnectionSettings?>[];
    await tester.pumpWidget(screen(onConnect: (settings) async {
      captured.add(settings);
    }));

    await connect(tester); // untouched blank field
    await tester.enterText(
      find.widgetWithText(TextFormField, 'CA certificate path'),
      '   ',
    );
    await connect(tester); // whitespace-only

    expect(captured, hasLength(2));
    expect(captured[0]!.caCertPath, isNull);
    expect(captured[1]!.caCertPath, isNull);
  });
}
