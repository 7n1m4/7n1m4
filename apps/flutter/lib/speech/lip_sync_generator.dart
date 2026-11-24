// SPDX-License-Identifier: GPL-3.0-or-later

// Bridges the local PCM tap to the existing `LipSyncRmsData` wire shape.
// Flutter has no renderer (decision-client-local-tts-pcm.md §9.2), so this
// generator exposes the RMS stream + event frames for consumers/tests rather
// than pushing into a renderer.

import 'dart:async';

import 'amplitude_frame.dart';
import 'amplitude_tap.dart';
import 'lip_sync_rms_data.dart';
import 'pcm_source.dart';

/// Converts a [PcmSource]'s amplitude frames into client-stamped
/// [LipSyncRmsData] frames. One output frame per amplitude window, no output
/// for [AmplitudeDone] (the stream simply completes).
class LipSyncGenerator {
  LipSyncGenerator({
    required this.actorId,
    required PcmSource source,
    required AbortHandle abort,
    this.windowMs = 50,
    DateTime Function()? now,
  })  : _tap = AmplitudeTap(source: source, abort: abort, windowMs: windowMs),
        _now = now ?? DateTime.now;

  final String actorId;
  final int windowMs;
  final AmplitudeTap _tap;
  final DateTime Function() _now;

  int _seq = 0;

  /// Start (or restart) the stream. A generator keeps its seq counter across
  /// restarts so frames stay monotonic for the actor.
  Stream<LipSyncRmsData> frames() async* {
    await for (final frame in _tap.run()) {
      final level = switch (frame) {
        AmplitudeLevel(:final double level) => level,
        AmplitudeDone() => null,
      };
      if (level == null) continue;
      yield LipSyncRmsData(
        actorId: actorId,
        level: level,
        seq: _seq++,
        tsMs: _now().millisecondsSinceEpoch,
      );
    }
  }
}
