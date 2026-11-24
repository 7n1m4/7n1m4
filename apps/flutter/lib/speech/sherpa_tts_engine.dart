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

  /// Sample rate of [synthesize] output (may be model-dependent). Zero until
  /// the engine is initialized or the first synthesis succeeds.
  int get sampleRate;

  /// Synthesize [text] into interleaved f32 samples in `[-1, 1]`.
  /// Implementations must not return fabricated audio.
  Future<Float32List> synthesize(String text);

  /// Synthesize [text] as a one-shot [PcmSource] for the RMS tap.
  ///
  /// Default wraps the real samples from [synthesize]; engines that already
  /// hold a decoded WAVE buffer may override this to stream it directly.
  Future<PcmSource> synthesizeToSource(String text) async {
    final samples = await synthesize(text);
    return MemoryPcmSource(
      sampleRate: sampleRate,
      channels: 1,
      samples: samples,
    );
  }

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
  SherpaTtsEngine({required this.config, this.loader});

  final SherpaTtsConfig config;

  /// Optional adapter injected for tests; otherwise resolved from the public
  /// [SherpaLoaderRegistry] when [initialize] runs, so app startup order does
  /// not matter.
  final SherpaLoader? loader;

  SherpaLoader? _activeLoader;
  Object? _tts;
  int _sampleRate = 0;

  @override
  String get id => 'sherpa-onnx';

  @override
  int get sampleRate => _sampleRate;

  /// Load plugin/native bindings. Throws [TtsEngineUnavailable] with a clear
  /// reason when the dependency or model assets are absent.
  Future<void> initialize() async {
    final adapter = loader ?? sherpaLoader;
    if (adapter == null) {
      throw const TtsEngineUnavailable(
        'sherpa_onnx package is not installed; add it to pubspec.yaml '
        'and provide downloaded model assets to enable Option B.',
      );
    }
    try {
      await adapter.initBindings();
      final tts = adapter.createOfflineTts(config);
      _tts = tts;
      _activeLoader = adapter;
      _sampleRate = adapter.sampleRate(tts);
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
    final adapter = _activeLoader;
    if (tts == null || adapter == null) {
      throw const TtsEngineUnavailable('initialize() was not called');
    }
    final audio = adapter.generate(tts, text, config);
    if (audio.sampleRate <= 0 || audio.samples.isEmpty) {
      throw const TtsEngineUnavailable('synthesis produced no PCM');
    }
    _sampleRate = audio.sampleRate;
    return audio.samples;
  }

  /// Treat the synthesized buffer as a one-shot PCM source for the tap.
  Future<PcmSource> sourceFor(String text) => synthesizeToSource(text);

  @override
  Future<PcmSource> synthesizeToSource(String text) async {
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
      _activeLoader?.free(tts);
      _tts = null;
    }
    _activeLoader = null;
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

/// Durable process-wide registry for the optional sherpa-onnx adapter.
/// Separate from [SherpaTtsEngine] so the core Flutter app compiles without
/// adding the heavy native plugin to pubspec.yaml.
class SherpaLoaderRegistry {
  SherpaLoaderRegistry._();

  static final SherpaLoaderRegistry instance = SherpaLoaderRegistry._();

  SherpaLoader? _loader;

  void register(SherpaLoader loader) => _loader = loader;

  SherpaLoader? lookup() => _loader;

  /// Test-only reset; production code registers exactly once at startup.
  void clear() => _loader = null;
}

/// Currently registered adapter, if any.
SherpaLoader? get sherpaLoader => SherpaLoaderRegistry.instance.lookup();

/// Public registration hook for the optional sherpa-onnx adapter.
void registerSherpaLoader(SherpaLoader loader) =>
    SherpaLoaderRegistry.instance.register(loader);
