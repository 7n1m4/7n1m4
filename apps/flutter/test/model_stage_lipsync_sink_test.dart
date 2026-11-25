// SPDX-License-Identifier: GPL-3.0-or-later

// Contract coverage for the generic scale/tint sink that consumes real,
// client-stamped LipSyncRmsData frames. Existing renderer coverage is in
// lipsync_renderer_test.dart; this test keeps the future model-stage input
// contract explicit without fabricating audio or model assets.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';
import 'package:anima_control/ui/lipsync_renderer.dart';

void main() {
  testWidgets('a stamped frame reaches the generic scale/tint sink', (tester) async {
    final controller = StreamController<LipSyncRmsData>();
    addTearDown(controller.close);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LipSyncRenderer(frames: controller.stream)),
    ));
    await tester.pump();
    expect(find.textContaining('No lip-sync frames'), findsOneWidget);

    controller.add(const LipSyncRmsData(
      actorId: 'pet-1',
      level: 0.75,
      seq: 0,
      tsMs: 1700000000123,
    ));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(tester.widget<AnimatedScale>(find.byKey(const Key('lip-sync-pet'))).scale,
        greaterThan(1.0));
    expect(find.textContaining('pet-1 · level 0.75 · seq 0'), findsOneWidget);
  });
}