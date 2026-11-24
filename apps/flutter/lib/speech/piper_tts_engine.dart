// SPDX-License-Identifier: GPL-3.0-or-later

// Option B (ratified primary path): on-device Piper TTS via a locally
// installed `piper` executable. The CLI reads the spoken text from stdin and
// writes a real WAVE file to --output_file; that file is decoded in-process
// by [WavPcmSource] before it reaches the RMS tap. No binary or model is
// committed: the user installs the binary and downloads a voice asset.
// See docs/decision-client-local-tts-pcm.md for the decision.
//
// Setup (outside the repo):
//   - Install piper: https://github.com/rhasspy/piper/releases
//   - Download a voice: https://huggingface.co/rhasspy/piper-voices
//     e.g. en_US-lessac-medium.onnx + en_US-lessac-medium.onnx.json
//   - Set PIPER_MODEL to the .onnx path (or pass modelPath to the engine).
//   - Optionally set PIPER_PATH to the binary (default: `piper` on PATH).

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'pcm_source.dart';
import 'sherpa_tts_engine.dart';
import 'wav_pcm_source.dart';

/// A completed local TTS process result. [stdinText] records the exact bytes
/// piped to the process so tests can assert the text path without fabricating
/// PCM; the real runner returns what was actually written.
class PiperProcessResult {
  const PiperProcessResult(
    this.exitCode,
    this.stderr, {
    this.stdinText = '',
  });

  final int exitCode;
  final String stderr;
  final String stdinText;
}

/// A real on-device Piper synthesizer backed by a local CLI executable.
///
/// Piper writes an actual WAVE file; [synthesizeToSource] decodes it with
/// [WavPcmSource]. No synthetic or fabricated PCM is ever produced. An
/// unavailable binary/model raises [TtsEngineUnavailable] so callers can fall
/// back to an explicitly supplied real WAVE asset (Option C harness).
class PiperTtsEngine implements TtsEngine {
  PiperTtsEngine({
    String? executable,
    String? modelPath,
    this.workingDirectory,
    Future<PiperProcessResult> Function(
      String executable,
      List<String> arguments,
      String text, {
      String? workingDirectory,
    })? processRunner,
  })  : executable = executable ?? _fromEnv('PIPER_PATH') ?? 'piper',
        modelPath = modelPath ?? _fromEnv('PIPER_MODEL') ?? '',
        _processRunner = processRunner ?? _defaultProcessRunner,
        _usesRealProcess = processRunner == null;

  /// Piper binary path, from `PIPER_PATH` or `piper` on PATH.
  final String executable;

  /// Downloaded `.onnx` voice model path (`PIPER_MODEL` env by default).
  final String modelPath;

  /// Optional working directory for the child process.
  final Directory? workingDirectory;

  final Future<PiperProcessResult> Function(
    String executable,
    List<String> arguments,
    String text, {
    String? workingDirectory,
  }) _processRunner;

  /// True only when the real OS process is spawned; asset validation must not
  /// be faked out by an injected test runner.
  final bool _usesRealProcess;

  int _sampleRate = 0;

  static String? _fromEnv(String name) {
    final value = Platform.environment[name];
    if (value == null || value.trim().isEmpty) return null;
    return value;
  }

  static Future<PiperProcessResult> _defaultProcessRunner(
    String executable,
    List<String> arguments,
    String text, {
    String? workingDirectory,
  }) async {
    final process = await Process.start(
      executable,
      arguments,
      workingDirectory: workingDirectory,
    );
    process.stdin.add(utf8.encode(text));
    await process.stdin.close();
    // Drain both pipes: piper logs progress to stderr, and an undrained
    // stdout pipe can stall a process that writes to it.
    final stdoutFuture = process.stdout.drain();
    final stderr = await utf8.decoder.bind(process.stderr).join();
    await stdoutFuture;
    final exitCode = await process.exitCode;
    return PiperProcessResult(
      exitCode,
      stderr,
      stdinText: text,
    );
  }

  /// Canonical piper CLI: text arrives on stdin, never as a positional arg.
  static List<String> _arguments(String modelPath, String outputPath) =>
      <String>[
        '--model',
        modelPath,
        '--output_file',
        outputPath,
      ];

  @override
  String get id => 'piper';

  @override
  int get sampleRate => _sampleRate;

  /// Verify that the binary and the downloaded model file are present before
  /// any synthesis attempt.
  Future<void> initialize() async {
    if (executable.trim().isEmpty) {
      throw const TtsEngineUnavailable('piper executable path is empty');
    }
    if (modelPath.trim().isEmpty) {
      throw const TtsEngineUnavailable(
        'Piper model is missing; download a voice from '
        'https://huggingface.co/rhasspy/piper-voices and set PIPER_MODEL.',
      );
    }
    final model = File(modelPath);
    if (!await model.exists()) {
      throw TtsEngineUnavailable('piper model file not found: $modelPath');
    }
    if (_usesRealProcess) {
      final resolved = await _resolveExecutable(executable);
      if (resolved == null) {
        throw TtsEngineUnavailable('piper executable not found: $executable');
      }
    }
  }

  Future<String?> _resolveExecutable(String name) async {
    if (name.contains(Platform.pathSeparator) || name.contains('/')) {
      final file = File(name);
      return await file.exists() ? file.path : null;
    }
    final pathValue = Platform.environment['PATH'] ?? '';
    for (final segment in pathValue.split(Platform.pathSeparator)) {
      if (segment.isEmpty) continue;
      final candidate = File('$segment${Platform.pathSeparator}$name');
      if (await candidate.exists()) return candidate.path;
    }
    return null;
  }

  @override
  Future<PcmSource> synthesizeToSource(String text) async {
    if (text.trim().isEmpty) {
      throw const TtsEngineUnavailable('text must not be empty');
    }
    await initialize();

    final tempDir = await Directory.systemTemp.createTemp('anima-piper-');
    final output = File('${tempDir.path}${Platform.pathSeparator}speech.wav');
    try {
      final result = await _processRunner(
        executable,
        _arguments(modelPath, output.path),
        text,
        workingDirectory: workingDirectory?.path,
      );
      if (result.exitCode != 0) {
        throw TtsEngineUnavailable(
          'piper exited ${result.exitCode}: ${result.stderr}',
        );
      }
      if (result.stdinText != text) {
        throw const TtsEngineUnavailable(
          'piper process did not receive the full text on stdin',
        );
      }
      if (!await output.exists()) {
        throw const TtsEngineUnavailable('piper produced no WAVE output');
      }
      final source = WavPcmSource.fromBytes(await output.readAsBytes());
      _sampleRate = source.sampleRate;
      return source;
    } on FormatException catch (e) {
      throw TtsEngineUnavailable('piper produced an invalid WAVE file: $e');
    } on ProcessException catch (e) {
      throw TtsEngineUnavailable('failed to run piper: $e');
    } finally {
      try {
        await tempDir.delete(recursive: true);
      } on Object {
        // Best-effort cleanup; temp data is non-sensitive and OS-cleaned.
      }
    }
  }

  @override
  Future<Float32List> synthesize(String text) async {
    final source = await synthesizeToSource(text);
    final samples = <double>[];
    await for (final sample in source.open()) {
      samples.add(sample);
    }
    return Float32List.fromList(samples);
  }

  @override
  void dispose() {
    _sampleRate = 0;
  }
}
