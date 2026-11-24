// SPDX-License-Identifier: GPL-3.0-or-later

// airi-xpy Flutter half: mirror of crates/anima-speech/src/tap.rs plus the
// Option C WAVE reader harness and the client-stamped LipSyncRmsData shape.

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/speech.dart';

List<double> _levels(List<AmplitudeFrame> frames) =>
    frames.whereType<AmplitudeLevel>().map((frame) => frame.level).toList();

Uint8List _wav16({
  required int sampleRate,
  required int channels,
  required List<int> samples,
}) {
  final dataLength = samples.length * 2;
  final bytes = Uint8List(44 + dataLength);
  final view = ByteData.sublistView(bytes);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little); // PCM
  view.setUint16(22, channels, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * channels * 2, Endian.little);
  view.setUint16(32, channels * 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

void main() {
  group('AmplitudeTap (Rust tap.rs mirror)', () {
    test('50ms non-overlapping windows at the source sample rate', () async {
      // 100 Hz => 5 samples/window; 12 samples => 2 windows + 2-sample tail.
      final samples = List<double>.generate(12, (i) => 0.5);
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: samples,
        ),
        abort: AbortHandle(),
      ).run().toList();

      expect(_levels(frames), hasLength(3));
      for (final level in _levels(frames)) {
        expect(level, closeTo(0.5, 1e-12));
      }
      expect(frames.last, isA<AmplitudeDone>());
      expect(frames.whereType<AmplitudeDone>(), hasLength(1));
    });

    test('level = min(1, sqrt(mean(x^2))) and clamps above 1.0', () async {
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: <double>[1.0, 1.0, 1.0, 1.0, 1.0],
        ),
        abort: AbortHandle(),
      ).run().toList();
      expect(_levels(frames), <double>[1.0]);
      expect(frames.last, isA<AmplitudeDone>());
    });

    test('partial tail is flushed exactly once', () async {
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: <double>[0.0, 0.8, 0.0],
        ),
        abort: AbortHandle(),
      ).run().toList();
      expect(_levels(frames), hasLength(1));
      expect(_levels(frames).single, closeTo(math.sqrt(0.64 / 3), 1e-12));
      expect(frames.last, isA<AmplitudeDone>());
    });

    test('aborted tap is silent and emits no Done', () async {
      final abort = AbortHandle();
      abort.abort();
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: List<double>.filled(20, 1.0),
        ),
        abort: abort,
      ).run().toList();
      expect(frames, isEmpty);
    });

    test('windowMs below 5 is clamped as in tap.rs', () async {
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 1000,
          channels: 1,
          samples: List<double>.filled(5, 0.25),
        ),
        abort: AbortHandle(),
        windowMs: 1,
      ).run().toList();
      expect(_levels(frames), hasLength(1));
      expect(_levels(frames).single, closeTo(0.25, 1e-12));
    });
  });

  group('WavPcmSource (Option C harness)', () {
    test('decodes 16-bit PCM and feeds the tap', () async {
      final source = WavPcmSource.fromBytes(
        _wav16(
          sampleRate: 100,
          channels: 1,
          samples: List<int>.filled(5, 16384),
        ),
      );
      expect(source.sampleRate, 100);
      expect(source.channels, 1);
      final frames = await AmplitudeTap(
        source: source,
        abort: AbortHandle(),
      ).run().toList();
      expect(_levels(frames).single, closeTo(0.5, 1e-3));
      expect(frames.last, isA<AmplitudeDone>());
    });

    test('rejects non-WAVE bytes', () {
      expect(
        () => WavPcmSource.fromBytes(Uint8List(64)),
        throwsFormatException,
      );
    });
  });

  group('LipSyncGenerator', () {
    test('stamps monotonic seq and epoch ms in LipSyncRmsData shape', () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000000123);
      final generator = LipSyncGenerator(
        actorId: 'character-7',
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: List<double>.filled(10, 0.42),
        ),
        abort: AbortHandle(),
        now: () => now,
      );
      final frames = await generator.frames().toList();
      expect(frames, hasLength(2));
      expect(frames.map((f) => f.seq), <int>[0, 1]);
      expect(frames.map((f) => f.tsMs), <int>[1700000000123, 1700000000123]);
      expect(frames.first.level, closeTo(0.42, 1e-12));

      // Wire keys must match crates/anima-channel/src/wire.rs exactly.
      final json = frames.first.toJson();
      expect(json.keys,
          containsAll(<String>['actor_id', 'level', 'seq', 'ts_ms']));
      expect(LipSyncRmsData.fromJson(json).actorId, 'character-7');
    });
  });

  group('Option C end-to-end (real decoded PCM)', () {
    test('WAV samples drive LipSyncGenerator with stamped wire fields',
        () async {
      final now = DateTime.fromMillisecondsSinceEpoch(1700000001123);
      final source = WavPcmSource.fromBytes(
        _wav16(
          sampleRate: 100,
          channels: 1,
          samples: List<int>.filled(5, 16384),
        ),
      );
      final generator = LipSyncGenerator(
        actorId: 'pet-1',
        source: source,
        abort: AbortHandle(),
        now: () => now,
      );
      final frames = await generator.frames().toList();
      expect(frames, hasLength(1));
      expect(frames.single.level, closeTo(0.5, 1e-3));
      expect(frames.single.seq, 0);
      expect(frames.single.tsMs, 1700000001123);

      final wire = frames.single.toJson();
      expect(wire['actor_id'], 'pet-1');
      expect(wire.keys,
          containsAll(<String>['actor_id', 'level', 'seq', 'ts_ms']));
    });
  });

  group('Option B engine dependency gap', () {
    test('missing adapter is reported, not substituted with fake PCM',
        () async {
      final engine = SherpaTtsEngine(
        config:
            const SherpaTtsConfig(model: '/tmp/no.onnx', tokens: '/tmp/no.txt'),
      );
      await expectLater(
          engine.initialize(), throwsA(isA<TtsEngineUnavailable>()));
      await expectLater(
          engine.synthesize('hello'), throwsA(isA<TtsEngineUnavailable>()));
      engine.dispose();
    });
  });
}
