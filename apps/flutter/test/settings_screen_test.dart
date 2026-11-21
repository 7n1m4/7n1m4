// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

void main() {
  Widget screen(FakeChatClient client) => MaterialApp(
        home: Scaffold(body: SettingsScreen(client: client, onOpenConnections: () {})),
      );

  FilledButton saveButton(WidgetTester tester) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Save general'));

  testWidgets('Save is disabled until a real load and preserves unrelated keys',
      (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final pending = Completer<Map<String, dynamic>>();
    client.deferredSettings = pending;

    await tester.pumpWidget(screen(client));
    await tester.pump();

    // The section has not arrived yet: saving an empty map would make the
    // daemon refill every missing field with serde defaults.
    expect(saveButton(tester).onPressed, isNull);

    pending.complete(<String, dynamic>{
      'language': 'en',
      'disableTransitions': true,
      'usePageSpecificTransitions': true,
      'remoteSyncEnabled': true, // a key this UI never edits
    });
    await tester.pump();
    await tester.pump();

    expect(saveButton(tester).onPressed, isNotNull);
    await tester.enterText(find.byType(TextField), 'ja');
    saveButton(tester).onPressed!();
    await tester.pump();

    expect(client.lastSettingsWritten, isNotNull);
    expect(client.lastSettingsWritten!['language'], 'ja');
    expect(client.lastSettingsWritten!['remoteSyncEnabled'], isTrue,
        reason: 'untouched keys are sent back, not wiped');
  });

  testWidgets('Save stays disabled when the load fails', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final pending = Completer<Map<String, dynamic>>();
    client.deferredSettings = pending;

    await tester.pumpWidget(screen(client));
    await tester.pump();
    pending.completeError(const DaemonClientException(
      kind: DaemonFailureKind.notConnected,
      message: 'Not connected to the daemon.',
    ));
    await tester.pump();
    await tester.pump();

    expect(saveButton(tester).onPressed, isNull);
  });

  testWidgets('a reconnect reloads the general section', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.settingsToLoad = <String, dynamic>{'language': 'en'};
    // Start already connected so the first status below is a duplicate, not
    // a genuine transition that legitimately reloads.
    client.emitStatus(DaemonConnectionState.connected);

    await tester.pumpWidget(screen(client));
    await tester.pump();
    expect(client.settingsLoads, 1);

    // A repeated connected status is not a reconnect.
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(client.settingsLoads, 1);

    client.emitStatus(DaemonConnectionState.reconnecting);
    await tester.pump();
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(client.settingsLoads, 2,
        reason: 'fresh daemon state is reloaded before Save is allowed again');
  });
}
