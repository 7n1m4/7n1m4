// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local mirror of `LipSyncRmsData` in
// crates/anima-channel/src/wire.rs. Wire keys are intentionally identical so a
// locally generated frame can be decoded by the same codec as a daemon frame
// (golden-fixture conformance in test/golden_fixtures_test.dart). Stamp seq /
// ts_ms locally: the daemon bus only stamps events it publishes itself and
// `lip_sync.rms` is explicitly client-generated (decision-bridge-scope.md:24).

/// One client-generated `lip_sync.rms` amplitude sample.
class LipSyncRmsData {
  const LipSyncRmsData({
    required this.actorId,
    required this.level,
    required this.seq,
    required this.tsMs,
  });

  /// Character/actor id the sample belongs to.
  final String actorId;

  /// RMS level in `[0, 1]`, already clamped by [AmplitudeTap].
  final double level;

  /// Monotonic client-stamped publication sequence.
  final int seq;

  /// Unix epoch milliseconds, stamped by the client generator.
  final int tsMs;

  factory LipSyncRmsData.fromJson(Map<String, dynamic> json) {
    return LipSyncRmsData(
      actorId: json['actor_id'] as String,
      level: (json['level'] as num).toDouble(),
      seq: (json['seq'] as num).toInt(),
      tsMs: (json['ts_ms'] as num).toInt(),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'actor_id': actorId,
        'level': level,
        'seq': seq,
        'ts_ms': tsMs,
      };

  @override
  String toString() =>
      'LipSyncRmsData(actorId: $actorId, level: $level, seq: $seq, tsMs: $tsMs)';
}
