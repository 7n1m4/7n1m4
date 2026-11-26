// SPDX-License-Identifier: GPL-3.0-or-later

// Vendor-neutral UST subset ported from
// packages/stage-ui/src/stores/modules/speech.ts:147-434. Cases mirror
// packages/stage-ui/src/stores/modules/speech.test.ts.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/main.dart' show speakCompletedTurns;
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
  });
}
