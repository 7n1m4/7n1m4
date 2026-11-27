// SPDX-License-Identifier: GPL-3.0-or-later

// Code-grounded regression coverage for two audit findings in Companion
// Connectors:
//   F9  - a `settings.changed(discord)` event arriving while a PATCH is in
//         flight must not reload over the in-flight save's choices/status.
//   F16 - a stored choice value outside the dropdown's options must be
//         normalized at hydration, so the displayed fallback is the value
//         that is actually saved.

import 'dart:async';

// ignore: deprecated_member_use — material_ui replacement is not a project dependency.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/modules/modules_screen.dart';

import 'support/fakes.dart';

GatewayEventFrame _discordChanged() => const GatewayEventFrame(
  topic: EventTopic.settingsChanged,
  rawTopic: 'settings.changed',
  data: <String, dynamic>{'section': 'discord'},
);

Map<String, dynamic> _discordView() => <String, dynamic>{
  'enabled': true,
  'hasToken': true,
  'ownerUsername': 'alice',
  'executionMode': 'local',
  'chatMode': 'followup',
  'voiceMode': 'puppet',
  'voiceCall': 'off',
};

/// Holds PATCH open so an event can land mid-save.
class _GateableSaveClient extends FakeChatClient {
  Completer<bool>? gate;

  @override
  Future<bool> settingsSet(
    String section,
    Map<String, dynamic> settings,
  ) async {
    lastSettingsWritten = settings;
    final completer = gate;
    if (completer == null) return true;
    return completer.future;
  }
}

/// Lets a test complete reads out of order to prove stale loads are ignored.
class _DeferredGetClient extends FakeChatClient {
  final List<Completer<Map<String, dynamic>>> gets =
      <Completer<Map<String, dynamic>>>[];

  @override
  Future<Map<String, dynamic>> settingsGet(String section) {
    final completer = Completer<Map<String, dynamic>>();
    gets.add(completer);
    return completer.future;
  }
}

