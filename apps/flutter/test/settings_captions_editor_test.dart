// SPDX-License-Identifier: GPL-3.0-or-later

// Regression target for the persisted `settings/captions` shape
// (crates/anima-core/src/settings.rs:807-861). The editor must fail closed on
// malformed persisted values instead of PATCHing them back to the daemon.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/settings/captions_values.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

void main() {
  const invalidMessage =
      'Captions settings contain invalid values. Check each field and try again.';

  Widget screen(FakeChatClient client) => MaterialApp(
    home: Scaffold(
      body: SettingsScreen(client: client, onOpenConnections: () {}),
    ),
  );

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Save captions'),
  );

  Future<void> revealSave(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save captions');
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 60 && button.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  Future<void> revealText(WidgetTester tester, String text) async {
    final finder = find.text(text);
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  Future<void> loadAndSave(WidgetTester tester, FakeChatClient client) async {
    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await revealSave(tester);
    saveButton(tester).onPressed!();
    await tester.pumpAndSettle();
  }

  group('P0: malformed persisted captions values fail closed', () {
    // Each case mirrors one field of `CaptionsSettings` with an out-of-domain
    // value that a legacy or hand-edited blob could contain.
    final cases = <String, Map<String, dynamic>>{
      'docking': <String, dynamic>{'docking': 'side'},
      'layoutMode': <String, dynamic>{'layoutMode': 'triple'},
      'fontSize': <String, dynamic>{'fontSize': 201},
      'opacity': <String, dynamic>{'opacity': -1},
      // `followStrength` is the TS shorthand for the camelCase wire key.
      'followStrength': <String, dynamic>{
        'headTetheredCaptionFollowStrength': 101,
      },
      'resetTrigger': <String, dynamic>{'resetTrigger': -1},
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} is rejected before settingsSet', (
        tester,
      ) async {
        final client = FakeChatClient();
        addTearDown(client.dispose);
        client.settingsToLoad = <String, dynamic>{
          'enabled': true,
          'fontSize': 100,
          'opacity': 20,
          'docking': 'none',
          'layoutMode': 'single',
          'resetTrigger': 0,
          'headTetheredCaptionFollowStrength': 100.0,
          ...entry.value,
          'futureKey': 'keep-me',
        };

        await loadAndSave(tester, client);
        await revealText(tester, invalidMessage);

        expect(
          client.lastSettingsWritten,
          isNull,
          reason: '${entry.key}: no invalid draft reaches settingsSet',
        );
        expect(
          find.text(invalidMessage),
          findsOneWidget,
          reason: '${entry.key}: a sanitized error is shown',
        );
      });
    }
  });

  testWidgets('a valid captions save round-trips unknown keys', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.settingsToLoad = <String, dynamic>{
      'enabled': true,
      'fontSize': 100,
      'opacity': 20,
      'docking': 'bottom',
      'followStageVisibility': true,
      'followStagePosition': true,
      'layoutMode': 'single',
      'resetTrigger': 0,
      'headTetheredCaptionEnabled': false,
      'headTetheredCaptionOffset': <String, dynamic>{'x': 0.0, 'y': -15.0},
      'headTetheredCaptionFollowStrength': 100.0,
      'futureKey': 'keep-me',
    };

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await revealSave(tester);

    final tile = find.ancestor(
      of: find.text('Follow stage visibility'),
      matching: find.byType(SwitchListTile),
    );
    await tester.ensureVisible(tile);
    await tester.pumpAndSettle();
    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    await revealSave(tester);
    saveButton(tester).onPressed!();
    await tester.pump();

    final written = client.lastSettingsWritten;
    expect(written, isNotNull);
    expect(written!['followStageVisibility'], isFalse);
    expect(written['futureKey'], 'keep-me', reason: 'unknown key survives');
    expect(written['layoutMode'], 'single', reason: 'untouched field survives');
    expect(written['headTetheredCaptionOffset'], <String, dynamic>{
      'x': 0.0,
      'y': -15.0,
    });
    expect(written['headTetheredCaptionFollowStrength'], 100.0);
    expect(find.text(invalidMessage), findsNothing);
  });

  group('pure captions value helpers', () {
    test('sanitized error never echoes a bad value', () {
      final result = validateCaptions(<String, dynamic>{
        'docking': 'side',
        'fontSize': 201,
        'opacity': -1,
        'layoutMode': 'triple',
        'headTetheredCaptionFollowStrength': 101,
        'resetTrigger': -1,
      });
      expect(result.isValid, isFalse);
      expect(result.error, invalidMessage);
      expect(result.error, isNot(contains('side')));
      expect(result.error, isNot(contains('201')));
      expect(result.error, isNot(contains('101')));
      expect(result.error, isNot(contains('-1')));
    });

    test('normalization fills only absent keys and keeps unknown ones', () {
      final valid = <String, dynamic>{
        'enabled': true,
        'fontSize': 100,
        'opacity': 20,
        'docking': 'bottom',
        'followStageVisibility': true,
        'followStagePosition': true,
        'layoutMode': 'single',
        'resetTrigger': 0,
        'headTetheredCaptionEnabled': false,
        'headTetheredCaptionOffset': <String, dynamic>{'x': 0.0, 'y': -15.0},
        'headTetheredCaptionFollowStrength': 100.0,
      };
      expect(validateCaptions(valid).isValid, isTrue);

      final normalized = normalizeCaptions(<String, dynamic>{
        'docking': 'top',
        'futureKey': 'keep-me',
      });
      expect(normalized['docking'], 'top', reason: 'present values are kept');
      expect(
        normalized['fontSize'],
        100.0,
        reason: 'absent value is defaulted',
      );
      expect(normalized['headTetheredCaptionOffset'], <String, dynamic>{
        'x': 0.0,
        'y': -15.0,
      });
      expect(normalized['futureKey'], 'keep-me');
      expect(validateCaptions(normalized).isValid, isTrue);
    });
  });
}
