// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local atmosphere parity coverage: the Vue preset catalog is copied
// verbatim, particle geometry is a pure function of preset/index/elapsed, and
// the unpainter-safe `none` preset draws nothing. No daemon data is invented.

import 'dart:ui' as ui;

import 'package:anima_control/features/stage/stage_atmosphere.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_overlays.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/fakes.dart';

void main() {
  group('atmosphere preset metadata', () {
    test('catalog ids, labels and order match the Vue reference', () {
      expect(kAtmospherePresets.map((preset) => preset.id).toList(), <String>[
        'none',
        'hearts',
        'petals',
        'stars',
        'bubbles',
        'crosses',
        'notes',
      ]);
      expect(kAtmospherePresets.map((preset) => preset.name).toList(), <String>[
        'None',
        'Hearts',
        'Sakura',
        'Stars',
        'Bubbles',
        'Crosses',
        'Melody',
      ]);
    });

    test('descriptions and icons are copied, not invented', () {
      expect(
        kAtmospherePresets.first.description,
        'Clean and static with no moving particles',
      );
      expect(
        atmosphereMeta(StageAtmosphere.petals).description,
        'Soft pink cherry blossom petals drifting with the wind',
      );
      expect(atmosphereMeta(StageAtmosphere.notes).name, 'Melody');
      expect(
        atmosphereMeta(StageAtmosphere.hearts).icon,
        'i-solar:heart-bold-duotone',
      );
    });

    test('store ids round-trip and unknown ids are rejected', () {
      for (final preset in StageAtmosphere.values) {
        expect(atmosphereFromId(atmosphereId(preset)), preset);
        expect(atmosphereMeta(preset).id, atmosphereId(preset));
      }
      expect(atmosphereFromId('lava'), isNull);
      expect(atmosphereFromId(null), isNull);
    });

    testWidgets('the selector reports intent using the reference labels', (
      tester,
    ) async {
      StageAtmosphere? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageAtmosphereSelector(
              selected: StageAtmosphere.none,
              onChanged: (preset) => chosen = preset,
            ),
          ),
        ),
      );
      expect(find.text('Sakura'), findsOneWidget);
      expect(find.text('Melody'), findsOneWidget);
      await tester.tap(find.text('Sakura'));
      expect(chosen, StageAtmosphere.petals);
    });
  });

  group('particle geometry', () {
    const size = ui.Size(300, 200);

    test('none has no particles and a zero offset', () {
      expect(
        atmosphereParticlePosition(
          StageAtmosphere.none,
          3,
          const Duration(seconds: 4),
          size,
        ),
        ui.Offset.zero,
      );
    });

    test('positions derive from preset, index and elapsed time only', () {
      final first = atmosphereParticlePosition(
        StageAtmosphere.hearts,
        4,
        const Duration(seconds: 2),
        size,
      );
      final replay = atmosphereParticlePosition(
        StageAtmosphere.hearts,
        4,
        const Duration(seconds: 2),
        size,
      );
      expect(replay, first);
      final later = atmosphereParticlePosition(
        StageAtmosphere.hearts,
        4,
        const Duration(seconds: 3),
        size,
      );
      expect(later, isNot(first));
      expect(first.dx, greaterThanOrEqualTo(0));
      expect(first.dx, lessThanOrEqualTo(size.width));
      expect(first.dy, greaterThanOrEqualTo(0));
      expect(first.dy, lessThanOrEqualTo(size.height));
    });

    test('the none painter is safe on a zero and a real canvas', () {
      const painter = StageAtmospherePainter(
        preset: StageAtmosphere.none,
        elapsed: Duration(seconds: 1),
      );
      final recorder = ui.PictureRecorder();
      final canvas = ui.Canvas(recorder);
      painter.paint(canvas, ui.Size.zero);
      painter.paint(canvas, size);
      recorder.endRecording().dispose();
    });
  });

  group('stage shell wiring', () {
    testWidgets('the shell picker drives the shared render state', (tester) async {
      final client = FakeChatClient();
      final state = StageRenderState();
      addTearDown(client.dispose);
      addTearDown(state.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: StageScreen(client: client, render: state)),
        ),
      );
      await tester.pump();
      expect(state.atmosphere, StageAtmosphere.none);

      await tester.tap(find.text('Sakura'));
      await tester.pump();
      expect(state.atmosphere, StageAtmosphere.petals);
    });
  });
}
