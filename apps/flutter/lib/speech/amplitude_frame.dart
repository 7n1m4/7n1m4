// SPDX-License-Identifier: GPL-3.0-or-later

/// One output frame of the client-local amplitude tap.
///
/// Mirrors the two `SpeechEvent` variants emitted by
/// `crates/anima-speech/src/tap.rs`: `Amplitude { level }` and `Done {}`.
/// A tap stream emits any number of [AmplitudeLevel] frames followed by
/// exactly one [AmplitudeDone] frame on natural completion (no Done when
/// aborted).
sealed class AmplitudeFrame {
  const AmplitudeFrame();
}

/// RMS of one window of PCM samples, clamped to `[0, 1]`.
class AmplitudeLevel extends AmplitudeFrame {
  const AmplitudeLevel(this.level);

  final double level;

  @override
  String toString() => 'AmplitudeLevel($level)';
}

/// Terminal frame: the PCM source was exhausted without being aborted.
class AmplitudeDone extends AmplitudeFrame {
  const AmplitudeDone();

  @override
  String toString() => 'AmplitudeDone()';
}
