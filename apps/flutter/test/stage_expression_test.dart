// SPDX-License-Identifier: GPL-3.0-or-later

// Golden-style conformance for the client-local cue mapping ported from
// crates/anima-render: fast attack, 120 ms linear decay, and strict parsing of
// daemon emotion.tag payloads so malformed/wrong-actor frames cannot spoof cues.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_expression.dart';

void main() {
  group('LipSyncSmoother', () {
    test('attack snaps to the sample and decay reaches silence', () {
      final smoother = LipSyncSmoother();
      expect(smoother.tick(0.8, 1 / 30), 0.8);
      expect(smoother.tick(0.0, 1 / 30), closeTo(0.8 - 1 / 30 / 0.12, 1e-9));
      for (var i = 0; i < 30; i++) {
        smoother.tick(0.0, 1 / 30);
      }
      expect(smoother.weight, 0.0);
    });

    test('samples are clamped and non-finite values are ignored', () {
      final smoother = LipSyncSmoother();
      expect(smoother.tick(2.5, 1 / 30), 1.0);
      expect(smoother.tick(-1.0, 1 / 30), closeTo(1.0 - 1 / 30 / 0.12, 1e-9));
      expect(
        smoother.tick(double.nan, 1 / 30),
        closeTo(1.0 - 2 * (1 / 30 / 0.12), 1e-9),
      );
      smoother.reset();
      expect(smoother.weight, 0.0);
    });
  });

  group('parseExpressionCue', () {
    Map<String, dynamic> payload({
      Object tag = 'happy',
      Object kind = 'emotion',
      Object intensity = 0.8,
      Object actorId = 'pet-1',
      Object seq = 7,
      Object tsMs = 1700000000123,
    }) => <String, dynamic>{
      'tag': tag,
      'kind': kind,
      'intensity': intensity,
      'actor_id': actorId,
      'seq': seq,
      'ts_ms': tsMs,
    };

    test('a valid emotion payload parses with clamped intensity', () {
      final cue = parseExpressionCue(payload(intensity: 1.4));
      expect(cue, isNotNull);
      expect(cue!.tag, 'happy');
      expect(cue.intensity, 1.0);
      expect(cue.isMotion, isFalse);
      expect(cue.seq, 7);
    });

    test('a motion cue is distinguished from an emotion', () {
      final cue = parseExpressionCue(payload(kind: 'motion', tag: 'wave'));
      expect(cue!.isMotion, isTrue);
      expect(cue.tag, 'wave');
    });

    test('wrong-actor and malformed frames are ignored', () {
      expect(parseExpressionCue(payload(), actorId: 'other'), isNull);
      expect(parseExpressionCue(payload(tag: '')), isNull);
      expect(parseExpressionCue(payload(kind: 'vfx')), isNull);
      expect(parseExpressionCue(payload(intensity: 'high')), isNull);
      expect(parseExpressionCue(payload(seq: '7')), isNull);
      expect(parseExpressionCue(payload(tsMs: '123')), isNull);
    });
  });
}
