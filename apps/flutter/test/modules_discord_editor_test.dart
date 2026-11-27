// SPDX-License-Identifier: GPL-3.0-or-later

// P0 coverage for the Discord masked-view → PATCH boundary. The daemon returns
// a token-free view with a `hasToken` boolean; a thin client must be able to
// edit it without ever echoing a read-backed token, leaking it into the UI, or
// wiping the stored credential with a blank field.

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/modules/discord_settings_patch.dart';
import 'package:anima_control/features/modules/modules_screen.dart';

import 'support/fakes.dart';

void main() {
  group('buildDiscordPatch', () {
    test('a masked read with hasToken emits neither token nor hasToken', () {
      final patch = buildDiscordPatch(<String, dynamic>{
        'enabled': true,
        'hasToken': true,
        'ownerUsername': 'alice',
      });
      expect(patch.containsKey('token'), isFalse);
      expect(patch.containsKey('hasToken'), isFalse);
      expect(patch['ownerUsername'], 'alice');
    });

    test('a token echoed from a read is dropped, never rotated', () {
      final patch = buildDiscordPatch(<String, dynamic>{
        'hasToken': true,
        'token': 'MT-READ-ECHO-LEAK',
      });
      expect(patch.containsKey('token'), isFalse);
      expect(patch.toString(), isNot(contains('MT-READ-ECHO-LEAK')));
    });

    test('an empty or whitespace typed token is omitted', () {
      final blank = buildDiscordPatch(const <String, dynamic>{
        'enabled': true,
      }, typedToken: '');
      expect(blank.containsKey('token'), isFalse);
      final spaces = buildDiscordPatch(const <String, dynamic>{
        'enabled': true,
      }, typedToken: '   ');
      expect(spaces.containsKey('token'), isFalse);
    });

    test('a token is emitted only when freshly typed', () {
      final view = <String, dynamic>{'hasToken': true, 'enabled': true};
      expect(buildDiscordPatch(view).containsKey('token'), isFalse);
      expect(
        buildDiscordPatch(
          view,
          edits: <String, dynamic>{'token': 'MT-EDIT-SHOULD-BE-IGNORED'},
        ).containsKey('token'),
        isFalse,
      );
      expect(
        buildDiscordPatch(view, typedToken: 'MT-FRESH-TOKEN')['token'],
        'MT-FRESH-TOKEN',
      );
    });

    test('only allowlisted mode values are emitted', () {
      final patch = buildDiscordPatch(
        <String, dynamic>{
          'executionMode': 'local',
          'chatMode': 'followup',
          'voiceMode': 'puppet',
          'voiceCall': 'off',
        },
        edits: <String, dynamic>{
          'executionMode': 'magic',
          'chatMode': 'steer',
          'voiceMode': 'sideways',
          'voiceCall': 'gemini',
        },
      );
      expect(patch.containsKey('executionMode'), isFalse);
      expect(patch['chatMode'], 'steer');
      expect(patch.containsKey('voiceMode'), isFalse);
      expect(patch['voiceCall'], 'gemini');
    });

    test('sibling keys from the masked view round-trip unchanged', () {
      final view = <String, dynamic>{
        'enabled': true,
        'executionMode': 'remote',
        'ownerUsername': 'alice',
        'ownerUserId': '12345',
        'lastRegisteredVersion': 7,
        'chatMode': 'collect',
        'voiceMode': 'none',
        'voiceCall': 'classic',
        'visionEnabled': true,
        'dmsEnabled': false,
        'hasToken': true,
      };
      final patch = buildDiscordPatch(
        view,
        edits: <String, dynamic>{'enabled': false},
      );
      expect(patch['enabled'], false);
      expect(patch['executionMode'], 'remote');
      expect(patch['ownerUsername'], 'alice');
      expect(patch['ownerUserId'], '12345');
      expect(patch['lastRegisteredVersion'], 7);
      expect(patch['chatMode'], 'collect');
      expect(patch['voiceMode'], 'none');
      expect(patch['voiceCall'], 'classic');
      expect(patch['visionEnabled'], true);
      expect(patch['dmsEnabled'], false);
      expect(patch.containsKey('hasToken'), isFalse);
      expect(patch.containsKey('token'), isFalse);
    });
  });

  group('DiscordSectionEditor UI', () {
    setUp(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .implicitView!;
      view.physicalSize = const Size(1200, 12000);
      view.devicePixelRatio = 1;
    });

    tearDown(() {
      final view = TestWidgetsFlutterBinding.ensureInitialized()
          .platformDispatcher
          .implicitView!;
      view.resetPhysicalSize();
      view.resetDevicePixelRatio();
    });

    Widget editor(FakeChatClient client) => MaterialApp(
      home: Scaffold(body: DiscordSectionEditor(client: client)),
    );

    FakeChatClient maskedClient() =>
        FakeChatClient()
          ..onCall = (action, payload) {
            if (action == 'settings.get') {
              return RpcReply(
                action: action,
                ok: true,
                data: <String, dynamic>{
                  'settings': <String, dynamic>{
                    'enabled': true,
                    'hasToken': true,
                    'ownerUsername': 'alice',
                    'ownerUserId': '12345',
                    'executionMode': 'local',
                    'chatMode': 'followup',
                    'voiceMode': 'puppet',
                    'voiceCall': 'off',
                  },
                },
              );
            }
            throw StateError('unexpected action $action');
          };

    Future<void> load(WidgetTester tester) async {
      await tester.tap(find.byKey(const Key('modules-discord-load')));
      await tester.pumpAndSettle();
    }

    testWidgets('a freshly typed token is saved but never shown in the UI', (
      tester,
    ) async {
      const secret = 'MT-SECRET-UI-LEAK';
      final client = maskedClient();
      addTearDown(client.dispose);

      await tester.pumpWidget(editor(client));
      await load(tester);

      // The read hint is a boolean; the credential itself is never rendered.
      expect(find.textContaining('Bot token configured'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('modules-discord-token')),
        secret,
      );
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pumpAndSettle();

      expect(client.lastSettingsWritten, isNotNull);
      expect(client.lastSettingsWritten!['token'], secret);
      expect(client.lastSettingsWritten!.containsKey('hasToken'), isFalse);
      expect(client.lastSettingsWritten!['ownerUsername'], 'alice');
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains(secret)));
      }
      expect(find.text('Discord settings saved.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('modules-discord-token')))
            .obscureText,
        isTrue,
      );
    });

    testWidgets('a blank token on a read-backed edit is omitted', (
      tester,
    ) async {
      final client = maskedClient();
      addTearDown(client.dispose);

      await tester.pumpWidget(editor(client));
      await load(tester);
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pumpAndSettle();

      expect(client.lastSettingsWritten, isNotNull);
      expect(client.lastSettingsWritten!.containsKey('token'), isFalse);
      expect(client.lastSettingsWritten!.containsKey('hasToken'), isFalse);
      expect(client.lastSettingsWritten!['executionMode'], 'local');
      expect(find.text('Discord settings saved.'), findsOneWidget);
    });

    testWidgets('save errors are sanitized and never echo the token', (
      tester,
    ) async {
      const secret = 'MT-SECRET-IN-ERROR';
      final client = maskedClient()
        ..onSet = (section, settings) {
          throw const DaemonClientException(
            kind: DaemonFailureKind.rpc,
            message: 'settings.set discord token=$secret',
            code: 'rpc_bad_payload',
          );
        };
      addTearDown(client.dispose);

      await tester.pumpWidget(editor(client));
      await load(tester);
      await tester.enterText(
        find.byKey(const Key('modules-discord-token')),
        secret,
      );
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pumpAndSettle();

      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains(secret)));
      }
      expect(
        find.text('The daemon could not complete the request.'),
        findsOneWidget,
      );
    });
  });
}
