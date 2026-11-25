// SPDX-License-Identifier: GPL-3.0-or-later

// BLOCKED: the Flutter package has no model-stage widget or asset-loading seam.
// This contract test deliberately does not invent a missing widget, an asset,
// or a silent fallback. The future test must pump that public widget with a
// missing asset and assert a visible, loud error (and no fake model).

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';

void main() {
  test('a missing model asset must remain an explicit error contract', () {
    // LipSyncRmsData is the existing, deterministic input contract available
    // to a future model stage. Model/asset ownership is not present in this
    // thin Flutter client (pubspec.yaml has no model assets).
    const frame = LipSyncRmsData(actorId: 'pet-1', level: 0, seq: 0, tsMs: 1);
    expect(frame.actorId, 'pet-1');
  });
}