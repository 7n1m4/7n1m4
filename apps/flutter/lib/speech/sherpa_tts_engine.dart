// SPDX-License-Identifier: GPL-3.0-or-later

// Option B (ratified primary path): on-device Piper-class TTS exposing raw
// PCM. sherpa-onnx 2.0.3 ships a Flutter FFI binding whose `OfflineTts`
// returns `GeneratedAudio.samples` as Float32List — a real PCM source, no
// OS TTS tap. The binding is optional at runtime so apps without the plugin
// (e.g. unit tests) still load; model artifacts are downloaded assets, never
// repo blobs (decision-client-local-tts-pcm.md:39).

import 'dart:async';
import 'dart:typed_data';

import 'pcm_source.dart';

/// Thrown when Option B is unavailable: dep not installed, native library not
/// loaded, or model files missing. Never substitute synthetic PCM — callers
/// should fall back to Option C ([WavPcmSource]) with a real decoded file.
class TtsEngineUnavailable implements Exception {
  const TtsEngineUnavailable(this.reason);

  final String reason;

  @override
  String toString() => 'TtsEngineUnavailable: $reason';
}

/// An on-device synthesizer that returns raw PCM for one sentence.
abstract class TtsEngine {
  /// Stable vendor/engine identifier, e.g. `sherpa-onnx`.
  String get id;

  /// Sample rate of [synthesize] output (may be model-dependent).
  int get sampleRate;

  /// Synthesize [text] into interleaved f32 samples in `[-1, 1]`.
  /// Implementations must not return fabricated audio.
  Future<Float32List> synthesize(String text);

  void dispose();
}

/// Configuration for [SherpaTtsEngine]: model files downloaded by the user,
/// with license verified per vendor before use.
class SherpaTtsConfig {
  const SherpaTtsConfig({
    required this.model,
    required this.tokens,
    this.lexicon = '',
    this.numThreads = 1,
    this.speakerId = 0,
    this.speed = 1.0,
  });

  /// Path to the VITS/Piper `.onnx` model file.
  final String model;

  /// Path to `tokens.txt`.
  final String tokens;

  /// Optional lexicon path (needed for some Piper VITS models).
  final String lexicon;

  final int numThreads;
  final int speakerId;
  final double speed;
}

/// PCM source backed by a sherpa-onnx `OfflineTts` instance.
///
/// Construction is lazy: [initialize] loads the native bindings and validates
/// model paths. [synthesize] calls `OfflineTts.generate`, wrapping the real
/// f32 buffer in a [MemoryPcmSource] for the RMS tap. No fake amplitudes.
class SherpaTtsEngine implements TtsEngine {
  SherpaTtsEngine({required this.config});

  final SherpaTtsConfig config;

  Object? _tts;
  int _sampleRate = 0;

  @override
  String get id => 'sherpa-onnx';

  @override
  int get sampleRate => _sampleRate;

  /// Load plugin/native bindings. Throws [TtsEngineUnavailable] with a clear
  /// reason when the dependency or model assets are absent.
  Future<void> initialize() async {
    try {
      // Optional dependency: importing the package through the normal URI
      // would fail at compile time when it is not in pubspec.yaml. Use a
      // runtime plugin lookup so the core app builds without sherpa-onnx.
      final loader = _SherpaLoader.lookup();
      if (loader == null) {
        throw const TtsEngineUnavailable(
          'sherpa_onnx package is not installed; add it to pubspec.yaml '
          'and provide downloaded model assets to enable Option B.',
        );
      }
      await loader.initBindings();
      final tts = loader.createOfflineTts(config);
      _tts = tts;
      _sampleRate = loader.sampleRate(tts);
      if (_sampleRate <= 0) {
        throw const TtsEngineUnavailable('engine reported no sample rate');
      }
    } on TtsEngineUnavailable {
      rethrow;
    } on Object catch (e) {
      throw TtsEngineUnavailable('failed to initialize sherpa-onnx: $e');
    }
  }

  @override
  Future<Float32List> synthesize(String text) async {
    final tts = _tts;
    if (tts == null) {
      throw const TtsEngineUnavailable('initialize() was not called');
    }
    final loader = _SherpaLoader.lookup();
    if (loader == null) {
      throw const TtsEngineUnavailable('sherpa_onnx plugin disappeared');
    }
    final audio = loader.generate(tts, text, config);
    if (audio.sampleRate <= 0 || audio.samples.isEmpty) {
      throw const TtsEngineUnavailable('synthesis produced no PCM');
    }
    _sampleRate = audio.sampleRate;
    return audio.samples;
  }

  /// Treat the synthesized buffer as a one-shot PCM source for the tap.
  Future<PcmSource> sourceFor(String text) async {
    final samples = await synthesize(text);
    return MemoryPcmSource(
      sampleRate: _sampleRate,
      channels: 1,
      samples: samples,
    );
  }

  @override
  void dispose() {
    final tts = _tts;
    if (tts != null) {
      _SherpaLoader.lookup()?.free(tts);
      _tts = null;
    }
    _sampleRate = 0;
  }
}

/// Pure data result from a synth: real decoded/generated samples plus rate.
class GeneratedPcm {
  const GeneratedPcm({required this.samples, required this.sampleRate});

  final Float32List samples;
  final int sampleRate;
}

/// Interface implemented by a thin adapter around `package:sherpa_onnx`.
/// Registered by the app at startup when the optional dependency is present.
abstract class SherpaLoader {
  Future<void> initBindings();
  Object createOfflineTts(SherpaTtsConfig config);
  int sampleRate(Object tts);
  GeneratedPcm generate(Object tts, String text, SherpaTtsConfig config);
  void free(Object tts);
}

/// Registry for the optional adapter. Kept separate from [SherpaTtsEngine] so
/// the core Flutter app compiles without adding the heavy native plugin to
/// pubspec.yaml in this environment.
class _SherpaLoader {
  static SherpaLoader? _loader;

  static void register(SherpaLoader loader) => _loader = loader;

  static SherpaLoader? lookup() => _loader;
}

/// Public registration hook for the optional sherpa-onnx adapter.
void registerSherpaLoader(SherpaLoader loader) =>
    _SherpaLoader.register(loader);
