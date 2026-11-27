// SPDX-License-Identifier: GPL-3.0-or-later

// P0 coverage for the Discord masked-view → PATCH boundary. The daemon returns
// a token-free view with a `hasToken` boolean; a thin client must be able to
// edit it without ever echoing a read-backed token, leaking it into the UI, or
// wiping the stored credential with a blank field.

import 'dart:async';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/modules/discord_settings_patch.dart';
import 'package:anima_control/features/modules/modules_screen.dart';

import 'support/fakes.dart';

GatewayEventFrame _settingsChanged(String section) => GatewayEventFrame(
  topic: EventTopic.settingsChanged,
  rawTopic: 'settings.changed',
  data: <String, dynamic>{'section': section},
);

Map<String, dynamic> _discordTestView({
  bool hasToken = true,
  String executionMode = 'local',
  String chatMode = 'followup',
}) => <String, dynamic>{
  'enabled': true,
  'hasToken': hasToken,
  'ownerUsername': 'alice',
  'ownerUserId': '12345',
  'executionMode': executionMode,
  'chatMode': chatMode,
  'voiceMode': 'puppet',
  'voiceCall': 'off',
};

void _serveDiscord(FakeChatClient client, Map<String, dynamic> view) {
  client.onCall = (action, payload) {
    if (action == 'settings.get') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'settings': view},
      );
    }
    throw StateError('unexpected action $action');
  };
}

/// Lets a test hold a PATCH open and assert the editor is locked meanwhile.
class _GateablePatchClient extends FakeChatClient {
  Completer<bool>? patchGate;
  int setCalls = 0;

