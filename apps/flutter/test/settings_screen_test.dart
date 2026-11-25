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

  FilledButton saveButton(WidgetTester tester, String label) =>
      tester.widget<FilledButton>(find.widgetWithText(FilledButton, label));

  /// The settings screen is a single `ListView`; cards below the fold are
  /// built lazily, so `find` only matches painted ones. Scroll until the
  /// button we need is visible (same as a user scrolling).
  Future<void> reveal(WidgetTester tester, String label) async {
    final button = find.widgetWithText(FilledButton, label);
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 40 && button.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  /// The sections the screen reads, in load order.
  const sections = <String>['general', 'captions', 'control-strip'];

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
    await reveal(tester, 'Save general');
    expect(saveButton(tester, 'Save general').onPressed, isNull);

    pending.complete(<String, dynamic>{
      'language': 'en',
      'disableTransitions': true,
      'usePageSpecificTransitions': true,
      'remoteSyncEnabled': true, // a key this UI never edits
    });
    await tester.pump();
    await tester.pump();

    expect(saveButton(tester, 'Save general').onPressed, isNotNull);
    await tester.enterText(find.widgetWithText(TextField, 'Language code'), 'ja');
    saveButton(tester, 'Save general').onPressed!();
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

    for (final label in <String>[
      'Save general',
      'Save captions',
      'Save floating controls',
    ]) {
      await reveal(tester, label);
      expect(saveButton(tester, label).onPressed, isNull);
    }
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
    expect(client.settingsLoads, sections.length);

    // A repeated connected status is not a reconnect.
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(client.settingsLoads, sections.length);

    client.emitStatus(DaemonConnectionState.reconnecting);
    await tester.pump();
    client.emitStatus(DaemonConnectionState.connected);
    await tester.pump();
    expect(client.settingsLoads, sections.length * 2,
        reason: 'fresh daemon state is reloaded before Save is allowed again');
  });
