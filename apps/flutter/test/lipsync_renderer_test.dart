// SPDX-License-Identifier: GPL-3.0-or-later

// airi-ikp: observable Flutter renderer for client-stamped lip_sync.rms frames.
// Frames originate in LipSyncGenerator (real PCM through AmplitudeTap), never
// from daemon-published events and never from fabricated RMS values.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/app.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';
import 'package:anima_control/ui/lipsync_renderer.dart';

/// Deterministic real WAVE asset (Option C harness) for the controller path.
Uint8List _wav16({required int sampleRate, required List<int> samples}) {
  final dataLength = samples.length * 2;
  final bytes = Uint8List(44 + dataLength);
  final view = ByteData.sublistView(bytes);
  void ascii(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      bytes[offset + i] = text.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  view.setUint32(4, 36 + dataLength, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  view.setUint32(16, 16, Endian.little);
  view.setUint16(20, 1, Endian.little);
  view.setUint16(22, 1, Endian.little);
  view.setUint32(24, sampleRate, Endian.little);
  view.setUint32(28, sampleRate * 2, Endian.little);
  view.setUint16(32, 2, Endian.little);
  view.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  view.setUint32(40, dataLength, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    view.setInt16(44 + i * 2, samples[i], Endian.little);
  }
  return bytes;
}

class _WavEngine implements TtsEngine {
  _WavEngine(this.bytes);

  final Uint8List bytes;

  @override
  String get id => 'option-c-wav';

  @override
  int get sampleRate => 100;

  @override
  Future<PcmSource> synthesizeToSource(String text) async =>
      WavPcmSource.fromBytes(bytes);

  @override
  Future<Float32List> synthesize(String text) async =>
      throw UnsupportedError('use synthesizeToSource');

  @override
  void dispose() {}
}

void main() {
  testWidgets('stamped LipSyncRmsData frames visibly resize the pet renderer',
      (tester) async {
    final now = DateTime.fromMillisecondsSinceEpoch(1700000000123);
    final generator = LipSyncGenerator(
      actorId: 'pet-1',
      source: MemoryPcmSource(
        sampleRate: 100,
        channels: 1,
        // 100 Hz / 50 ms => 5 samples per window: exactly one full window.
        samples: List<double>.filled(5, 0.8),
      ),
      abort: AbortHandle(),
      windowMs: 50,
      now: () => now,
    );
    final frames = await generator.frames().toList();
    expect(frames.single.level, closeTo(0.8, 1e-12));
    expect(frames.single.seq, 0);
    expect(frames.single.tsMs, 1700000000123);

    final controller = StreamController<LipSyncRmsData>();
    addTearDown(controller.close);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LipSyncRenderer(frames: controller.stream)),
    ));
    await tester.pump();

    final finder = find.byKey(const Key('lip-sync-pet'));
    expect(tester.widget<AnimatedScale>(finder).scale, 1.0,
        reason: 'renderer starts at rest before frames');
    expect(find.textContaining('No lip-sync frames'), findsOneWidget);

    controller.add(frames.single);
    await tester.pump();
    await tester.pumpAndSettle();
    expect(tester.widget<AnimatedScale>(finder).scale, greaterThan(1.0),
        reason: 'a loud stamped frame visibly enlarges the pet');
    expect(find.textContaining('seq 0'), findsOneWidget);
    expect(find.textContaining('1700000000123'), findsOneWidget);
  });

  testWidgets('app controller feeds real WAV PCM frames into the renderer',
      (tester) async {
    final controller = LipSyncController(
      actorId: 'pet',
      engine: _WavEngine(_wav16(
        sampleRate: 100,
        // 16-bit PCM at half full scale -> RMS ~= 0.5, one full window.
        samples: List<int>.filled(5, 16384),
      )),
    );
    addTearDown(controller.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: LipSyncRenderer(frames: controller.frames)),
    ));
    await tester.pump();
    expect(find.textContaining('No lip-sync frames'), findsOneWidget);

    await controller.speak('real audio');
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.textContaining('pet · level 0.50 · seq 0'), findsOneWidget);
    expect(tester.widget<AnimatedScale>(find.byKey(const Key('lip-sync-pet'))).scale,
        greaterThan(1.0));
  });

  testWidgets('AnimaApp mounts the renderer supplied at app entry',
      (tester) async {
    final stream = StreamController<LipSyncRmsData>();
    addTearDown(stream.close);
    final client = DaemonClient();
    addTearDown(client.dispose);

    await tester.pumpWidget(AnimaApp(
      client: client,
      lipSync: LipSyncRenderer(frames: stream.stream),
    ));
    await tester.pump();

    expect(find.byKey(const Key('lip-sync-pet')), findsOneWidget);
  });
}
