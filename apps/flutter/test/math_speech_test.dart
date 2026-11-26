// SPDX-License-Identifier: GPL-3.0-or-later

// Expectations are pinned from the LIVE TypeScript oracle, not from Dart,
// except the two spellFormula raw-core rows whose provenance is noted in place:
//   node --input-type=module importing
//     packages/speech-transformer-math/dist/index.mjs (spellNumber, MathSpeech)
//     packages/speech-transformer-chem/dist/index.mjs (chemistry, speakChemistry)
//     packages/stage-ui/src/utils/math-speech.ts (the three extraction helpers)
// Corpus seeded from numbers.test.ts:6-24, chem.test.ts:5-19,
// locales/en.test.ts:9-43 and math-speech.test.ts:47-112.
// This is a bounded subset port, not package parity: no TeX/KaTeX/MathJSON/
// mhchemparser parsing is ported; Chemistry takes an already-shaped AST.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/math_speech.dart';

void main() {
  group('spellNumber', () {
    // numbers.test.ts:6-20 — en/ja/ko columns, verified against the dist build.
    const rows = <(String source, String en, String ja, String ko)>[
      ('0', 'zero', 'ゼロ', '영'),
      ('14', 'fourteen', 'じゅうよん', '십사'),
      ('25', 'twenty-five', 'にじゅうご', '이십오'),
      ('300', 'three hundred', 'さんびゃく', '삼백'),
      ('600', 'six hundred', 'ろっぴゃく', '육백'),
      ('800', 'eight hundred', 'はっぴゃく', '팔백'),
      ('1,200', 'one thousand two hundred', 'せんにひゃく', '천이백'),
      ('3000', 'three thousand', 'さんぜん', '삼천'),
      ('10000', 'ten thousand', 'いちまん', '만'),
      // Largest scale: billion / 億 / 억 (oracle-pinned).
      ('2000000000', 'two billion', 'にじゅうおく', '이십억'),
      ('3.14', 'three point one four', 'さんてんいちよん', '삼 점 일사'),
    ];
    for (final row in rows) {
      test('spells ${row.$1} in all three languages', () {
        expect(spellNumber(row.$1, 'en'), row.$2);
        expect(spellNumber(row.$1, 'ja'), row.$3);
        expect(spellNumber(row.$1, 'ko'), row.$4);
      });
    }

    test('reads a very long integer digit by digit (numbers.test.ts:22-24)', () {
      expect(spellNumber('1234567890123', 'en'), 'one two three four five six seven eight nine zero one two three');
      expect(spellNumber('1234567890123', 'ja'), 'いちにさんよんごろくななはちきゅうゼロいちにさん');
      expect(spellNumber('1234567890123', 'ko'), '일이삼사오육칠팔구영일이삼');
    });

    // Extra oracle probes, expectations serialized as \uXXXX so NFC/NFD
    // normalization cannot hide a mismatch. 300/600/800 gemination is already
    // covered by the rows above.
    test('edge probes from the live TS oracle', () {
      const edges = <(String source, String en, String ja, String ko)>[
        ('-0', 'zero', '\u30bc\u30ed', '\uc601'),
        ('0.00001', 'zero point zero zero zero zero one', '\u30bc\u30ed\u3066\u3093\u30bc\u30ed\u30bc\u30ed\u30bc\u30ed\u30bc\u30ed\u3044\u3061', '\uc601 \uc810 \uc601\uc601\uc601\uc601\uc77c'),
        // JS Number('1e-7') is a tiny number whose every group is zero.
        ('1e-7', '', '', ''),
        ('9007199254740991', 'nine zero zero seven one nine nine two five four seven four zero nine nine one', '\u304d\u3085\u3046\u30bc\u30ed\u30bc\u30ed\u306a\u306a\u3044\u3061\u304d\u3085\u3046\u304d\u3085\u3046\u306b\u3054\u3088\u3093\u306a\u306a\u3088\u3093\u30bc\u30ed\u304d\u3085\u3046\u304d\u3085\u3046\u3044\u3061', '\uad6c\uc601\uc601\uce60\uc77c\uad6c\uad6c\uc774\uc624\uc0ac\uce60\uc0ac\uc601\uad6c\uad6c\uc77c'),
        ('1010', 'one thousand ten', '\u305b\u3093\u3058\u3085\u3046', '\ucc9c\uc2ed'),
        ('0.05', 'zero point zero five', '\u30bc\u30ed\u3066\u3093\u30bc\u30ed\u3054', '\uc601 \uc810 \uc601\uc624'),
      ];
      for (final entry in edges) {
        expect(spellNumber(entry.$1, 'en'), entry.$2, reason: entry.$1);
        expect(spellNumber(entry.$1, 'ja'), entry.$3, reason: entry.$1);
        expect(spellNumber(entry.$1, 'ko'), entry.$4, reason: entry.$1);
      }
    });

    // Safety probes: arbitrary strings must not throw. Every expectation here
    // is the live TS oracle's output, including its empty slots for bad digits.
    test('malformed digits stay total in all three languages', () {
      expect(spellNumber('1.abc', 'en'), 'one point   ');
      expect(spellNumber('1.abc', 'ja'), 'いちてん');
      expect(spellNumber('1.abc', 'ko'), '일 점 ');
      expect(spellNumber('-12345678901234', 'en'), ' one two three four five six seven eight nine zero one two three four');
      expect(spellNumber('-12345678901234', 'ja'), 'いちにさんよんごろくななはちきゅうゼロいちにさんよん');
      expect(spellNumber('-12345678901234', 'ko'), '일이삼사오육칠팔구영일이삼사');
      expect(spellNumber('01a', 'en'), 'zero one ');
      expect(spellNumber('01a', 'ja'), 'ゼロいち');
      expect(spellNumber('01a', 'ko'), '영일');
    });

    test('non-finite values stay total in all three languages', () {
      for (final source in <String>['Infinity', '-Infinity', 'NaN', '1e309']) {
        expect(spellNumber(source, 'en'), '', reason: source);
        expect(spellNumber(source, 'ja'), 'undefinedじゅうおくundefinedじゅうまんundefinedじゅう', reason: source);
        expect(spellNumber(source, 'ko'), 'undefined천undefined백undefined십undefined억undefined천undefined백undefined십undefined만undefined천undefined백undefined십undefined', reason: source);
      }
    });

    // Oracle trap: spellNumber strips commas, but the full MathSpeech.speak
    // reads a top-level `1,200` as a Sequence of two numbers: "one, two hundred".
    test('the 1,200 trap: spellNumber vs the Sequence reading', () {
      expect(spellNumber('1,200', 'en'), 'one thousand two hundred');
      expect(speakNumberGroups('1,200'), 'one, two hundred');
    });
  });

  group('spellFormula', () {
    // Provenance: most rows are pinned from MathSpeech({extensions:[chemistry()]})
    // .speak(r'\ce{...}', 'en') on a lone species. The `CuSO4·5H2O` and
    // `[Fe(CN)6]` rows are NOT from full MathSpeech.speak — it gives
    // 'C U S O four dot five H two O' and
    // 'open parenthesis F E open parenthesis C N close parenthesis six close parenthesis'.
    // Those two come from the bounded spellFormula regex applied to the raw
    // core, checked against the TS oracle via speakChemistry on a shaped AST.
    const cases = <(String core, String spoken)>[
      ('H2O', 'H two O'),
      ('SO4', 'S O four'),
      ('CuSO4', 'C U S O four'),
      ('NH3', 'N H three'),
      ('O2', 'O two'),
      ('Ca(OH)2', 'C A open parenthesis O H close parenthesis two'),
      ('Fe(OH)3', 'F E open parenthesis O H close parenthesis three'),
      ('Fe2(SO4)3', 'F E two open parenthesis S O four close parenthesis three'),
      // Raw-core row, not full MathSpeech.speak (which says "dot five"):
      // the middle-dot separator and leading 5 are outside the bounded regex.
      ('CuSO4\u00B75H2O', 'C U S O four H two O'),
      ('CH3COOH', 'C H three C O O H'),
      // Raw-core row, not full MathSpeech.speak (which leads with "open
      // parenthesis" and speaks both brackets): bounded regex skips brackets.
      ('[Fe(CN)6]', 'F E open parenthesis C N close parenthesis six'),
    ];
    for (final entry in cases) {
      test('reads ${entry.$1} symbol by symbol', () {
        expect(spellFormula(entry.$1), entry.$2);
      });
    }
  });

  group('speakChemistry (English)', () {
    List<Object?> species(String formula, [String? coefficient, String state = 'Nothing']) => <Object?>[
      'Species', "'$formula'", coefficient == null ? 'Nothing' : <String, String>{'num': coefficient}, state,
    ];

    test('2H2 + O2 -> 2H2O (locales/en.test.ts:10)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'->'",
          <Object?>['Side', <Object?>['Species', "'H2'", <String, String>{'num': '2'}, 'Nothing'], <Object?>['Species', "'O2'", 'Nothing', 'Nothing']],
          <Object?>['Side', <Object?>['Species', "'H2O'", <String, String>{'num': '2'}, 'Nothing']],
          'Nothing',
        ],
      ];
      expect(speakChemistry(ast), 'two H two plus O two yields two H two O');
    });

    test('N2 + 3H2 <=> 2NH3 (locales/en.test.ts:11)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'<=>'",
          <Object?>['Side', <Object?>['Species', "'N2'", 'Nothing', 'Nothing'], <Object?>['Species', "'H2'", <String, String>{'num': '3'}, 'Nothing']],
          <Object?>['Side', <Object?>['Species', "'NH3'", <String, String>{'num': '2'}, 'Nothing']],
          'Nothing',
        ],
      ];
      expect(speakChemistry(ast), 'N two plus three H two is in equilibrium with two N H three');
    });

    test('Fe^{3+} stays a bare ion outside an equation (locales/en.test.ts:12)', () {
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('Fe^3+')]]),
        'F E three plus',
      );
    });

    test('bare vs explicit-one charges and a polyatomic anion', () {
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('Ca^2+')]]),
        'C A two plus',
      );
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('Ca^+')]]),
        'C A plus',
      );
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('[Fe(CN)6]^3-')]]),
        'F E open parenthesis C N close parenthesis six three minus',
      );
    });

    test('an untrusted arrow does not crash the reader', () {
      // No oracle reading exists for '~>'; the safety fallback is "yields".
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Reaction', "'~>'",
          <Object?>['Side', species('H2')],
          <Object?>['Side', species('O2')],
          'Nothing',
        ]]),
        'H two yields O two',
      );
    });

    test('heat condition and gas mark (locales/en.test.ts:13)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'->'",
          <Object?>['Side', <Object?>['Species', "'CaCO3'", 'Nothing', 'Nothing']],
          <Object?>['Side', <Object?>['Species', "'CaO'", 'Nothing', 'Nothing'], <Object?>['Gas', <Object?>['Species', "'CO2'", 'Nothing', 'Nothing']]],
          <Object?>['Heat'],
        ],
      ];
      expect(speakChemistry(ast), 'with heat C A C O three yields C A O plus C O two gas');
    });

    test('parenthesised groups in an equation (locales/en.test.ts:23)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'->'",
          <Object?>['Side', <Object?>['Species', "'Ca(OH)2'", 'Nothing', 'Nothing'], <Object?>['Species', "'CO2'", 'Nothing', 'Nothing']],
          <Object?>['Side', <Object?>['Species', "'CaCO3'", 'Nothing', 'Nothing'], <Object?>['Species', "'H2O'", 'Nothing', 'Nothing']],
          'Nothing',
        ],
      ];
      expect(speakChemistry(ast), 'C A open parenthesis O H close parenthesis two plus C O two yields C A C O three plus H two O');
    });

    test('hydrate keeps the dot (locales/en.test.ts:24)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Side', <Object?>['Hydrate',
          <Object?>['Species', "'CuSO4'", 'Nothing', 'Nothing'],
          <Object?>['Species', "'H2O'", <String, String>{'num': '5'}, 'Nothing'],
        ]],
      ];
      expect(speakChemistry(ast), 'C U S O four dot five H two O');
    });

    test('precipitate (locales/en.test.ts:32)', () {
      const ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'->'",
          <Object?>['Side', <Object?>['Species', "'AgNO3'", 'Nothing', 'Nothing'], <Object?>['Species', "'NaCl'", 'Nothing', 'Nothing']],
          <Object?>['Side', <Object?>['Precipitate', <Object?>['Species', "'AgCl'", 'Nothing', 'Nothing']], <Object?>['Species', "'NaNO3'", 'Nothing', 'Nothing']],
          'Nothing',
        ],
      ];
      expect(speakChemistry(ast), 'A G N O three plus N A C L yields A G C L precipitate plus N A N O three');
    });

    test('SO4^2- and H2O(l) (locales/en.test.ts:33-34)', () {
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('SO4^2-')]]),
        'S O four two minus',
      );
      expect(
        speakChemistry(<Object?>['Chemistry', <Object?>['Side', species('H2O', null, "'l'")]]),
        'H two O',
      );
    });

    test('ion word ends the charge inside an equation (locales/en.test.ts:42)', () {
      final ast = <Object?>[
        'Chemistry', <Object?>['Reaction', "'->'",
          <Object?>['Side', species('Fe^3+'), species('OH^-', '3')],
          <Object?>['Side', <Object?>['Precipitate', species('Fe(OH)3')]],
          'Nothing',
        ],
      ];
      expect(speakChemistry(ast), 'F E three plus ion plus three O H minus ion yields F E open parenthesis O H close parenthesis three precipitate');
    });
  });

  group('detectSpeechLanguage', () {
    // math-speech.ts:48-58 / math-speech.test.ts:47-65.
    test('narrows on the dominant script of the context', () {
      expect(detectSpeechLanguage('値段は 5x です'), 'ja');
      expect(detectSpeechLanguage('가격은 5x입니다'), 'ko');
      expect(detectSpeechLanguage('价格是 5x'), 'zh');
      expect(detectSpeechLanguage('价格是 5x', 'ja'), 'ja');
      expect(detectSpeechLanguage('the price is 5x'), 'en');
      expect(detectSpeechLanguage('123 456'), 'en');
      expect(detectSpeechLanguage('123 456', 'ko'), 'ko');
      // U+00A0 and U+2009 are whitespace, not scripts.
      expect(detectSpeechLanguage('\u00A0the price\u2009is 5x'), 'en');
      // Kana wins over Han: math-speech.ts checks the scripts in order.
      expect(detectSpeechLanguage('\u00A0\u4EF7\u683C\u2009\u306F 5x'), 'ja');
    });
  });

  group('braceBareScripts', () {
    // math-speech.ts:139-141 / math-speech.test.ts:68-75.
    test('braces only multi-digit or decimal scripts', () {
      expect(braceBareScripts('2^10'), '2^{10}');
      expect(braceBareScripts('x_12'), 'x_{12}');
      expect(braceBareScripts('v2^3'), 'v2^3');
      expect(braceBareScripts('a_1.5'), 'a_{1.5}');
    });

    test('passes literal dollar delimiters, currency and Unicode whitespace through', () {
      expect(braceBareScripts(r'$$x^2$$'), r'$$x^2$$');
      expect(braceBareScripts(r'$x^2$'), r'$x^2$');
      expect(braceBareScripts(r'$$x_12$$'), r'$$x_{12}$$');
      expect(braceBareScripts(r'$x_12$'), r'$x_{12}$');
      expect(braceBareScripts('2^10\u00A0x_34'), '2^{10}\u00A0x_{34}');
      expect(braceBareScripts(r'$5 and $10'), r'$5 and $10');
    });
  });

  group('replaceBalancedCommand', () {
    // math-speech.ts:146-199 / math-speech.test.ts:94-112.
    String replacer(String full, String inner) => '<$inner>';

    test('replaces every balanced occurrence', () {
      expect(replaceBalancedCommand(r'a \ce{H2O} b \ce{CO2} c', 'ce', replacer), 'a <H2O> b <CO2> c');
    });

    test('keeps nested balanced groups in the inner capture', () {
      expect(replaceBalancedCommand(r'\f{x{y}z}', 'f', replacer), '<x{y}z>');
    });

    test('skips escaped and unbalanced occurrences', () {
      expect(replaceBalancedCommand(r'\\ce{H2O}', 'ce', replacer), r'\\ce{H2O}');
      expect(replaceBalancedCommand(r'a \ce{H2O', 'ce', replacer), r'a \ce{H2O');
    });

    test('stops at the matching brace and preserves Unicode whitespace', () {
      expect(replaceBalancedCommand(r'\f{\g{x+1}}{2}', 'f', replacer), r'<\g{x+1}>{2}');
      expect(replaceBalancedCommand('a\u00A0\\f{x{y}z}\u2009b', 'f', replacer), 'a\u00A0<x{y}z>\u2009b');
    });
  });
}
