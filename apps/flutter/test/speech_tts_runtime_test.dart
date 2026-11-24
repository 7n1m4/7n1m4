// SPDX-License-Identifier: GPL-3.0-or-later

// Runtime Option B proof for Flutter: text -> real on-device TTS PCM -> RMS
// envelopes -> the client's available sink (LipSyncRmsData wire frames;
// Flutter has no renderer). The deterministic path substitutes only the
// *process* boundary: the fake piper still writes a genuine WAVE file that
// WavPcmSource decodes. The fixture is a real WAVE file, not fake RMS
// frames; no PCM is injected into the tap.

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/speech.dart';

/// Builds a valid 16-bit PCM WAVE file — the exact artifact the real piper CLI
/// writes to `--output_file`. Only file bytes are synthesized; the samples are
/// decoded by the production [WavPcmSource], never injected into the tap.
Uint8List _realWav16({
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
  view.setUint16(20, 1, Endian.little);
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
  group('Option B runtime: Piper CLI -> decoded WAVE PCM -> RMS wire frames',
      () {
    test('text drives LipSyncGenerator through a real WAVE output file',
        () async {
      final tempModel = await File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'anima-test-voice-${DateTime.now().microsecondsSinceEpoch}.onnx',
      ).create();
      final modelPath = tempModel.path;
      final now = DateTime.fromMillisecondsSinceEpoch(1700000002000);
      List<String>? observedArgs;
      String? observedExecutable;
      String? observedStdin;

      final engine = PiperTtsEngine(
        executable: 'piper-test-binary',
        modelPath: modelPath,
        processRunner: (
          String executable,
          List<String> arguments,
          String text, {
          String? workingDirectory,
        }) async {
          observedExecutable = executable;
          observedArgs = arguments;
          observedStdin = text;
          final output = arguments[arguments.indexOf('--output_file') + 1];
          // Deterministic WAVE artifact produced by the fake CLI process:
          // 100 Hz, 12 samples at 0.5 plus a 2-sample tail at 0.25 ->
          // 2 full windows + one tail frame containing two 0.5 and two 0.25.
          await File(output).writeAsBytes(_realWav16(
            sampleRate: 100,
            channels: 1,
            samples: <int>[
              ...List<int>.filled(12, 16384),
              8192,
              8192,
            ],
          ));
          return PiperProcessResult(0, '', stdinText: text);
        },
      );

      try {
        final source = await engine.synthesizeToSource('hello pet');
        expect(engine.sampleRate, 100);
        expect(observedExecutable, 'piper-test-binary');
        expect(observedStdin, 'hello pet');
        expect(observedArgs, contains('--model'));
        expect(observedArgs, contains(modelPath));
        expect(observedArgs, contains('--output_file'));
        // Canonical piper reads text from stdin, never as a positional arg.
        expect(observedArgs, isNot(contains('hello pet')));

        final generator = LipSyncGenerator(
          actorId: 'pet-1',
          source: source,
          abort: AbortHandle(),
          now: () => now,
        );
        final frames = await generator.frames().toList();

        expect(frames, hasLength(3));
        final levels = frames.map((f) => f.level).toList();
        expect(levels[0], closeTo(0.5, 1e-3));
        expect(levels[1], closeTo(0.5, 1e-3));
        expect(levels[2], closeTo(math.sqrt((2 * 0.25 + 2 * 0.0625) / 4), 1e-3));
        expect(frames.map((f) => f.seq), <int>[0, 1, 2]);
        for (final frame in frames) {
          expect(frame.tsMs, 1700000002000);
          final wire = frame.toJson();
          expect(wire.keys,
              containsAll(<String>['actor_id', 'level', 'seq', 'ts_ms']));
          expect(wire['actor_id'], 'pet-1');
        }
      } finally {
        engine.dispose();
        await tempModel.delete();
      }
    });

    test('missing model is reported, never replaced by fake PCM', () async {
      final engine = PiperTtsEngine(
        executable: 'piper',
        modelPath: '${Directory.systemTemp.path}'
            '${Platform.pathSeparator}anima-missing-voice.onnx',
      );
      await expectLater(
        engine.synthesizeToSource('hello'),
        throwsA(isA<TtsEngineUnavailable>()),
      );
      engine.dispose();
    });

    test('nonzero CLI exit is reported instead of decoded as audio', () async {
      final tempModel = await File(
        '${Directory.systemTemp.path}${Platform.pathSeparator}'
        'anima-test-voice-fail-${DateTime.now().microsecondsSinceEpoch}.onnx',
      ).create();
      final engine = PiperTtsEngine(
        executable: 'piper-test-binary',
        modelPath: tempModel.path,
        processRunner: (
          String executable,
          List<String> arguments,
          String text, {
          String? workingDirectory,
        }) async {
          // No WAVE file written at all: a buggy engine that silently
          // substitutes fake PCM would still succeed here.
          return PiperProcessResult(
            2,
            'model load failed',
            stdinText: text,
          );
        },
      );
      try {
        await expectLater(
          engine.synthesizeToSource('hello'),
          throwsA(isA<TtsEngineUnavailable>()),
        );
      } finally {
        engine.dispose();
        await tempModel.delete();
      }
    });
  });

  group('Option B runtime: sherpa adapter registration', () {
    test('registry adapter registered after construction drives the sink',
        () async {
      final previous = sherpaLoader;
      final loader = _DeterministicSherpaLoader();
      // Engine is created BEFORE registration: the public registry must be
      // consulted at initialize() time, not captured at construction.
      final engine = SherpaTtsEngine(
        config:
            const SherpaTtsConfig(model: 'voice.onnx', tokens: 'tokens.txt'),
      );
      try {
        registerSherpaLoader(loader);
        await engine.initialize();
        final source = await engine.synthesizeToSource('hello');

        // The exact adapter PCM reaches the tap: a fabricated/tampered source
        // would change these decoded sample values and therefore the levels.
        final samples = <double>[];
        await for (final sample in source.open()) {
          samples.add(sample);
        }
        expect(samples.length, 8);
        for (final sample in samples.sublist(0, 5)) {
          expect(sample, closeTo(0.5, 1e-12));
        }
        for (final sample in samples.sublist(5)) {
          expect(sample, closeTo(0.25, 1e-12));
        }

        final generator = LipSyncGenerator(
          actorId: 'sherpa-pet',
          source: source,
          abort: AbortHandle(),
        );
        final frames = await generator.frames().toList();

        expect(loader.initCalls, 1);
        expect(loader.generatedText, 'hello');
        expect(engine.sampleRate, 100);
        expect(frames, hasLength(2));
        final levels = frames.map((f) => f.level).toList();
        expect(levels[0], closeTo(0.5, 1e-12));
        expect(levels[1], closeTo(0.25, 1e-12));
        expect(frames.map((f) => f.seq), <int>[0, 1]);
        for (final frame in frames) {
          expect(frame.toJson().keys,
              containsAll(<String>['actor_id', 'level', 'seq', 'ts_ms']));
        }
        engine.dispose();
        expect(loader.freed, isTrue);
      } finally {
        // Idempotent: engine may already have been disposed on the happy path.
        engine.dispose();
        if (previous == null) {
          SherpaLoaderRegistry.instance.clear();
        } else {
          registerSherpaLoader(previous);
        }
      }
    });
  });

  group('TtsEngine.synthesizeToSource timing', () {
    test('uses sample rate learned during synthesize for the PCM source',
        () async {
      final engine = _RateAfterSynthesisEngine();
      expect(engine.sampleRate, 0);

      // The inherited default implementation must await synthesis before it
      // snapshots sampleRate into the one-shot source.
      final source = await engine.synthesizeToSource('hello');
      expect(engine.sampleRate, 100);
      expect(source.sampleRate, 100);
      expect(source.channels, 1);

      final frames = await LipSyncGenerator(
        actorId: 'late-rate',
        source: source,
        abort: AbortHandle(),
      ).frames().toList();
      expect(frames, hasLength(2));
      expect(frames.first.level, closeTo(0.5, 1e-12));
      expect(frames.last.level, closeTo(0.25, 1e-12));
      engine.dispose();
    });
  });

  group('Option B RMS correctness (negative controls)', () {
    test('correct levels differ from a wrong 100ms window and from raw means',
        () async {
      // Mixed 100 Hz PCM: first 50 ms window is [0, 1, 0, 1, 0].
      // Correct RMS is sqrt(0.4) ~= 0.632; a buggy arithmetic mean emits 0.4.
      // A buggy 100 ms window over all eight samples emits ~= 0.523.
      const samples = <double>[0.0, 1.0, 0.0, 1.0, 0.0, 0.25, 0.25, 0.25];
      final frames = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: samples,
        ),
        abort: AbortHandle(),
      ).run().toList();
      final levels = frames.whereType<AmplitudeLevel>().map((f) => f.level);
      expect(levels.first, closeTo(math.sqrt(0.4), 1e-12));
      expect(levels.first, isNot(closeTo(0.4, 1e-12))); // not arithmetic mean
      expect(levels.first,
          isNot(closeTo(math.sqrt((2 * 1.0 + 3 * 0.0625) / 8), 1e-12)));

      final wrongWindow = await AmplitudeTap(
        source: MemoryPcmSource(
          sampleRate: 100,
          channels: 1,
          samples: samples,
        ),
        abort: AbortHandle(),
        windowMs: 100,
      ).run().toList();
      final wrongLevels =
          wrongWindow.whereType<AmplitudeLevel>().map((f) => f.level).toList();
      expect(wrongLevels, hasLength(1));
      expect(wrongLevels.single, isNot(closeTo(levels.first, 1e-12)));
    });
  });

  group('Option B real-engine gate (opt-in)', () {
    final model = Platform.environment['PIPER_MODEL'];
    final executable = Platform.environment['PIPER_PATH'] ?? 'piper';
    final enabled = model != null && model.isNotEmpty;

    test('real piper synthesis drives the RMS sink', () async {
      final engine = PiperTtsEngine(executable: executable, modelPath: model!);
      try {
        await engine.initialize();
        final source = await engine.synthesizeToSource('hello pet');
        expect(engine.sampleRate, greaterThan(0));
        final frames = await LipSyncGenerator(
          actorId: 'real-piper',
          source: source,
          abort: AbortHandle(),
        ).frames().toList();
        expect(frames, isNotEmpty);
        for (final frame in frames) {
          expect(frame.level, greaterThanOrEqualTo(0.0));
          expect(frame.level, lessThanOrEqualTo(1.0));
          expect(frame.level, greaterThan(0.0));
          expect(frame.toJson().keys,
              containsAll(<String>['actor_id', 'level', 'seq', 'ts_ms']));
        }
      } finally {
        engine.dispose();
      }
    }, skip: enabled ? false : 'set PIPER_MODEL (and optionally PIPER_PATH)');
  });
}