  @override
  Future<bool> settingsSet(
    String section,
    Map<String, dynamic> settings,
  ) async {
    setCalls++;
    lastSettingsWritten = settings;
    final gate = patchGate;
    if (gate == null) return true;
    return gate.future;
  }
}

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

    testWidgets('settings.changed(discord) refreshes the form from the daemon', (
      tester,
    ) async {
      final view = _discordTestView();
      final client = _GateablePatchClient();
      addTearDown(client.dispose);
      _serveDiscord(client, view);

      await tester.pumpWidget(editor(client));
      await load(tester);

      expect(find.text('local'), findsOneWidget);
      expect(find.text('followup'), findsOneWidget);
      final loadsBefore = client.settingsLoads;

      // Another client changed the section. The event carries no values, so the
      // editor must re-read the authoritative masked view.
      view['executionMode'] = 'remote';
      view['chatMode'] = 'collect';
      view['hasToken'] = false;
      client.emitEvent(_settingsChanged('discord'));
      await tester.pumpAndSettle();

      expect(client.settingsLoads, loadsBefore + 1);
      expect(find.text('remote'), findsOneWidget);
      expect(find.text('collect'), findsOneWidget);
      expect(find.text('No bot token configured.'), findsOneWidget);

      // The refreshed, read-backed view still writes no token and no hint.
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pumpAndSettle();
      expect(client.lastSettingsWritten, isNotNull);
      expect(client.lastSettingsWritten!.containsKey('token'), isFalse);
      expect(client.lastSettingsWritten!.containsKey('hasToken'), isFalse);
      expect(client.lastSettingsWritten!['executionMode'], 'remote');
    });

    testWidgets('settings.changed for another section does not clobber edits', (
      tester,
    ) async {
      final view = _discordTestView();
      final client = _GateablePatchClient();
      addTearDown(client.dispose);
      _serveDiscord(client, view);

      await tester.pumpWidget(editor(client));
      await load(tester);

      // Unsaved local edits: a dropdown change and a freshly typed token.
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('modules-discord-chatMode')),
          )
          .onChanged!('steer');
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('modules-discord-token')),
        'MT-LOCAL-DRAFT',
      );
      await tester.pump();
      final loadsBefore = client.settingsLoads;

      view['chatMode'] = 'collect';
      view['hasToken'] = false;
      client.emitEvent(_settingsChanged('theme'));
      await tester.pumpAndSettle();

      expect(client.settingsLoads, loadsBefore);
      expect(find.text('steer'), findsOneWidget);
      expect(find.text('collect'), findsNothing);
      expect(find.textContaining('Bot token configured'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('modules-discord-token')))
            .controller!
            .text,
        'MT-LOCAL-DRAFT',
      );
    });

    testWidgets('controls are locked while a PATCH is in flight', (
      tester,
    ) async {
      final client = _GateablePatchClient()..patchGate = Completer<bool>();
      addTearDown(client.dispose);
      _serveDiscord(client, _discordTestView());

      await tester.pumpWidget(editor(client));
      await load(tester);

      const saveKey = Key('modules-discord-save');
      const tokenKey = Key('modules-discord-token');
      const modeKey = Key('modules-discord-executionMode');
      final saveButton = tester.widget<FilledButton>(find.byKey(saveKey));
      final previouslyEnabledCallback = saveButton.onPressed;
      expect(previouslyEnabledCallback, isNotNull);

      await tester.tap(find.byKey(saveKey));
      await tester.pump();

      expect(client.setCalls, 1);
      expect(
        tester.widget<FilledButton>(find.byKey(saveKey)).onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byKey(tokenKey)).enabled, isFalse);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(find.byKey(modeKey))
            .onChanged,
        isNull,
      );
      expect(find.text('Discord settings saved.'), findsNothing);

      // A dispatch routed to the previously-enabled callback must not start an
      // overlapping write while the first PATCH is still pending.
      previouslyEnabledCallback!();
      await tester.pump();
      expect(client.setCalls, 1);

      client.patchGate!.complete(true);
      await tester.pumpAndSettle();

      expect(client.setCalls, 1);
      expect(
        tester.widget<FilledButton>(find.byKey(saveKey)).onPressed,
        isNotNull,
      );
      expect(tester.widget<TextField>(find.byKey(tokenKey)).enabled, isTrue);
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(find.byKey(modeKey))
            .onChanged,
        isNotNull,
      );
      expect(find.text('Discord settings saved.'), findsOneWidget);
    });

    testWidgets('controls unlock after a failed PATCH', (tester) async {
      final client = _GateablePatchClient()..patchGate = Completer<bool>();
      addTearDown(client.dispose);
      _serveDiscord(client, _discordTestView());

      await tester.pumpWidget(editor(client));
      await load(tester);

      const saveKey = Key('modules-discord-save');
      const tokenKey = Key('modules-discord-token');
      await tester.tap(find.byKey(saveKey));
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byKey(saveKey)).onPressed,
        isNull,
      );
      expect(tester.widget<TextField>(find.byKey(tokenKey)).enabled, isFalse);

      client.patchGate!.completeError(
        const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: 'settings.set discord failed',
          code: 'rpc_bad_payload',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilledButton>(find.byKey(saveKey)).onPressed,
        isNotNull,
      );
      expect(tester.widget<TextField>(find.byKey(tokenKey)).enabled, isTrue);
      expect(
        find.text('The daemon could not complete the request.'),
        findsOneWidget,
      );
    });

    testWidgets('saving a fresh token into a tokenless view is immediate', (
      tester,
    ) async {
      const secret = 'MT-FRESH-CONFIGURED';
      final client = FakeChatClient();
      addTearDown(client.dispose);
      _serveDiscord(client, _discordTestView(hasToken: false));

      await tester.pumpWidget(editor(client));
      await load(tester);
      expect(find.text('No bot token configured.'), findsOneWidget);

      await tester.enterText(
        find.byKey(const Key('modules-discord-token')),
        secret,
      );
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pumpAndSettle();

      expect(client.lastSettingsWritten, isNotNull);
      expect(client.lastSettingsWritten!['token'], secret);
      expect(client.lastSettingsWritten!.containsKey('hasToken'), isFalse);
      expect(find.text('No bot token configured.'), findsNothing);
      expect(find.textContaining('Bot token configured'), findsOneWidget);
      for (final text in tester.widgetList<Text>(find.byType(Text))) {
        expect(text.data, isNot(contains(secret)));
        expect(text.data, isNot(contains('hasToken')));
      }
    });
  });
}
