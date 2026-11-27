// SPDX-License-Identifier: GPL-3.0-or-later

// Regression target for the persisted `settings/chat` shape
// (crates/anima-core/src/settings.rs:241-272). The editor must round-trip all
// five camelCase fields, preserve unknown keys, migrate the legacy 30s idle
// timeout, and fail closed on malformed persisted values instead of PATCHing
// them back to the daemon.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/settings/chat_values.dart';
import 'package:anima_control/features/settings/settings_screen.dart';

import 'support/fakes.dart';

void main() {
  const invalidMessage =
      'Chat settings contain invalid values. Check each field and try again.';

  const validSettings = <String, dynamic>{
    'sendMode': 'enter',
    'suggestMode': 'double-enter',
    'streamIdleTimeoutMs': 600000,
    'showDirectorNotes': true,
    'combineSystemMessages': false,
    'futureKey': 'keep-me',
  };

  Widget screen(FakeChatClient client) => MaterialApp(
    home: Scaffold(
      body: SettingsScreen(client: client, onOpenConnections: () {}),
    ),
  );

  FilledButton saveButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.widgetWithText(FilledButton, 'Save chat'),
  );

  Future<void> revealSave(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save chat');
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 60 && button.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  Future<void> revealKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    final scroll = find.byType(Scrollable).first;
    for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
      await tester.drag(scroll, const Offset(0, -400));
      await tester.pumpAndSettle();
    }
  }

  Future<void> tapKey(WidgetTester tester, Key key) async {
    final finder = find.byKey(key);
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
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

  testWidgets('a valid edit round-trips all five fields with one PATCH', (
    tester,
  ) async {
    final client = FakeChatClient()
      ..settingsToLoad = Map<String, dynamic>.from(validSettings);
    addTearDown(client.dispose);
    var patches = 0;
    client.onSet = (section, settings) {
      expect(section, 'chat', reason: 'the correct daemon section');
      patches++;
    };

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();

    // The UI shows the daemon's live values on load, not placeholders.
    await revealKey(tester, const Key('chat-send-mode'));
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('chat-send-mode')),
          )
          .initialValue,
      'enter',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('chat-suggest-mode')),
          )
          .initialValue,
      'double-enter',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('chat-stream-idle-timeout-ms')),
          )
          .controller!
          .text,
      '600000',
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('chat-show-director-notes')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('chat-combine-system-messages')),
          )
          .value,
      isFalse,
    );

    // Change every field through the editor itself.
    await tapKey(tester, const Key('chat-send-mode'));
    await tester.tap(find.text('Ctrl+Enter').last);
    await tester.pumpAndSettle();

    await tapKey(tester, const Key('chat-suggest-mode'));
    await tester.tap(find.text('Disabled').last);
    await tester.pumpAndSettle();

    await tester.ensureVisible(
      find.byKey(const Key('chat-stream-idle-timeout-ms')),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('chat-stream-idle-timeout-ms')),
      '120000',
    );
    await tester.pumpAndSettle();

    for (final key in const <Key>[
      Key('chat-show-director-notes'),
      Key('chat-combine-system-messages'),
    ]) {
      final tile = find.byKey(key);
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(of: tile, matching: find.byType(Switch)),
      );
      await tester.pumpAndSettle();
    }

    await revealSave(tester);
    saveButton(tester).onPressed!();
    await tester.pump();

    final written = client.lastSettingsWritten;
    expect(written, isNotNull);
    expect(
      written!['sendMode'],
      'ctrl-enter',
      reason: 'the edited field changed',
    );
    expect(written['suggestMode'], 'disabled');
    expect(written['streamIdleTimeoutMs'], 120000);
    expect(written['showDirectorNotes'], isFalse);
    expect(written['combineSystemMessages'], isTrue);
    expect(written['futureKey'], 'keep-me', reason: 'unknown key survives');
    expect(patches, 1, reason: 'exactly one well-formed PATCH is dispatched');
    expect(find.text(invalidMessage), findsNothing);
  });

  testWidgets('a settings.changed event reloads live daemon state', (
    tester,
  ) async {
    final client = FakeChatClient()
      ..settingsToLoad = Map<String, dynamic>.from(validSettings);
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await revealKey(tester, const Key('chat-send-mode'));

    client.settingsToLoad = <String, dynamic>{
      'sendMode': 'double-enter',
      'suggestMode': 'enter',
      'streamIdleTimeoutMs': 42000,
      'showDirectorNotes': false,
      'combineSystemMessages': true,
      'futureKey': 'keep-me',
    };
    client.emitEvent(
      const GatewayEventFrame(
        topic: EventTopic.settingsChanged,
        rawTopic: 'settings.changed',
        data: <String, dynamic>{'section': 'chat'},
      ),
    );
    await tester.pumpAndSettle();

    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('chat-send-mode')),
          )
          .initialValue,
      'double-enter',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('chat-suggest-mode')),
          )
          .initialValue,
      'enter',
    );
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('chat-stream-idle-timeout-ms')),
          )
          .controller!
          .text,
      '42000',
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('chat-show-director-notes')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const Key('chat-combine-system-messages')),
          )
          .value,
      isTrue,
    );
    expect(client.lastSettingsWritten, isNull);
  });

  testWidgets('a legacy 30000 ms timeout migrates to 600000 ms on load', (
    tester,
  ) async {
    final client = FakeChatClient()
      ..settingsToLoad = <String, dynamic>{
        ...validSettings,
        'streamIdleTimeoutMs': 30000,
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();
    await revealKey(tester, const Key('chat-stream-idle-timeout-ms'));
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('chat-stream-idle-timeout-ms')),
          )
          .controller!
          .text,
      '600000',
      reason: 'the legacy 30s value reads as the daemon default',
    );

    await revealSave(tester);
    saveButton(tester).onPressed!();
    await tester.pump();
    expect(client.lastSettingsWritten!['streamIdleTimeoutMs'], 600000);
  });

  group('P0: malformed persisted chat values fail closed', () {
    final cases = <String, Map<String, dynamic>>{
      'sendMode bad enum': <String, dynamic>{'sendMode': 'shift-enter'},
      'sendMode non-string': <String, dynamic>{'sendMode': 1},
      'suggestMode bad enum': <String, dynamic>{'suggestMode': 'space'},
      'suggestMode non-string': <String, dynamic>{
        'suggestMode': <String>['enter'],
      },
      'showDirectorNotes non-bool': <String, dynamic>{
        'showDirectorNotes': 'true',
      },
      'combineSystemMessages non-bool': <String, dynamic>{
        'combineSystemMessages': 0,
      },
      'timeout non-numeric': <String, dynamic>{'streamIdleTimeoutMs': 'soon'},
      'timeout negative': <String, dynamic>{'streamIdleTimeoutMs': -1},
      'timeout double': <String, dynamic>{'streamIdleTimeoutMs': 1.5},
      'timeout overflow': <String, dynamic>{
        'streamIdleTimeoutMs': BigInt.parse('18446744073709551616'),
      },
    };

    for (final entry in cases.entries) {
      testWidgets('${entry.key} is rejected before settingsSet', (
        tester,
      ) async {
        final client = FakeChatClient()
          ..settingsToLoad = <String, dynamic>{
            ...validSettings,
            ...entry.value,
          };
        addTearDown(client.dispose);

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

  group('pure chat value helpers', () {
    test('sanitized error never echoes a bad value', () {
      final result = validateChat(<String, dynamic>{
        'sendMode': 'shift-enter',
        'streamIdleTimeoutMs': BigInt.parse('18446744073709551616'),
      });
      expect(result.isValid, isFalse);
      expect(result.error, invalidMessage);
      expect(result.error, isNot(contains('shift')));
      expect(result.error, isNot(contains('18446744073709551616')));
    });

    test('normalization fills only absent keys and keeps unknown ones', () {
      expect(validateChat(validSettings).isValid, isTrue);

      final normalized = normalizeChat(<String, dynamic>{
        'sendMode': 'ctrl-enter',
        'futureKey': 'keep-me',
      });
      expect(
        normalized['sendMode'],
        'ctrl-enter',
        reason: 'present values kept',
      );
      expect(normalized['suggestMode'], 'double-enter');
      expect(normalized['streamIdleTimeoutMs'], 600000);
      expect(normalized['showDirectorNotes'], isTrue);
      expect(normalized['combineSystemMessages'], isFalse);
      expect(normalized['futureKey'], 'keep-me');
      expect(validateChat(normalized).isValid, isTrue);
    });

    test(
      'legacy 30000 migrates but malformed values survive normalization',
      () {
        final migrated = normalizeChat(<String, dynamic>{
          'streamIdleTimeoutMs': 30000,
          'futureKey': 'keep-me',
        });
        expect(migrated['streamIdleTimeoutMs'], 600000);
        expect(migrated['futureKey'], 'keep-me');

        final normalized = normalizeChat(<String, dynamic>{
          'sendMode': 42,
          'streamIdleTimeoutMs': 'soon',
        });
        expect(normalized['sendMode'], 42, reason: 'not coerced');
        expect(normalized['streamIdleTimeoutMs'], 'soon');
        expect(validateChat(normalized).isValid, isFalse);
      },
    );

    test('a double 30000.0 is not migrated and fails validation', () {
      final normalized = normalizeChat(<String, dynamic>{
        'streamIdleTimeoutMs': 30000.0,
        'futureKey': 'keep-me',
      });
      expect(
        normalized['streamIdleTimeoutMs'],
        30000.0,
        reason: 'a float is not the legacy int and must survive normalization',
      );
      expect(validateChat(normalized).isValid, isFalse);
      expect(normalized['futureKey'], 'keep-me');
    });

    test('a present unknown key is never deleted by normalization', () {
      final normalized = normalizeChat(<String, dynamic>{
        'futureKey': 'keep-me',
        'nested': <String, dynamic>{'a': 1},
      });
      expect(normalized['futureKey'], 'keep-me');
      expect(normalized['nested'], <String, dynamic>{'a': 1});
    });
  });
}
