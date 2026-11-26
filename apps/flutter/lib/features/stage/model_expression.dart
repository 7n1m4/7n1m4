// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local cue mapping for the native stage. Mirrors the semantics of
// crates/anima-render/src/vrm/lipsync.rs and expression.rs: fast attack,
// exponential decay, and additive expression cues where unmanaged morphs
// (blink, lip-sync) are never zeroed by an emotion switch.

/// One semantic expression or motion cue from the daemon's `emotion.tag` lane.
class StageExpressionCue {
  const StageExpressionCue({
    required this.tag,
    required this.kind,
    required this.intensity,
    required this.actorId,
    required this.seq,
    required this.tsMs,
  });

  final String tag;
  final String kind;
  final double intensity;
  final String actorId;
  final int seq;
  final int tsMs;

  /// Whether the cue drives a body/visual-effect channel rather than a facial
  /// expression (`crates/anima-channel/src/wire.rs` `CueKind`). Neither one
  /// may be mapped to a morph by a renderer.
  bool get isNonFacial => kind == 'motion' || kind == 'vfx';

  bool get isMotion => kind == 'motion';

  @override
  String toString() => 'StageExpressionCue($kind:$tag @ $intensity, seq $seq)';
}

/// Parses an `emotion.tag` event payload. Returns null for malformed frames or
/// frames aimed at another actor, so junk on the right topic cannot spoof a
/// cue (matching the chat surface's emotion-cue contract).
StageExpressionCue? parseExpressionCue(
  Map<String, dynamic> data, {
  String? actorId,
}) {
  final tag = data['tag'];
  final kind = data['kind'];
  final intensity = data['intensity'];
  final actor = data['actor_id'];
  final seq = data['seq'];
  final ts = data['ts_ms'];
  if (tag is! String || tag.trim().isEmpty) return null;
  // `motion` and `vfx` are real cue kinds on this lane, not facial morphs.
  if (kind is! String ||
      !const <String>{'emotion', 'motion', 'vfx'}.contains(kind)) {
    return null;
  }
  if (intensity is! num) return null;
  if (seq is! int || ts is! int) return null;
  if (actorId != null && actor != actorId) return null;
  final value = intensity.toDouble();
  if (!value.isFinite) return null;
  return StageExpressionCue(
    tag: tag,
    kind: kind,
    intensity: value.clamp(0.0, 1.0),
    actorId: actor is String ? actor : '',
    seq: seq,
    tsMs: ts,
  );
}

/// Smooths an RMS amplitude into a mouth-open weight.
///
/// Ported from `crates/anima-render/src/vrm/lipsync.rs`: attack snaps to the
/// sample, decay is linear at ~120 ms to zero (the Rust engine's dt/0.120).
/// Out-of-range samples are clamped, never throw.
class LipSyncSmoother {
  LipSyncSmoother({this.decaySeconds = 0.120});

  final double decaySeconds;
  double _weight = 0;

  double get weight => _weight;

  /// Advance by [dtSeconds] with a fresh RMS [level].
  double tick(double level, double dtSeconds) {
    final target = level.isFinite ? level.clamp(0.0, 1.0) : 0.0;
    final dt = dtSeconds.isFinite && dtSeconds > 0 ? dtSeconds : 0.0;
    if (target > _weight) {
      _weight = target;
    } else if (decaySeconds > 0) {
      _weight = (_weight - dt / decaySeconds).clamp(target, 1.0);
    }
    return _weight;
  }

  void reset() => _weight = 0;
}
