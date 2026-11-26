// SPDX-License-Identifier: GPL-3.0-or-later

// Parity tests for the frozen quick-start rules. References:
//   Rust: crates/anima-core/src/onboarding_rules.rs:44-190
//   Vue:  packages/stage-ui/src/components/scenarios/dialogs/onboarding/v3/quick-start.vue
//
// These exercise pure rules only: no routing, no daemon verb, no completion
// flag and no card commit.

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/features/onboarding/onboarding_rules.dart';

/// Mirrors Vue's `activeCompanion` computed (fallback to `starterCompanions[0]`).
StarterCompanion activeCompanion(String id) =>
    starterCompanion(id) ?? starterCompanions.first;

void main() {
  group('starter catalog', () {
    test('matches the Vue declaration exactly and in order', () {
      // id, name, title, tag, personality, personaCardId, vesselModelId,
      // kokoroVoice, pocketTtsVoice, mossNanoVoice.
      const rows = <List<String>>[
        <String>[
          'default',
          'ReLU',
          'ReLU',
          '🌸 Empathetic Companion',
          'Warm, playful kitten-girl soul mate',
          'default',
          'preset-live2d-2',
          'af_bella',
          'airi_relu',
          'airi_relu',
        ],
        <String>[
          'aria',
          'Dr. Aria',
          'Dr. Aria',
          '🔬 Analytical Scientist',
          'Rigorous science, sharp dry wit',
          'aria',
          'preset-vrm-1',
          'af_sarah',
          'airi_aria',
          'airi_aria',
        ],
        <String>[
          'lupin',
          'Lupin',
          'Lupin',
          '🛡️ Fierce Guardian',
          'Vigilant guardian, stoic & loyal',
          'lupin',
          'preset-vrm-2',
          'af_nicole',
          'airi_lupin',
          'airi_lupin',
        ],
      ];

      expect(starterCompanions.length, rows.length);
      for (var i = 0; i < rows.length; i++) {
        final companion = starterCompanions[i];
        expect(
          <String>[
            companion.id,
            companion.name,
            companion.title,
            companion.tag,
            companion.personality,
            companion.personaCardId,
            companion.vesselModelId,
            companion.kokoroVoice,
            companion.pocketTtsVoice,
            companion.mossNanoVoice,
          ],
          rows[i],
          reason: 'catalog entry $i',
        );
        expect(starterCompanion(companion.id), companion);
      }
      expect(starterCompanion('unknown'), isNull);
    });

    test('active companion applies the Vue first-entry fallback', () {
      expect(activeCompanion('default').name, 'ReLU');
      expect(activeCompanion('aria').name, 'Dr. Aria');
      expect(activeCompanion('lupin').name, 'Lupin');
      expect(activeCompanion('unknown').name, 'ReLU');
    });
  });

  group('speech engine aliases', () {
    test('normalize in Vue order and preserve unknown ids verbatim', () {
      const cases = <(String, String)>[
        ('kokoro-local', 'kokoro-local'),
        ('KOKORO Q4', 'kokoro-local'),
        ('pocket-tts-local', 'pocket-tts-local'),
        ('Pocket-French', 'pocket-tts-local'),
        ('moss-nano-local', 'moss-nano-local'),
        ('My-Moss-Engine', 'moss-nano-local'),
        ('moss-pocket', 'pocket-tts-local'),
        ('kokoro-moss', 'kokoro-local'),
        ('OpenAI', 'OpenAI'),
        ('', ''),
      ];
      for (final (engine, expected) in cases) {
        expect(normalizeSpeechProviderId(engine), expected, reason: engine);
      }
    });
  });

  group('provider -> companion voice', () {
    test('matches Vue for every companion and engine slot', () {
      // Slot 0 = Kokoro, 1 = Pocket, 2 = Moss; aliases and cloud engines
      // follow the same mapping as their canonical ids.
      const engines = <(String, int)>[
        ('kokoro-local', 0),
        ('pocket-tts-local', 1),
        ('moss-nano-local', 2),
        ('KOKORO Q8', 0),
        ('Pocket English', 1),
        ('moss-tts', 2),
        ('elevenlabs', 0),
      ];
      for (final companion in starterCompanions) {
        final voices = <String>[
          companion.kokoroVoice,
          companion.pocketTtsVoice,
          companion.mossNanoVoice,
        ];
        for (final (engine, slot) in engines) {
          expect(
            companionVoice(companion, engine),
            voices[slot],
            reason: '${companion.id} on $engine',
          );
        }
      }
    });

    test('Moss falls back to Pocket when the companion has no Moss voice', () {
      const noMoss = StarterCompanion(
        id: 'no-moss',
        name: 'No Moss',
        title: 'No Moss',
        tag: 'test',
        personality: 'test',
        personaCardId: 'test',
        vesselModelId: 'test',
        kokoroVoice: 'k',
        pocketTtsVoice: 'p',
        mossNanoVoice: '',
      );
      expect(companionVoice(noMoss, 'moss-nano-local'), 'p');
    });

    // In Vue the LLM provider, selectedCompanionId and ttsEngine are chosen
    // independently; the provider assertions below are separate rule checks,
    // not a driver of the catalog voice pins.
    test('catalog voice pin: ReLU -> af_bella', () {
      expect(
        initialLlmProvider(null, true, const <String>[
          'web-llm',
          'kilo',
          'openai',
        ]),
        'apple-core-ai',
      );
      final companion = activeCompanion('default');
      expect(companion.id, 'default');
      expect(companionVoice(companion, 'kokoro-local'), 'af_bella');
    });

    test('catalog voice pin: Aria -> airi_aria', () {
      expect(
        initialLlmProvider(null, false, const <String>['openai', 'kilo']),
        'kilo',
      );
      final companion = activeCompanion('aria');
      expect(companion.id, 'aria');
      expect(companionVoice(companion, 'pocket-tts-local'), 'airi_aria');
    });
  });

  group('platform -> provider', () {
    test('precedence and fallback match quick-start.vue:307-325', () {
      final cases =
          <
            ({
              String name,
              String? draft,
              bool native,
              List<String> providers,
              String expected,
            })
          >[
            (
              name: 'draft wins over native Apple',
              draft: 'groq',
              native: true,
              providers: <String>['web-llm', 'kilo'],
              expected: 'groq',
            ),
            (
              name: 'empty draft is ignored',
              draft: '',
              native: false,
              providers: <String>['kilo'],
              expected: 'kilo',
            ),
            (
              name: 'native iOS wins over web-llm and kilo',
              draft: null,
              native: true,
              providers: <String>['web-llm', 'kilo'],
              expected: 'apple-core-ai',
            ),
            (
              name: 'web-llm wins over first provider',
              draft: null,
              native: false,
              providers: <String>['openai', 'web-llm'],
              expected: 'web-llm',
            ),
            (
              name: 'webllm alias is accepted',
              draft: null,
              native: false,
              providers: <String>['webllm', 'kilo'],
              expected: 'web-llm',
            ),
            (
              name: 'kilo wins over providers[0]',
              draft: null,
              native: false,
              providers: <String>['kilo', 'openai'],
              expected: 'kilo',
            ),
            (
              name: 'kilo wins when the first provider is another cloud',
              draft: null,
              native: false,
              providers: <String>['groq', 'kilo'],
              expected: 'kilo',
            ),
            (
              name: 'first provider when no preferred id exists',
              draft: null,
              native: false,
              providers: <String>['groq', 'anthropic'],
              expected: 'groq',
            ),
            (
              name: 'empty first provider falls back to openai like Vue',
              draft: null,
              native: false,
              providers: <String>['', 'groq'],
              expected: 'openai',
            ),
            (
              name: 'empty registry falls back to openai',
              draft: null,
              native: false,
              providers: <String>[],
              expected: 'openai',
            ),
            (
              name: 'all empty provider ids fall back to openai',
              draft: null,
              native: false,
              providers: <String>['', ''],
              expected: 'openai',
            ),
          ];

      for (final c in cases) {
        expect(
          initialLlmProvider(c.draft, c.native, c.providers),
          c.expected,
          reason: c.name,
        );
      }
    });
  });

  group('ttft -> pacing', () {
    test('boundaries match quick-start.vue:392-405 exactly', () {
      const cases = <(int, String)>[
        (0, 'snappy'),
        (799, 'snappy'),
        (800, 'balanced'),
        (2500, 'balanced'),
        (2501, 'deep'),
        (9223372036854775807, 'deep'),
      ];
      for (final (ttftMs, expected) in cases) {
        expect(pacingForTtftMs(ttftMs).id, expected, reason: '$ttftMs ms');
      }
    });
  });
}
