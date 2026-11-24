// SPDX-License-Identifier: GPL-3.0-or-later
//
// Seam for client-local TTS PCM sources (airi-xpy). The primary path is an
// on-device Piper-class synth behind `TtsEngine`/`SherpaTtsEngine`; Option C
// audio-file playback with a PCM reader is the deterministic test harness
// (`WavPcmSource`). Everything downstream (AmplitudeTap) only depends on
// `PcmSource`, so swapping the source is a one-line change.

import 'dart:async';

/// Cancellation handle shared between a producer and the amplitude tap.
///
/// Mirrors the `abort: Arc<AtomicBool>` in `crates/anima-speech/src/tap.rs`:
/// once aborted the tap drains without accumulating and emits no terminal
/// [AmplitudeFrame.done].
class AbortHandle {
  bool _aborted = false;

  bool get isAborted => _aborted;

  void abort() => _aborted = true;
}

/// A source of interleaved PCM samples at a fixed sample rate.
///
/// Samples are `double` in `[-1, 1]` (f32 range). [open] may be called once;
/// re-opening is not required by the tap.
abstract class PcmSource {
  int get sampleRate;
  int get channels;
  Stream<double> open();
}

/// In-memory source, used by tests and by synth adapters that already hold a
/// decoded buffer.
class MemoryPcmSource implements PcmSource {
  MemoryPcmSource({
    required this.sampleRate,
    required this.channels,
    required List<double> samples,
  }) : _samples = List<double>.unmodifiable(samples);

  @override
  final int sampleRate;

  @override
  final int channels;

  final List<double> _samples;

  @override
  Stream<double> open() => Stream<double>.fromIterable(_samples);
}
