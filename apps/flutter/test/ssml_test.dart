// SPDX-License-Identifier: GPL-3.0-or-later

// Parity tests for the pure Dart port of the TS speech store helpers:
// toSignedPercent (speech.test.ts:12-21) and generateSSML. Escaping
// expectations were verified against the repo-pinned xast-util-to-xml, which
// emits numeric character references and leaves `>` literal.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/speech.dart';

void main() {
  group('toSignedPercent', () {
    test('formats positive percentages with a plus sign', () {
      expect(toSignedPercent(25), '+25%');
      expect(toSignedPercent(1.5), '+1.5%');
      expect(toSignedPercent(25.0), '+25%');
      expect(toSignedPercent(1e19), '+10000000000000000000%');
    });

    test('formats negative percentages', () {
      expect(toSignedPercent(-20), '-20%');
      expect(toSignedPercent(-0.5), '-0.5%');
    });

    test('formats zero as 0%', () {
      expect(toSignedPercent(0), '0%');
    });
  });

  group('generateSSML', () {
    const voice = SsmlVoice(id: 'v1');
    const prefix = '<speak version="1.0"'
        ' xmlns="http://www.w3.org/2001/10/synthesis"'
        ' xml:lang="en-US">'
        '<voice name="v1" gender="neutral">';
    const suffix = '</voice></speak>';

    test('omits prosody when no provider config is given', () {
      expect(generateSSML('Hello world', voice), '$prefix' 'Hello world' '$suffix');
    });

    test('emits pitch, rate and volume in xast attribute order', () {
      final ssml = generateSSML('Hello', voice, <String, dynamic>{
        'pitch': 25,
        'speed': 1.5,
        'volume': -20,
      });
      expect(ssml, '$prefix'
          '<prosody pitch="+25%" rate="1.5" volume="-20%">Hello</prosody>'
          '$suffix');
    });

    test('renders speed 1 as rate="1" and integral doubles without .0', () {
      expect(generateSSML('Hi', voice, <String, dynamic>{'speed': 1}),
          '$prefix<prosody rate="1">Hi</prosody>$suffix');
      expect(generateSSML('Hi', voice, <String, dynamic>{'speed': 1.0}),
          '$prefix<prosody rate="1">Hi</prosody>$suffix');
      expect(generateSSML('Hi', voice, <String, dynamic>{'speed': 2.0}),
          '$prefix<prosody rate="2">Hi</prosody>$suffix');
    });

    test('renders large integral doubles without int64 overflow', () {
      expect(
        generateSSML('Hi', voice, <String, dynamic>{'speed': 1e19}),
        '$prefix<prosody rate="10000000000000000000">Hi</prosody>$suffix',
      );
    });

    test('emits only the prosody attributes that are present', () {
      expect(generateSSML('Hi', voice, <String, dynamic>{'volume': -10}),
          '$prefix<prosody volume="-10%">Hi</prosody>$suffix');
    });

    test('coerces non-numeric config values like JS', () {
      expect(
        generateSSML('Hi', voice, <String, dynamic>{
          'pitch': 'loud',
          'speed': null,
          'volume': 5,
        }),
        '$prefix<prosody pitch="0%" volume="+5%">Hi</prosody>$suffix',
      );
    });

    test('escapes text and attributes and drops XML noncharacters', () {
      final ssml = generateSSML(
        'A & B < C > D\u0001',
        const SsmlVoice(
          id: 'a&b"c',
          gender: 'female',
          languageCode: 'ja-JP',
        ),
      );
      expect(ssml,
          '<speak version="1.0"'
          ' xmlns="http://www.w3.org/2001/10/synthesis"'
          ' xml:lang="ja-JP">'
          '<voice name="a&#x26;b&#x22;c" gender="female">'
          'A &#x26; B &#x3C; C > D'
          '</voice></speak>');
    });

    test('falls back to en-US and neutral for empty voice fields', () {
      expect(
        generateSSML('', const SsmlVoice(id: 'v1', gender: '', languageCode: '')),
        '$prefix$suffix',
      );
    });
  });
}
