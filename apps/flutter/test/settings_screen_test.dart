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

  group('captions section', () {
    testWidgets('edits only the touched keys and reports the save',
        (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{
                'enabled': true,
                'fontSize': 100,
                'opacity': 70,
                'docking': 'none',
                'futureKey': 'keep-me', // a key this UI never edits
              },
            },
          );
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();

      await reveal(tester, 'Save captions');
      await tester.ensureVisible(find.widgetWithText(TextField, 'Font size (%)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Font size (%)'), '150');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      saveButton(tester, 'Save captions').onPressed!();
      await tester.pump();

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['fontSize'], 150.0);
      expect(written['docking'], 'none');
      expect(written['futureKey'], 'keep-me',
          reason: 'untouched keys are sent back, not wiped');
      expect(find.text('Captions settings saved.'), findsOneWidget);
    });

    testWidgets('a failed write surfaces the daemon error', (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{'enabled': true, 'docking': 'bottom'},
            },
          );
        }
        throw StateError('unexpected action $action');
      };
      client.onSet = (section, settings) {
        throw const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: 'write denied',
        );
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();

      await reveal(tester, 'Save captions');
      saveButton(tester, 'Save captions').onPressed!();
      await tester.pump();
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();

      expect(find.text('write denied'), findsOneWidget);
      expect(find.text('Captions settings saved.'), findsNothing);
    });
  });

  group('control-strip section', () {
    testWidgets('edits the docked edge and preserves the button catalog',
        (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{
                'dockedEdge': 'right',
                'collapsed': false,
                'captionOpen': false,
                'backgroundTint': '#171717',
                'buttons': <Map<String, dynamic>>[
                  <String, dynamic>{'id': 'stage', 'enabled': true},
                  <String, dynamic>{
                    'id': 'gemini-tts',
                    'enabled': false,
                    'label': 'TTS Output Toggle',
                    'icon': 'i-solar:volume-loud-linear',
                  },
                  <String, dynamic>{'id': 'caption', 'enabled': true},
                ],
              },
            },
          );
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();

      await reveal(tester, 'Save floating controls');
      await tester.ensureVisible(find.text('Docked edge'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Left').last);
      await tester.pumpAndSettle();
      saveButton(tester, 'Save floating controls').onPressed!();
      await tester.pumpAndSettle();

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['dockedEdge'], 'left');
      expect(written['backgroundTint'], '#171717');
      final buttons = (written['buttons'] as List)
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      expect(
        buttons.map((b) => b['id']).toList(),
        <String>['stage', 'gemini-tts', 'caption', 'chat', 'actor-characters', 'mic', 'stage-atmosphere'],
        reason: 'the stored entries keep their position and fields',
      );
      expect(buttons.firstWhere((b) => b['id'] == 'gemini-tts')['label'],
          'TTS Output Toggle',
          reason: 'an id this build does not surface is carried through');
      expect(buttons.firstWhere((b) => b['id'] == 'stage')['enabled'], isTrue);
      expect(buttons.firstWhere((b) => b['id'] == 'chat')['enabled'], isFalse);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(client.lastSettingsWritten, isNotNull);
    });
  });
}