void main() {
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

  void serveDiscord(FakeChatClient client, Map<String, dynamic> view) {
    client.onCall = (action, payload) {
      if (action == 'settings.get') {
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{'settings': Map<String, dynamic>.from(view)},
        );
      }
      throw StateError('unexpected action $action');
    };
  }

  Future<void> loadDiscord(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('modules-discord-load')));
    await tester.pumpAndSettle();
  }

  Widget screenWith(
    Map<String, Map<String, dynamic>> sections,
    FakeChatClient client,
  ) {
    client.onCall = (action, payload) {
      if (action == 'settings.get') {
        final section = payload?['section'] as String;
        return RpcReply(
          action: action,
          ok: true,
          data: <String, dynamic>{
            'settings': Map<String, dynamic>.from(
              sections[section] ?? const <String, dynamic>{},
            ),
          },
        );
      }
      throw StateError('unexpected action $action');
    };
    return MaterialApp(
      home: Scaffold(body: ModulesScreen(client: client)),
    );
  }

  Map<String, dynamic> hearing({Object? detectionMode, bool include = true}) {
    final values = <String, dynamic>{
      'activeProvider': 'whisper-local',
      'activeModel': 'base',
      'autoSendEnabled': true,
      'autoSendDelay': 2000,
      'tapToTalk': true,
      'voiceInputMode': 'dictation',
      'vadThreshold': 0.6,
      'speechProviderSettings': <String, dynamic>{},
      'transcriptionProviderSettings': <String, dynamic>{},
    };
    if (include) values['detectionMode'] = detectionMode;
    return values;
  }

  Future<void> saveHearing(WidgetTester tester) async {
    final button = find.widgetWithText(FilledButton, 'Save Hearing');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  group('F9 - settings.changed during an in-flight Discord save', () {
    testWidgets('queues the event instead of clobbering choices or status', (
      tester,
    ) async {
      final view = _discordView();
      final client = _GateableSaveClient()..gate = Completer<bool>();
      addTearDown(client.dispose);
      serveDiscord(client, view);

      await tester.pumpWidget(editor(client));
      await loadDiscord(tester);

      // An unsaved local edit that must survive the echo event.
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('modules-discord-chatMode')),
          )
          .onChanged!('steer');
      await tester.pumpAndSettle();
      expect(find.text('steer'), findsOneWidget);

      final loadsBefore = client.settingsLoads;
      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pump();
      expect(client.lastSettingsWritten!['chatMode'], 'steer');

      // Another client changes the section and the daemon echoes the event
      // while the PATCH is still pending.
      view
        ..['executionMode'] = 'remote'
        ..['chatMode'] = 'collect'
        ..['hasToken'] = false;
      client.emitEvent(_discordChanged());
      await tester.pumpAndSettle();

      expect(client.settingsLoads, loadsBefore, reason: 'reload is queued');
      expect(find.text('steer'), findsOneWidget);
      expect(find.text('collect'), findsNothing);

      client.gate!.complete(true);
      await tester.pumpAndSettle();

      expect(find.text('Discord settings saved.'), findsOneWidget);
      expect(find.text('steer'), findsOneWidget);
      expect(
        client.settingsLoads,
        loadsBefore,
        reason: 'no redundant echo reload',
      );
      expect(client.lastSettingsWritten!['chatMode'], 'steer');
      // Token masking survives the merge.
      expect(client.lastSettingsWritten!.containsKey('token'), isFalse);
      expect(find.textContaining('Bot token configured'), findsOneWidget);
    });

    testWidgets('a queued event triggers a reload when the PATCH fails', (
      tester,
    ) async {
      final view = _discordView();
      final client = _GateableSaveClient()..gate = Completer<bool>();
      addTearDown(client.dispose);
      serveDiscord(client, view);

      await tester.pumpWidget(editor(client));
      await loadDiscord(tester);
      final loadsBefore = client.settingsLoads;

      await tester.tap(find.byKey(const Key('modules-discord-save')));
      await tester.pump();

      view
        ..['chatMode'] = 'collect'
        ..['hasToken'] = false;
      client.emitEvent(_discordChanged());
      await tester.pumpAndSettle();
      expect(client.settingsLoads, loadsBefore, reason: 'still queued');

      client.gate!.completeError(
        const DaemonClientException(
          kind: DaemonFailureKind.rpc,
          message: 'settings.set discord failed',
          code: 'rpc_bad_payload',
        ),
      );
      await tester.pumpAndSettle();

      expect(client.settingsLoads, loadsBefore + 1);
      expect(find.text('collect'), findsOneWidget);
      expect(find.text('No bot token configured.'), findsOneWidget);
    });

    testWidgets('a stale in-flight load cannot overwrite a newer view', (
      tester,
    ) async {
      final client = _DeferredGetClient();
      addTearDown(client.dispose);

      await tester.pumpWidget(editor(client));
      await tester.tap(find.byKey(const Key('modules-discord-load')));
      await tester.pump();
      expect(client.gets, hasLength(1));

      client.gets[0].complete(_discordView());
      await tester.pumpAndSettle();
      expect(find.text('followup'), findsOneWidget);

      // Two reads start; the newer one resolves first.
      client.emitEvent(_discordChanged());
      client.emitEvent(_discordChanged());
      await tester.pump();
      expect(client.gets, hasLength(3));

      final newest = _discordView()
        ..['chatMode'] = 'steer'
        ..['voiceCall'] = 'gemini';
      client.gets[2].complete(newest);
      await tester.pumpAndSettle();
      expect(find.text('steer'), findsOneWidget);
      expect(find.text('gemini'), findsOneWidget);

      final stale = _discordView()
        ..['chatMode'] = 'collect'
        ..['voiceCall'] = 'classic';
      client.gets[1].complete(stale);
      await tester.pumpAndSettle();

      expect(find.text('steer'), findsOneWidget);
      expect(find.text('gemini'), findsOneWidget);
      expect(find.text('collect'), findsNothing);
      expect(find.text('classic'), findsNothing);
    });
  });

  group('F16 - choice dropdown fallback desync', () {
    testWidgets('an unknown stored choice saves the displayed fallback', (
      tester,
    ) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      Map<String, dynamic>? saved;
      client.onSet = (section, settings) => saved = settings;

      await tester.pumpWidget(
        screenWith(<String, Map<String, dynamic>>{
          'hearing': hearing(detectionMode: 'legacy'),
        }, client),
      );
      await tester.pumpAndSettle();

      expect(
        find.descendant(
          of: find.byKey(const Key('modules-hearing-detectionMode')),
          matching: find.text('vad'),
        ),
        findsOneWidget,
      );

      await saveHearing(tester);
      expect(saved!['detectionMode'], 'vad');
    });

    testWidgets(
      'case and whitespace variants normalize to the canonical option',
      (tester) async {
        final client = FakeChatClient();
        addTearDown(client.dispose);
        Map<String, dynamic>? saved;
        client.onSet = (section, settings) => saved = settings;

        await tester.pumpWidget(
          screenWith(<String, Map<String, dynamic>>{
            'hearing': hearing(detectionMode: '  MANUAL '),
          }, client),
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const Key('modules-hearing-detectionMode')),
            matching: find.text('manual'),
          ),
          findsOneWidget,
        );

        await saveHearing(tester);
        expect(saved!['detectionMode'], 'manual');
      },
    );

    testWidgets(
      'a missing choice key saves the default shown by the dropdown',
      (tester) async {
        final client = FakeChatClient();
        addTearDown(client.dispose);
        Map<String, dynamic>? saved;
        client.onSet = (section, settings) => saved = settings;

        await tester.pumpWidget(
          screenWith(<String, Map<String, dynamic>>{
            'hearing': hearing(include: false),
          }, client),
        );
        await tester.pumpAndSettle();

        expect(
          find.descendant(
            of: find.byKey(const Key('modules-hearing-detectionMode')),
            matching: find.text('vad'),
          ),
          findsOneWidget,
        );

        await saveHearing(tester);
        expect(saved!['detectionMode'], 'vad');
      },
    );

    testWidgets('a valid stored choice is preserved unchanged', (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      Map<String, dynamic>? saved;
      client.onSet = (section, settings) => saved = settings;

      await tester.pumpWidget(
        screenWith(<String, Map<String, dynamic>>{
          'hearing': hearing(detectionMode: 'manual'),
        }, client),
      );
      await tester.pumpAndSettle();

      await saveHearing(tester);
      expect(saved!['detectionMode'], 'manual');
      expect(saved!['voiceInputMode'], 'dictation');
    });
  });
}
