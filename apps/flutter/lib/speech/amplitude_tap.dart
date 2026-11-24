// SPDX-License-Identifier: GPL-3.0-or-later

// Dart mirror of `crates/anima-speech/src/tap.rs`: a non-overlapping RMS tap
// over interleaved PCM samples at the source's own sample rate.
//
// The math is deliberately identical to the Rust reference:
//   window_samples = max(1, sample_rate * max(window_ms, 5) ~/ 1000)
//   level          = min(1.0, sqrt(sum(sample^2) / count))
// One frame per full window, one partial-tail flush at natural exhaustion,
// no frames while aborted, and at most one terminal `AmplitudeDone`.

import 'dart:math' as math;

import 'amplitude_frame.dart';
import 'pcm_source.dart';

/// Wraps a [PcmSource] and exposes its RMS envelope as a [Stream].
class AmplitudeTap {
  AmplitudeTap({
    required this.source,
    required this.abort,
    this.windowMs = 50,
  });

  final PcmSource source;
  final AbortHandle abort;

  /// Requested window length; values below 5 ms are clamped like tap.rs.
  final int windowMs;

  bool _done = false;

  /// True after the source has been fully drained and the terminal frame was
  /// produced (or suppressed because the tap was aborted).
  bool get isDone => _done;

  /// Lazily computes and emits one [AmplitudeLevel] per window.
  ///
  /// The stream completes after exactly one [AmplitudeDone] on natural end.
  /// An aborted tap emits no levels from the point of abort and no Done.
  Stream<AmplitudeFrame> run() async* {
    final windowSamples = math.max(
      1,
      source.sampleRate * math.max(windowMs, 5) ~/ 1000,
    );
    var acc = 0.0;
    var count = 0;

    await for (final sample in source.open()) {
      if (abort.isAborted) {
        // Drain without accumulating: "silence while aborted". Drop any
        // partial window so the tail flush cannot emit post-abort audio.
        acc = 0.0;
        count = 0;
        continue;
      }
      acc += sample * sample;
      count += 1;
      if (count >= windowSamples) {
        yield AmplitudeLevel(_level(acc, count));
        acc = 0.0;
        count = 0;
      }
    }

    if (_done) return;
    _done = true;
    if (abort.isAborted) return;

    // Partial-tail flush, then one terminal frame.
    if (count > 0) yield AmplitudeLevel(_level(acc, count));
    yield const AmplitudeDone();
  }

  static double _level(double sumOfSquares, int count) =>
      math.min(1.0, math.sqrt(sumOfSquares / count));
}