/// Deterministic adapter for the *public* sherpa boundary. Its samples are a
/// fixed real f32 buffer (not fake RMS frames); the tap computes envelopes.
class _DeterministicSherpaLoader implements SherpaLoader {
  int initCalls = 0;
  String? generatedText;
  bool freed = false;

  @override
  Future<void> initBindings() async => initCalls++;

  @override
  Object createOfflineTts(SherpaTtsConfig config) =>
      Object(); // opaque handle, as the real plugin would return

  @override
  int sampleRate(Object tts) => 100;

  @override
  GeneratedPcm generate(Object tts, String text, SherpaTtsConfig config) {
    generatedText = text;
    return GeneratedPcm(
      samples: Float32List.fromList(<double>[
        ...List<double>.filled(5, 0.5),
        ...List<double>.filled(3, 0.25),
      ]),
      sampleRate: 100,
    );
  }

  @override
  void free(Object tts) => freed = true;
}

/// Engine that only learns its output rate while synthesis is in flight.
class _RateAfterSynthesisEngine extends TtsEngine {
  int _sampleRate = 0;

  @override
  String get id => 'late-rate-test';

  @override
  int get sampleRate => _sampleRate;

  @override
  Future<Float32List> synthesize(String text) async {
    await Future<void>.delayed(Duration.zero);
    _sampleRate = 100;
    return Float32List.fromList(<double>[
      ...List<double>.filled(5, 0.5),
      ...List<double>.filled(3, 0.25),
    ]);
  }

  @override
  void dispose() {}
}
