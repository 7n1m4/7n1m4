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

  Future<void> toggleSwitch(WidgetTester tester, String title) async {
    final tile = find.ancestor(
      of: find.text(title),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(
      of: tile,
      matching: find.byType(Switch),
    ));
    await tester.pumpAndSettle();
  }

  /// The sections the screen reads, in load order.
  const sections = <String>['general', 'theme', 'captions', 'control-strip'];

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

      expect(
        find.text('Connection failed. Check the daemon and retry.'),
        findsOneWidget,
      );
      expect(find.text('write denied'), findsNothing,
          reason: 'raw handler text is never rendered');
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
      final dockedEdge = find.ancestor(
        of: find.text('Docked edge'),
        matching: find.byType(DropdownButtonFormField<String>),
      );
      await tester.ensureVisible(dockedEdge);
      await tester.pumpAndSettle();
      await tester.tap(dockedEdge);
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
      // The stored entries keep their position and fields; only ids this
      // build actually surfaces (kStageStripCatalog) may be appended. Ids
      // without a stage dispatch are intentionally not advertised.
      expect(
        buttons.map((b) => b['id']).toList(),
        <String>['stage', 'gemini-tts', 'caption'],
        reason: 'the stored entries keep their position and fields',
      );
      final unknown = buttons.firstWhere((b) => b['id'] == 'gemini-tts');
      expect(unknown['label'], 'TTS Output Toggle',
          reason: 'an id this build does not surface is carried through');
      expect(unknown['enabled'], isFalse,
          reason: 'an unknown entry keeps its stored enabled state');
      expect(buttons.firstWhere((b) => b['id'] == 'stage')['enabled'], isTrue);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 5000));
      await tester.pumpAndSettle();
      expect(client.lastSettingsWritten, isNotNull);
    });
  });

  group('general section', () {
    testWidgets('switches write the fields the daemon owns, not remote sync',
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
                'language': 'en',
                'disableTransitions': true,
                'usePageSpecificTransitions': true,
                'websocketSecureEnabled': false,
                'autostart': false,
                'remoteSyncEnabled': true, // retired under airi-3cp
              },
            },
          );
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();
      await reveal(tester, 'Save general');

      // The one retired field is neither a control nor a new key on save.
      final card = find.ancestor(
        of: find.text('General Preferences'),
        matching: find.byType(Card),
      );
      final titles = tester
          .widgetList<SwitchListTile>(
            find.descendant(of: card, matching: find.byType(SwitchListTile)),
          )
          .map((widget) => (widget.title as Text).data)
          .toSet();
      expect(titles, <String>{
        'Disable page transitions',
        'Use page-specific transitions',
        'Secure websocket (wss://)',
        'Launch at login',
      });

      await toggleSwitch(tester, 'Launch at login');
      await toggleSwitch(tester, 'Secure websocket (wss://)');
      await toggleSwitch(tester, 'Disable page transitions');
      await reveal(tester, 'Save general');
      saveButton(tester, 'Save general').onPressed!();
      await tester.pump();

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['autostart'], isTrue);
      expect(written['websocketSecureEnabled'], isTrue);
      expect(written['disableTransitions'], isFalse);
      expect(written['usePageSpecificTransitions'], isTrue);
      expect(written['remoteSyncEnabled'], isTrue,
          reason: 'the retired key is preserved, never surfaced or rewritten');
    });

    testWidgets('invalid locale code is rejected before any write',
        (tester) async {
      final client = FakeChatClient()
        ..settingsToLoad = <String, dynamic>{'language': 'en'};
      addTearDown(client.dispose);

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();
      await reveal(tester, 'Save general');

      final field = find.widgetWithText(TextField, 'Language code');
      await tester.ensureVisible(field);
      await tester.pumpAndSettle();
      await tester.enterText(field, 'not a locale!');
      saveButton(tester, 'Save general').onPressed!();
      await tester.pumpAndSettle();

      expect(client.lastSettingsWritten, isNull,
          reason: 'invalid input never reaches settingsSet');
      expect(
        find.text('Use a locale code such as "en" or "zh-Hant".'),
        findsOneWidget,
      );

      // A valid edit clears the error and can be saved. Empty is the daemon's
      // "use system default" value.
      await tester.enterText(field, '');
      await reveal(tester, 'Save general');
      saveButton(tester, 'Save general').onPressed!();
      await tester.pump();
      expect(client.lastSettingsWritten!['language'], isEmpty);
    });
  });

  group('theme section', () {
    testWidgets('a preset and the dark toggle write typed theme settings',
        (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      String? writtenSection;
      client.onSet = (section, settings) => writtenSection = section;
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{
                'hue': 12.5,
                'hueDynamic': false,
                'chromaMultiplier': 'not a number', // normalized on load
                'dark': true,
                'futureKey': 'keep-me',
              },
            },
          );
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();
      await reveal(tester, 'Save theme');

      final preset = find.widgetWithText(TextButton, 'Ocean');
      await tester.ensureVisible(preset);
      await tester.pumpAndSettle();
      await tester.tap(preset);
      await tester.pumpAndSettle();
      await toggleSwitch(tester, 'Dark mode');
      await reveal(tester, 'Save theme');
      saveButton(tester, 'Save theme').onPressed!();
      await tester.pump();

      expect(writtenSection, 'theme');
      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['hue'], 262.88, reason: 'Ocean preset hue');
      expect(written['hueDynamic'], isFalse,
          reason: 'choosing a hue makes it manual');
      expect(written['dark'], isFalse);
      expect(written['chromaMultiplier'], 1.0,
          reason: 'malformed input was normalized to the daemon default');
      expect(written['futureKey'], 'keep-me',
          reason: 'untouched keys are sent back, not wiped');
    });

    testWidgets('reset restores palette defaults and keeps dark mode', (
      tester,
    ) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      client.onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(
            action: action,
            ok: true,
            data: <String, dynamic>{
              'settings': <String, dynamic>{
                'hue': 17.58,
                'hueDynamic': true,
                'chromaMultiplier': 1.5,
                'dark': false,
              },
            },
          );
        }
        throw StateError('unexpected action $action');
      };

      await tester.pumpWidget(screen(client));
      await tester.pumpAndSettle();
      await reveal(tester, 'Save theme');

      final reset = find.widgetWithText(TextButton, 'Reset to defaults');
      await tester.ensureVisible(reset);
      await tester.pumpAndSettle();
      await tester.tap(reset);
      await tester.pumpAndSettle();
      await reveal(tester, 'Save theme');
      saveButton(tester, 'Save theme').onPressed!();
      await tester.pump();

      final written = client.lastSettingsWritten;
      expect(written, isNotNull);
      expect(written!['hue'], 220.44);
      expect(written['hueDynamic'], isFalse);
      expect(written['chromaMultiplier'], 1.0);
      expect(written['dark'], isFalse,
          reason: 'a palette reset must not flip the user brightness choice');
    });
  });

  testWidgets('a settings failure shows a safe message, never the raw RPC text',
      (tester) async {
    // The shared fake swallows exceptions in settingsGet, so use a small
    // subclass that really throws like the client does on an RPC failure.
    final client = _FailingSettingsClient();
    addTearDown(client.dispose);
    const secret = '/home/user/.config/anima/token=abc123?key=secret';

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await reveal(tester, 'Save theme');
    // The error row sits below the section cards in the same lazily built
    // ListView; scroll until it is materialized.
    final safe = find.text(
      'Could not reach the daemon. Check the host and port, then retry.',
    );
    for (var i = 0; i < 40 && safe.evaluate().isEmpty; i++) {
      await tester.drag(find.byType(Scrollable).first, const Offset(0, -400));
      await tester.pumpAndSettle();
    }

    expect(find.textContaining('secret'), findsNothing);
    expect(find.textContaining('abc123'), findsNothing);
    expect(safe, findsOneWidget);
  });

  testWidgets('settings.changed reloads the section from the daemon', (tester) async {
    final client = FakeChatClient()
      ..settingsToLoad = <String, dynamic>{
        'language': 'en',
        'disableTransitions': true,
      };
    addTearDown(client.dispose);
    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    expect(client.settingsLoads, sections.length);

    // Another client changed `general`; the event carries no values, so the
    // screen must re-read the authoritative blob.
    client.settingsToLoad = <String, dynamic>{
      'language': 'ja',
      'disableTransitions': false,
      'remoteSyncEnabled': true,
    };
    client.emitEvent(GatewayEventFrame(
      topic: EventTopic.settingsChanged,
      rawTopic: 'settings.changed',
      data: <String, dynamic>{'section': 'general'},
    ));
    await tester.pumpAndSettle();
    expect(client.settingsLoads, greaterThan(3));

    await reveal(tester, 'Save general');
    saveButton(tester, 'Save general').onPressed!();
    await tester.pumpAndSettle();
    final written = client.lastSettingsWritten;
    expect(written, isNotNull);
    expect(written!['language'], 'ja');
    expect(written['remoteSyncEnabled'], true);
  });
}

/// A client whose settings.get really throws, as DaemonClient does on a
/// failed RPC (the shared fake swallows handler exceptions by design).
class _FailingSettingsClient extends FakeChatClient {
  @override
  Future<Map<String, dynamic>> settingsGet(String section) async {
    throw DaemonClientException(
      kind: DaemonFailureKind.transport,
      message: 'rpc failed at /home/user/.config/anima/token=abc123?key=secret',
    );
  }
}
