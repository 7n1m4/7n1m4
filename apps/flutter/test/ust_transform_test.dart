// SPDX-License-Identifier: GPL-3.0-or-later

// Vendor-neutral UST subset ported from
// packages/stage-ui/src/stores/modules/speech.ts:147-434. Cases mirror
// packages/stage-ui/src/stores/modules/speech.test.ts.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart'
    show DaemonConnectionState;
import 'package:anima_control/features/chat/chat_screen.dart';
import 'package:anima_control/main.dart'
    show loadUstOptionsOnce, speakCompletedTurns;
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';

import 'support/fakes.dart';

class _IdleEngine implements TtsEngine {
  @override
  String get id => 'test-idle';

  @override
  int get sampleRate => 0;

  @override
  Future<Float32List> synthesize(String text) async => Float32List(0);

  @override
  Future<PcmSource> synthesizeToSource(String text) async =>
      MemoryPcmSource(sampleRate: 1, channels: 1, samples: <double>[0]);

  @override
  void dispose() {}
}

void main() {
  group('applyUstTransform', () {
    test('null or disabled options are an exact passthrough', () {
      const input = r'*smiles* $19.99 😊';
      expect(applyUstTransform(input), input);
      expect(applyUstTransform(input, const UstOptions(enabled: false)), input);
    });

    test('literal legacy placeholder text is never rewritten', () {
      const options = UstOptions(
        asterisks: UstBracketAction.mute,
        stripEmojis: false,
        tildeReplacement: null,
      );
      final spoken = applyUstTransform(
        'literal __UST_TOKEN_0__ / __UST_MATH_0__ stays and *muted* goes',
        options,
      );
      expect(spoken, contains('__UST_TOKEN_0__'));
      expect(spoken, contains('__UST_MATH_0__'));
      expect(spoken, isNot(contains('muted')));
    });

    test('per-bracket mute / flatten / passThrough / token actions', () {
      const options = UstOptions(
        asterisks: UstBracketAction.mute,
        squareBrackets: UstBracketAction.flatten,
        parentheses: UstBracketAction.passThrough,
        angleBrackets: UstBracketAction.token,
        stripHtml: false,
        stripEmojis: false,
        tildeReplacement: null,
      );
      expect(
        applyUstTransform('*giggles* [happy] (whispers) <aside>', options),
        'happy (whispers) <|aside|>',
      );
      expect(
        applyUstTransform('*smiles*', const UstOptions(
          asterisks: UstBracketAction.flatten,
        )),
        'smiles',
      );
      expect(
        applyUstTransform('*smiles*', const UstOptions(
          asterisks: UstBracketAction.passThrough,
        )),
        '*smiles*',
      );
    });

    test('ACTOR and ACT placeholders survive bracket muting verbatim', () {
      const input = '<|ACTOR:pet|>Hello *warmly*<|ACT:smile|>';
      expect(applyUstTransform(input, const UstOptions()),
          '<|ACTOR:pet|>Hello <|ACT:smile|>');

      const angleToken = UstOptions(
        angleBrackets: UstBracketAction.token,
        stripHtml: false,
      );
      expect(
        applyUstTransform('<|ACTOR:pet|>Hi <aside>', angleToken),
        '<|ACTOR:pet|>Hi <|aside|>',
      );
    });

    test('arithmetic operators survive asterisk muting', () {
      const options = UstOptions(
        asterisks: UstBracketAction.mute,
        stripEmojis: false,
        tildeReplacement: null,
      );
      expect(applyUstTransform('*smiles* 2 * 3 = 6', options), '2 * 3 = 6');
      expect(applyUstTransform('*x* 2**10 and x**2', options),
          '2**10 and x**2');
    });

    test('code blocks are muted by default and can pass through', () {
      const input = 'Start\n```bash\npnpm dev\n```\nDone';
      expect(applyUstTransform(input, const UstOptions()), 'Start\n\nDone');
      expect(
        applyUstTransform(
          input,
          const UstOptions(codeBlocks: UstCodeBlockAction.passThrough),
        ),
        input,
      );
    });

    test('markdown image, HTML, links and block markers are cleaned', () {
      const input = '![alt](img.png) [label](https://x) <div>hi</div>\n'
          '# Head\n- item';
      expect(applyUstTransform(input, const UstOptions()),
          'label hi\nHead\nitem');
    });

    test('emoji, ZWJ and repeated whitespace are removed', () {
      const options = UstOptions(tildeReplacement: null);
      expect(applyUstTransform('Hello 😊   world  ', options), 'Hello world');
      expect(applyUstTransform('👩\u200D💻 gone', options), 'gone');
      expect(applyUstTransform('a\n\n\n\nb', options), 'a\n\nb');
    });

    test('tilde is replaced, removed, or left alone', () {
      expect(
        applyUstTransform('a~b', const UstOptions(tildeReplacement: 'nyan')),
        'a nyan b',
      );
      expect(
        applyUstTransform('a~b', const UstOptions(tildeReplacement: '')),
        'ab',
      );
      expect(
        applyUstTransform('a~b', const UstOptions(tildeReplacement: null)),
        'a~b',
      );
    });
  });

  group('UstOptions.fromSpeechSettings', () {
    test('missing section or empty profile list is an exact passthrough', () {
      const raw = '*smiles* a~b 😊';
      for (final settings in <Map<String, dynamic>>[
        <String, dynamic>{},
        <String, dynamic>{'voiceProfiles': <dynamic>[]},
      ]) {
        final options = UstOptions.fromSpeechSettings(settings);
        expect(options.enabled, isFalse);
        expect(applyUstTransform(raw, options), raw);
      }
    });

    test('unmatched profile, non-map ust and missing enabled are passthrough',
        () {
      const raw = '*smiles* a~b 😊';
      Map<String, dynamic> settings(Object? ust, {String voice = 'pet-voice'}) =>
          <String, dynamic>{
            'activeProvider': 'piper',
            'voice': voice,
            'voiceProfiles': <dynamic>[
              <String, dynamic>{
                'baseVoice': 'pet-voice',
                'baseProvider': 'piper',
                'ust': ust,
              },
            ],
          };
      for (final value in <Map<String, dynamic>>[
        settings(<String, dynamic>{}, voice: 'unknown'),
        settings('not a map'),
        settings(<String, dynamic>{'asterisks': 'mute'}),
        settings(<String, dynamic>{'enabled': 'true'}),
      ]) {
        final options = UstOptions.fromSpeechSettings(value);
        expect(options.enabled, isFalse);
        expect(applyUstTransform(raw, options), raw);
      }
    });

    test('virtual id/name match wins over the baseVoice/baseProvider fallback',
        () {
      final options = UstOptions.fromSpeechSettings(<String, dynamic>{
        'activeProvider': 'virtual-audio-studio',
        'voice': 'Pet',
        'voiceProfiles': <dynamic>[
          <String, dynamic>{
            'id': 'pet-voice',
            'baseVoice': 'pet-voice',
            'baseProvider': 'piper',
            'ust': <String, dynamic>{
              'enabled': true,
              'asterisks': 'mute',
              'tildeReplacement': 'nyan',
            },
          },
          <String, dynamic>{
            'id': 'other',
            'name': 'Pet',
            'ust': <String, dynamic>{
              'enabled': true,
              'asterisks': 'flatten',
            },
          },
        ],
      });
      expect(options.asterisks, UstBracketAction.flatten);
      expect(options.tildeReplacement, isNull); // absent means leave `~` alone
    });

    test('non-virtual profiles resolve by base voice and provider', () {
      final options = UstOptions.fromSpeechSettings(<String, dynamic>{
        'activeProvider': 'piper',
        'voice': 'pet-voice',
        'voiceProfiles': <dynamic>[
          <String, dynamic>{
            'id': 'pet-voice',
            'baseVoice': 'pet-voice',
            'baseProvider': 'piper',
            'ust': <String, dynamic>{
              'enabled': true,
              'parentheses': 'token',
              'preserveMarkdownLinks': 'mute',
              'codeBlocks': 'passThrough',
              'mode': 'flatten',
            },
          },
        ],
      });
      expect(options.parentheses, UstBracketAction.token);
      expect(options.preserveMarkdownLinks, UstLinkMode.mute);
      expect(options.codeBlocks, UstCodeBlockAction.passThrough);
      expect(options.legacyMode, UstLegacyMode.flatten);
      expect(options.stripEmojis, const UstOptions().stripEmojis);
    });

    test('explicitly disabled UST and bypass providers are passthrough', () {
      final disabled = UstOptions.fromSpeechSettings(<String, dynamic>{
        'activeProvider': 'virtual-audio-studio',
        'voice': 'pet',
        'voiceProfiles': <dynamic>[
          <String, dynamic>{
            'id': 'pet',
            'ust': <String, dynamic>{
              'enabled': false,
              'asterisks': 'mute',
            },
          },
        ],
      });
      expect(disabled.enabled, isFalse);

      final bypass = UstOptions.fromSpeechSettings(<String, dynamic>{
        'activeProvider': 'chatterbox',
        'voice': 'pet',
        'voiceProfiles': <dynamic>[
          <String, dynamic>{
            'id': 'pet',
            'ust': <String, dynamic>{'asterisks': 'mute'},
          },
        ],
      });
      expect(bypass.enabled, isFalse);
    });
  });

  group('token.delta -> queue bridge', () {
    test('final text is transformed before the intent is opened', () async {
      final client = FakeChatClient();
      final controller = LipSyncController(actorId: 'pet', engine: _IdleEngine());
      final spoken = <String>[];
      final queue = SpeechIntentQueue(
        sink: (text, {abort}) async {
          spoken.add(text);
        },
      );
      addTearDown(controller.dispose);

      speakCompletedTurns(client, controller, queue: queue);
      client.emitEvent(tokenDelta(delta: 'hello 😊 '));
      client.emitEvent(
        tokenDelta(delta: 'world', isFinal: true, reason: 'complete'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(spoken, <String>['hello world']);
    });

    test('non-complete terminal reasons still never reach the queue', () async {
      final client = FakeChatClient();
      final controller = LipSyncController(actorId: 'pet', engine: _IdleEngine());
      final spoken = <String>[];
      final queue = SpeechIntentQueue(
        sink: (text, {abort}) async {
          spoken.add(text);
        },
      );
      addTearDown(controller.dispose);

      speakCompletedTurns(client, controller, queue: queue);
      client.emitEvent(tokenDelta(delta: 'hello 😊'));
      client.emitEvent(
        tokenDelta(delta: '', isFinal: true, reason: 'cancelled'),
      );
      await Future<void>.delayed(Duration.zero);

      expect(spoken, isEmpty);
    });

    testWidgets(
        'loader waits for connection, applies late UST reply to speech only',
        (tester) async {
      final settingsReply = Completer<Map<String, dynamic>>();
      final client = FakeChatClient()..deferredSettings = settingsReply;
      addTearDown(client.dispose);
      final controller =
          LipSyncController(actorId: 'pet', engine: _IdleEngine());
      addTearDown(controller.dispose);
      final spoken = <String>[];
      final queue = SpeechIntentQueue(
        sink: (text, {abort}) async {
          spoken.add(text);
        },
      );
      var options = const UstOptions();
      // Subscribe before loading: starter defaults cover early turns, and the
      // holder is re-read on every later turn once the reply arrives.
      speakCompletedTurns(
        client,
        controller,
        queue: queue,
        optionsForTurn: () => options,
      );
      unawaited(loadUstOptionsOnce(client, (loaded) => options = loaded));
      expect(client.settingsLoads, 0);

      await tester.pumpWidget(
        MaterialApp(home: Scaffold(body: ChatScreen(client: client))),
      );
      await tester.pump();

      client.emitStatus(DaemonConnectionState.connected);
      await tester.pump();

      settingsReply.complete(<String, dynamic>{
        'activeProvider': 'virtual-audio-studio',
        'voice': 'pet-voice',
        'voiceProfiles': <dynamic>[
          <String, dynamic>{
            'id': 'pet-voice',
            'name': 'Pet',
            'baseVoice': 'pet-voice',
            'baseProvider': 'piper',
            'ust': <String, dynamic>{
              'enabled': true,
              'asterisks': 'mute',
              'tildeReplacement': 'nyan',
              'stripEmojis': false,
            },
          },
        ],
      });
      await tester.pump();

      const raw = '*smiles* a~b 😊';
      client.emitEvent(tokenDelta(delta: raw));
      await tester.pump();
      client.emitEvent(
        tokenDelta(delta: '', isFinal: true, reason: 'complete'),
      );
      await tester.pumpAndSettle();

      expect(spoken, <String>['a nyan b 😊']);
      expect(
        tester.widget<MarkdownBody>(find.byType(MarkdownBody)).data,
        raw,
      );
      expect(client.lastSettingsWritten, isNull);
    });

    testWidgets(
        'loader gives up instead of hanging on a daemon that never connects',
        (tester) async {
      final client = FakeChatClient();
      addTearDown(client.dispose);
      var applied = false;
      unawaited(loadUstOptionsOnce(client, (_) => applied = true));

      await tester.pump(const Duration(seconds: 11));

      expect(applied, isFalse);
      expect(client.settingsLoads, 0);
      expect(client.lastSettingsWritten, isNull);
    });
  });
}
