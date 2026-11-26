// SPDX-License-Identifier: GPL-3.0-or-later

// App-level bridge from client-local TTS PCM to the observable renderer.
// A frame only exists when a real TtsEngine produced PCM and AmplitudeTap
// measured it; no daemon-published lip_sync.rms and no fabricated envelopes.

import 'dart:async';

import '../speech/speech.dart';

/// Feeds real TTS PCM through [LipSyncGenerator] and exposes the resulting
/// client-stamped frames to [LipSyncRenderer].
class LipSyncController {
  LipSyncController({
    required this.actorId,
    required this.engine,
  });

  final String actorId;
  final TtsEngine engine;
  AbortHandle? _abort;

  final StreamController<LipSyncRmsData> _frames =
      StreamController<LipSyncRmsData>.broadcast();

  /// Stamped frames for the renderer. The controller owns the stream; callers
  /// must not close it.
  Stream<LipSyncRmsData> get frames => _frames.stream;

  /// Synthesize [text] locally and stream its measured RMS frames.
  ///
  /// Throws [TtsEngineUnavailable] (or any engine failure) before emitting a
  /// frame when no real PCM is available: a missing model is loud, never
  /// silent fabrication.
  Future<void> speak(String text, {AbortHandle? abort}) async {
    final source = await engine.synthesizeToSource(text);
    await _drain(source, abort: abort);
  }

  /// Consume an already-produced PCM source (used by engines that own their
  /// own synthesis pipeline). Only real samples reach the tap.
  Future<void> feed(PcmSource source, {AbortHandle? abort}) =>
      _drain(source, abort: abort);

  Future<void> _drain(PcmSource source, {AbortHandle? abort}) async {
    _abort?.abort();
    final handle = abort ?? AbortHandle();
    _abort = handle;
    final generator = LipSyncGenerator(
      actorId: actorId,
      source: source,
      abort: handle,
    );
    try {
      await for (final frame in generator.frames()) {
        if (_frames.isClosed || !identical(_abort, handle)) break;
        _frames.add(frame);
      }
    } finally {
      if (identical(_abort, handle)) _abort = null;
    }
  }

  /// Abort the in-flight source: remaining PCM is drained as silence.
  void stop() => _abort?.abort();

  void dispose() {
    stop();
    _frames.close();
    engine.dispose();
  }
}
