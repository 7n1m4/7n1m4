// SPDX-License-Identifier: GPL-3.0-or-later

// In-process algorithmic mirror of packages/stage-ui/src/services/speech/
// audio-cache.ts: only the deterministic key normalization and the bounded
// LRU core are ported. BroadcastChannel sync, the global singleton, message
// associations/isMessageCached and engine wiring are deliberately excluded.
// No replay caller exists in the Flutter client yet, so this is not cache
// parity — it is the shared key/LRU core made directly testable.

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/audio_cache.dart';

void main() {
  group('createSpeechAudioCacheKey', () {
    test('applies JS-like defaults and trims the text', () {
      expect(
        createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: '  hello  ',
        ),
        '["p","m","v",0,1,false,"",null,"hello"]',
      );
    });

    test('encodes all parameters in the TS field order', () {
      expect(
        createSpeechAudioCacheKey(
          providerId: 'provider',
          model: 'model',
          voiceId: 'voice',
          text: 'hi',
          pitch: 25,
          speed: 1.5,
          ssml: true,
          language: 'ja-JP',
          extra: <String, dynamic>{'style': 'calm'},
        ),
        '["provider","model","voice",25,1.5,true,"ja-JP",'
        '{"style":"calm"},"hi"]',
      );
    });

    test('stringifies integral doubles like JS JSON.stringify', () {
      final keyedWithDoubles = createSpeechAudioCacheKey(
        providerId: 'p',
        model: 'm',
        voiceId: 'v',
        text: 'hi',
        pitch: 2.0,
        speed: 1.0,
      );
      expect(keyedWithDoubles, '["p","m","v",2,1,false,"",null,"hi"]');
      expect(
        keyedWithDoubles,
        createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
          pitch: 2,
          speed: 1,
        ),
      );
    });

    test('normalizes numbers nested in extra like JS JSON.stringify', () {
      expect(
        createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
          extra: <String, dynamic>{
            'gain': 2.0,
            'nested': <String, dynamic>{'rate': 1.0, 'label': 'x'},
            'list': <dynamic>[3.0, 0.5],
          },
        ),
        '["p","m","v",0,1,false,"",'
        '{"gain":2,"nested":{"rate":1,"label":"x"},"list":[3,0.5]},'
        '"hi"]',
      );
    });

    test('preserves extra key insertion order', () {
      expect(
        createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
          extra: <String, dynamic>{'z': 1, 'a': 2},
        ),
        '["p","m","v",0,1,false,"",{"z":1,"a":2},"hi"]',
      );
    });

    test('only identical synthesis parameters share a key', () {
      final base = createSpeechAudioCacheKey(
        providerId: 'p',
        model: 'm',
        voiceId: 'v',
        text: 'hi',
      );
      expect(
        base,
        createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
        ),
      );
      expect(
        base,
        isNot(createSpeechAudioCacheKey(
          providerId: 'other',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
        )),
      );
      expect(
        base,
        isNot(createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'bye',
        )),
      );
      expect(
        base,
        isNot(createSpeechAudioCacheKey(
          providerId: 'p',
          model: 'm',
          voiceId: 'v',
          text: 'hi',
          ssml: true,
        )),
      );
    });
  });

  group('count LRU', () {
    test('get refreshes recency so the oldest untouched entry is evicted', () {
      final cache = SpeechAudioCache(maxEntries: 2);
      cache.set('a', Uint8List(1));
      cache.set('b', Uint8List(1));

      expect(cache.get('a'), isNotNull);
      cache.set('c', Uint8List(1));

      expect(cache.size, 2);
      expect(cache.has('a'), isTrue);
      expect(cache.has('b'), isFalse);
      expect(cache.has('c'), isTrue);
    });

    test('has does not refresh recency', () {
      final cache = SpeechAudioCache(maxEntries: 2);
      cache.set('a', Uint8List(1));
      cache.set('b', Uint8List(1));

      expect(cache.has('a'), isTrue);
      cache.set('c', Uint8List(1));

      expect(cache.size, 2);
      expect(cache.has('a'), isFalse);
      expect(cache.has('b'), isTrue);
      expect(cache.has('c'), isTrue);
    });

    test('overwriting a key replaces its bytes and refreshes recency', () {
      final cache = SpeechAudioCache(maxEntries: 3, maxBytes: 100);
      cache.set('a', Uint8List(2));
      cache.set('b', Uint8List(3));
      cache.set('a', Uint8List(6));

      expect(cache.size, 2);
      expect(cache.totalBytes, 9);
      expect(cache.get('a'), Uint8List(6));

      cache.set('c', Uint8List(1));
      cache.set('d', Uint8List(1));

      expect(cache.size, 3);
      expect(cache.totalBytes, 8);
      expect(cache.has('a'), isTrue);
      expect(cache.has('b'), isFalse);
      expect(cache.has('c'), isTrue);
      expect(cache.has('d'), isTrue);
    });
  });

  group('byte LRU', () {
    test('a buffer larger than the byte budget is a no-op', () {
      final cache = SpeechAudioCache(maxBytes: 10);
      cache.set('big', Uint8List(11));

      expect(cache.size, 0);
      expect(cache.totalBytes, 0);
      expect(cache.has('big'), isFalse);
      expect(cache.get('big'), isNull);
    });

    test('oldest entries are evicted until the buffer fits the budget', () {
      final cache = SpeechAudioCache(maxBytes: 10);
      cache.set('a', Uint8List.fromList(<int>[1, 2, 3, 4]));
      cache.set('b', Uint8List.fromList(<int>[5, 6, 7, 8]));
      expect(cache.totalBytes, 8);

      cache.set('c', Uint8List(5));

      expect(cache.size, 2);
      expect(cache.totalBytes, 9);
      expect(cache.has('a'), isFalse);
      expect(cache.get('b'), <int>[5, 6, 7, 8]);
      expect(cache.get('c'), Uint8List(5));
    });

    test('evicts several oldest entries to fit one larger buffer', () {
      final cache = SpeechAudioCache(maxBytes: 10);
      cache.set('a', Uint8List(4));
      cache.set('b', Uint8List(3));
      cache.set('c', Uint8List(2));
      expect(cache.totalBytes, 9);

      cache.set('d', Uint8List(6));

      expect(cache.size, 2);
      expect(cache.totalBytes, 8);
      expect(cache.has('a'), isFalse);
      expect(cache.has('b'), isFalse);
      expect(cache.has('c'), isTrue);
      expect(cache.has('d'), isTrue);
      expect(cache.get('c'), Uint8List(2));
      expect(cache.get('d'), Uint8List(6));

      cache.set('e', Uint8List(3));
      expect(cache.has('c'), isFalse);
      expect(cache.has('d'), isTrue);
      expect(cache.has('e'), isTrue);
      expect(cache.totalBytes, 9);
    });

    test('accepts a buffer exactly at the byte budget', () {
      final cache = SpeechAudioCache(maxBytes: 10);
      cache.set('exact', Uint8List(10));

      expect(cache.size, 1);
      expect(cache.totalBytes, 10);
      expect(cache.get('exact'), Uint8List(10));
    });

    test('a zero-byte entry is a get miss but remains present', () {
      final cache = SpeechAudioCache(maxBytes: 10);
      cache.set('empty', Uint8List(0));

      expect(cache.has('empty'), isTrue);
      expect(cache.get('empty'), isNull);
      expect(cache.has('empty'), isTrue);
      expect(cache.size, 1);
      expect(cache.totalBytes, 0);
    });
  });

  group('clear', () {
    test('drops every entry and resets the byte counter', () {
      final cache = SpeechAudioCache(maxEntries: 3, maxBytes: 100);
      cache.set('a', Uint8List(4));
      cache.set('b', Uint8List(6));

      cache.clear();

      expect(cache.size, 0);
      expect(cache.totalBytes, 0);
      expect(cache.has('a'), isFalse);
      expect(cache.has('b'), isFalse);
      expect(cache.get('a'), isNull);

      cache.set('c', Uint8List(3));
      expect(cache.size, 1);
      expect(cache.totalBytes, 3);
      expect(cache.get('c'), Uint8List(3));
    });
  });
}
