// SPDX-License-Identifier: GPL-3.0-or-later

// Focused coverage of Companion Connectors settings: every card must edit a
// daemon-registered section, preserve unrelated keys, reject invalid numbers
// locally, and surface RPC failures as sanitized messages.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/modules/modules_screen.dart';

import 'support/fakes.dart';

void main() {
  setUp(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.implicitView!;
    view.physicalSize = const Size(1200, 12000);
    view.devicePixelRatio = 1;
  });

  tearDown(() {
    final view = TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher.implicitView!;
    view.resetPhysicalSize();
    view.resetDevicePixelRatio();
  });

  Widget screen(FakeChatClient client) => MaterialApp(
        home: Scaffold(body: ModulesScreen(client: client)),
      );

  Widget screenWith(Map<String, Map<String, dynamic>> sections, FakeChatClient client) {
    client.onCall = (action, payload) {
      if (action != 'settings.get') throw StateError('unexpected action $action');
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
    };
    return screen(client);
  }

  Map<String, Map<String, dynamic>> moduleSections() => <String, Map<String, dynamic>>{
        'audio-device': <String, dynamic>{
          'selectedInputDevice': 'mic-1',
          'selectedOutputDevice': 'spk-1',
          'inputEnabled': true,
        },
        'local-llm': <String, dynamic>{
          'modelPath': '/models/test.gguf',
          'contextSize': 2048,
          'temperature': 0.8,
          'maxTokens': 512,
          'gpuLayers': 12,
        },
        'consciousness': <String, dynamic>{
          'activeProvider': 'anthropic',
          'activeModel': 'claude-x',
          'activeCustomModel': 'custom-llm',
          'futureKey': 'keep-consciousness',
        },
        'speech': <String, dynamic>{
          'activeProvider': 'piper',
          'activeModel': '',
          'voice': 'aria',
          'outputVolume': 0.6,
          'enabled': true,
          'pitch': 1.0,
          'rate': 1.2,
          'ssmlEnabled': false,
          'language': 'ja-JP',
          'voiceProfiles': <dynamic>[],
          'futureKey': 'keep-speech',
        },
        'hearing': <String, dynamic>{
          'activeProvider': 'whisper-local',
          'activeModel': 'base',
          'activeCustomModel': '',
          'autoSendEnabled': true,
          'autoSendDelay': 2000,
          'detectionMode': 'vad',
          'tapToTalk': true,
          'voiceInputMode': 'dictation',
          'vadThreshold': 0.6,
          'speechProviderSettings': <String, dynamic>{},
          'transcriptionProviderSettings': <String, dynamic>{},
        },
        'vision': <String, dynamic>{
          'strategy': 'direct',
          'activeProvider': 'openai-compatible',
          'activeModel': 'vlm',
          'contextWindow': 1,
          'activeAdvanced': <String, dynamic>{},
          'promptShim': 'direct prompt',
          'promptShimForward': 'forward prompt',
          'witnessEnabled': false,
          'witnessPrompt': 'observe',
          'respectSchedule': true,
        },
      };

  Future<void> saveSection(
    WidgetTester tester,
    String label,
  ) async {
    final button = find.widgetWithText(FilledButton, 'Save $label');
    await tester.ensureVisible(button);
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  testWidgets('loads every registered section and keeps the narrow notice', (tester) async {
    final client = FakeChatClient()
      ..onCall = (action, payload) {
        final section = payload?['section'];
        if (action == 'settings.get') {
          return RpcReply(action: action, ok: true, data: <String, dynamic>{
            'settings': <String, dynamic>{
              'selectedInputDevice': 'mic-1',
              'selectedOutputDevice': 'spk-1',
              'inputEnabled': true,
              'unknownKey': 'preserve-me',
            },
          });
        }
        throw StateError('unexpected action $action / $section');
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();

    expect(find.text('Companion Connectors'), findsOneWidget);
    for (final label in <String>[
      'Audio device', 'Local LLM', 'Consciousness', 'Speech', 'Hearing', 'Vision',
    ]) {
      expect(find.widgetWithText(FilledButton, 'Save $label'), findsOneWidget);
    }
    expect(find.textContaining('Integration modules (Discord, MCP and ACP)'),
        findsOneWidget);
    expect(find.textContaining('have no daemon settings section'), findsOneWidget);
    expect(client.settingsLoads, 6);
  });

  testWidgets('saves a whole typed section and preserves unrelated keys', (tester) async {
    final client = FakeChatClient()
      ..onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(action: action, ok: true, data: <String, dynamic>{
            'settings': <String, dynamic>{
              'selectedInputDevice': 'mic-1',
              'inputEnabled': true,
              'futureKey': 'keep-me',
            },
          });
        }
        throw StateError('unexpected action $action');
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('modules-audio-device-selectedInputDevice')), 'mic-2');
    await saveSection(tester, 'Audio device');

    expect(client.lastSettingsWritten, isNotNull);
    expect(client.lastSettingsWritten!['selectedInputDevice'], 'mic-2');
    expect(client.lastSettingsWritten!['futureKey'], 'keep-me',
        reason: 'untouched daemon keys round-trip');
    expect(find.text('Audio device settings saved.'), findsOneWidget);
  });

  testWidgets('invalid local LLM numbers do not reach the daemon', (tester) async {
    final client = FakeChatClient()
      ..onCall = (action, payload) {
        if (action == 'settings.get') {
          return RpcReply(action: action, ok: true, data: <String, dynamic>{
            'settings': <String, dynamic>{},
          });
        }
        throw StateError('unexpected action $action');
      };
    addTearDown(client.dispose);

    await tester.pumpWidget(screen(client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('modules-local-llm-contextSize')), 'not-a-number');
    await saveSection(tester, 'Local LLM');

    expect(client.lastSettingsWritten, isNull);
    expect(find.text('Context size, max tokens, GPU layers and temperature must be numbers.'),
        findsOneWidget);
  });

  testWidgets('loads and saves all four daemon-backed module sections', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    final sections = moduleSections();
    String? savedSection;
    Map<String, dynamic>? savedSettings;
    client.onSet = (section, settings) {
      savedSection = section;
      savedSettings = settings;
    };

    await tester.pumpWidget(screenWith(sections, client));
    await tester.pumpAndSettle();

    expect(client.settingsLoads, 6);

    await tester.enterText(
      find.byKey(const Key('modules-consciousness-activeProvider')),
      'openai',
    );
    await saveSection(tester, 'Consciousness');
    expect(savedSection, 'consciousness');
    expect(savedSettings!['activeProvider'], 'openai');
    expect(savedSettings!['futureKey'], 'keep-consciousness',
        reason: 'unrelated daemon keys survive the save');

    await tester.enterText(find.byKey(const Key('modules-speech-voice')), 'nova');
    await saveSection(tester, 'Speech');
    expect(savedSection, 'speech');
    expect(savedSettings!['voice'], 'nova');
    expect(savedSettings!['language'], 'ja-JP');
    expect(savedSettings!['futureKey'], 'keep-speech');

    await tester.enterText(
      find.byKey(const Key('modules-hearing-autoSendDelay')),
      '1500',
    );
    await saveSection(tester, 'Hearing');
    expect(savedSection, 'hearing');
    expect(savedSettings!['autoSendDelay'], 1500);
    expect(savedSettings!['detectionMode'], 'vad');

    await tester.enterText(
      find.byKey(const Key('modules-vision-contextWindow')),
      '4',
    );
    await saveSection(tester, 'Vision');
    expect(savedSection, 'vision');
    expect(savedSettings!['contextWindow'], 4);
    expect(savedSettings!['witnessEnabled'], false);
  });

  testWidgets('invalid module numbers never reach the daemon', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    await tester.pumpWidget(screenWith(moduleSections(), client));
    await tester.pumpAndSettle();

    await tester.enterText(find.byKey(const Key('modules-speech-rate')), 'fast');
    await saveSection(tester, 'Speech');
    expect(client.lastSettingsWritten, isNull);
    expect(find.text('Speech rate must be a number.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('modules-hearing-autoSendDelay')),
      'soon',
    );
    await saveSection(tester, 'Hearing');
    expect(client.lastSettingsWritten, isNull);
    expect(find.text('Auto-send delay and VAD threshold must be numbers.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const Key('modules-vision-contextWindow')),
      'many',
    );
    await saveSection(tester, 'Vision');
    expect(client.lastSettingsWritten, isNull);
    expect(find.text('Context window must be a whole number.'), findsOneWidget);
  });

  testWidgets('module load and save failures show sanitized messages', (tester) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    // FakeChatClient.settingsSet delegates to call(): both an RPC exception
    // and an unsuccessful reply must produce a fixed, secret-free message.
    await tester.pumpWidget(screenWith(moduleSections(), client));
    await tester.pumpAndSettle();
    client.onSet = (section, settings) {
      throw DaemonClientException(
        kind: DaemonFailureKind.rpc,
        message: 'save /tmp/config.json apiKey=leak',
        code: 'rpc_bad_payload',
      );
    };
    await tester.enterText(
      find.byKey(const Key('modules-vision-contextWindow')),
      '7',
    );
    await saveSection(tester, 'Vision');
    expect(find.text('The daemon could not complete the request.'), findsOneWidget);
    expect(find.textContaining('apiKey=leak'), findsNothing);
    expect(find.textContaining('/tmp/config.json'), findsNothing);
  });
}
