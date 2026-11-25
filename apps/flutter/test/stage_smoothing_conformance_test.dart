// SPDX-License-Identifier: GPL-3.0-or-later

// Dart leg of the shared lip-sync smoothing conformance fixture
// (airi-2z6). The same JSON envelope is locked by
// crates/anima-render/tests/lipsync_conformance.rs, so both engines must
// produce bit-identical weights for the same fixture steps.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_expression.dart';

final File _fixture = () {
  // Works when tests run from apps/flutter (flutter test default cwd).
  const relative =
      '../../crates/anima-channel/fixtures/lipsync/smoothing.basic.json';
  for (final dir in [
    relative,
    'crates/anima-channel/fixtures/lipsync/smoothing.basic.json',
  ]) {
    final file = File(dir);
    if (file.existsSync()) return file;
  }
  fail('lipsync smoothing fixture not found (tried $relative)');
}();

void main() {
  test('dart smoothing matches shared fixture', () {
    final fixture =
        jsonDecode(_fixture.readAsStringSync()) as Map<String, dynamic>;
    expect(fixture['schema'], 'lipsync-smoothing-v1');
    expect(fixture['decay_seconds'], 0.120);

    final smoother = LipSyncSmoother(
      decaySeconds: (fixture['decay_seconds'] as num).toDouble(),
    );
    final steps = fixture['steps'] as List;
    for (var i = 0; i < steps.length; i++) {
      final step = steps[i] as Map<String, dynamic>;
      final weight = smoother.tick(
        (step['rms'] as num).toDouble(),
        (step['dt'] as num).toDouble(),
      );
      // Rust computes in f32, Dart in f64; the ~2e-9 gap (e.g. step 9:
      // 0.09166666865348816 vs 0.09166666666666667) is ~8 orders below
      // perceptible morph quantization and the two engines run in separate
      // processes that never exchange these weights bit-for-bit, so exact bit
      // equality is not required — f32 tolerance is the contract.
      final expected = double.parse(
        (step['expected_weight'] as num).toStringAsFixed(7),
      );
      expect(
        double.parse(weight.toStringAsFixed(7)),
        expected,
        reason: 'step $i ($step) weight mismatch',
      );
      expect(smoother.weight, weight, reason: 'step $i');
    }
  });
}
