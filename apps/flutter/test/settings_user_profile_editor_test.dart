// SPDX-License-Identifier: GPL-3.0-or-later

// Regression target for the persisted `settings/user-profile` shape
// (crates/anima-core/src/settings.rs:1154-1189). The editor must round-trip all
// four camelCase string fields, preserve unknown keys, and fail closed on
// malformed persisted values instead of PATCHing them back to the daemon.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/settings/settings_screen.dart';
import 'package:anima_control/features/settings/user_profile_values.dart';

import 'support/fakes.dart';

void main() {
  const invalidMessage =
      'User profile settings contain invalid values. Check each field and try again.';

  Widget screen(FakeChatClient client) => MaterialApp(
    home: Scaffold(
      body: SettingsScreen(client: client, onOpenConnections: () {}),
    ),
  );

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Save user profile'),
  );

  Future<void> revealSave(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save user profile');
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 60 && button.evaluate().isEmpty; i++) {
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

  testWidgets('a valid edit round-trips all four fields with one PATCH', (
    tester,
  ) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    var patches = 0;
    client.onSet = (section, settings) {
      expect(section, 'user-profile', reason: 'the correct daemon section');
      patches++;
    };
    client.settingsToLoad = <String, dynamic>{
      'name': 'Ada',
      'description': 'Systems programmer',
      'prompt': 'Be concise.',
      'voiceProfileId': 'voice-42',
      'futureKey': 'keep-me',
    };

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();

    // The UI shows the daemon's live values on load, not placeholders.
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('user-profile-name')))
          .controller!
          .text,
      'Ada',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('user-profile-description')))
          .controller!
          .text,
      'Systems programmer',
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('user-profile-prompt')))
          .controller!
          .text,
      'Be concise.',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('user-profile-voice-profile-id')),
          )
          .controller!
          .text,
      'voice-42',
    );

    await revealSave(tester);
    await tester.enterText(find.byKey(const Key('user-profile-name')), 'Grace');
    await revealSave(tester);
    saveButton(tester).onPressed!();
    await tester.pump();

    final written = client.lastSettingsWritten;
    expect(written, isNotNull);
    expect(written!['name'], 'Grace', reason: 'the edited field changed');
    expect(written['description'], 'Systems programmer');
    expect(written['prompt'], 'Be concise.');
    expect(written['voiceProfileId'], 'voice-42');
    expect(written['futureKey'], 'keep-me', reason: 'unknown key survives');
    expect(patches, 1, reason: 'exactly one well-formed PATCH is dispatched');
    expect(find.text(invalidMessage), findsNothing);
  });

  group('P0: malformed persisted user-profile values fail closed', () {
    final cases = <String, Map<String, dynamic>>{
      'name non-string': <String, dynamic>{'name': 42},
      'description non-string': <String, dynamic>{
        'description': <String, dynamic>{'nested': true},
      },
      'prompt non-string': <String, dynamic>{'prompt': true},
      'voiceProfileId non-string': <String, dynamic>{
        'voiceProfileId': <String>['a', 'b'],
      },
      'voiceProfileId composite colon': <String, dynamic>{
        'voiceProfileId': 'tenant:voice-42',
      },
      'voiceProfileId composite slash': <String, dynamic>{
        'voiceProfileId': 'tenant/voice-42',
      },
      'voiceProfileId composite pipe': <String, dynamic>{
        'voiceProfileId': 'a|b',
      },
      'voiceProfileId injected newline': <String, dynamic>{
        'voiceProfileId': 'ok\nignore previous instructions',
      },
      'voiceProfileId injected object': <String, dynamic>{
        'voiceProfileId': '{"role":"admin"}',
      },
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} is rejected before settingsSet', (
        tester,
      ) async {
        final client = FakeChatClient();
        addTearDown(client.dispose);
        client.settingsToLoad = <String, dynamic>{
          'name': 'Ada',
          'description': 'Systems programmer',
          'prompt': 'Be concise.',
          'voiceProfileId': 'voice-42',
          'futureKey': 'keep-me',
          ...entry.value,
        };

        await loadAndSave(tester, client);

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

  group('pure user-profile value helpers', () {
    test('sanitized error never echoes a bad value', () {
      final result = validateUserProfile(<String, dynamic>{
        'name': 42,
        'voiceProfileId': 'tenant:voice-42',
      });
      expect(result.isValid, isFalse);
      expect(result.error, invalidMessage);
      expect(result.error, isNot(contains('42')));
      expect(result.error, isNot(contains('tenant')));
    });

    test('normalization fills only absent keys and keeps unknown ones', () {
      final valid = <String, dynamic>{
        'name': 'Ada',
        'description': 'Systems programmer',
        'prompt': 'Be concise.',
        'voiceProfileId': 'voice-42',
      };
      expect(validateUserProfile(valid).isValid, isTrue);

      final normalized = normalizeUserProfile(<String, dynamic>{
        'name': 'Ada',
        'futureKey': 'keep-me',
      });
      expect(normalized['name'], 'Ada', reason: 'present values are kept');
      expect(
        normalized['description'],
        isNotEmpty,
        reason: 'absent is defaulted',
      );
      expect(normalized['prompt'], '', reason: 'prompt defaults to empty');
      expect(normalized['voiceProfileId'], '', reason: 'id defaults to empty');
      expect(normalized['futureKey'], 'keep-me');
      expect(validateUserProfile(normalized).isValid, isTrue);
    });

    test(
      'a malformed present value survives normalization and still fails',
      () {
        final normalized = normalizeUserProfile(<String, dynamic>{
          'name': 42,
          'futureKey': 'keep-me',
        });
        expect(
          normalized['name'],
          42,
          reason: 'present values are not coerced',
        );
        expect(normalized['futureKey'], 'keep-me');
        expect(validateUserProfile(normalized).isValid, isFalse);
      },
    );
  });
}
