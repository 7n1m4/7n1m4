// SPDX-License-Identifier: GPL-3.0-or-later

// Contract coverage for the existing pure client-local lip-sync seam.
// A future model stage must consume these same stamped frames; it must not
// fabricate a model, an asset, or replacement frames when that seam is absent.

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';

void main() {
  test('model-stage input remains a stamped LipSyncRmsData frame', () {
    const frame = LipSyncRmsData(
      actorId: 'pet-1',
      level: 0.75,
      seq: 7,
      tsMs: 1700000000123,
    );

    expect(frame.toJson(), <String, dynamic>{
      'actor_id': 'pet-1',
      'level': 0.75,
      'seq': 7,
      'ts_ms': 1700000000123,
    });
    expect(LipSyncRmsData.fromJson(frame.toJson()).toString(), frame.toString());
  });
}