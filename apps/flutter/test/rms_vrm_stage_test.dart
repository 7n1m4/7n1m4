// SPDX-License-Identifier: GPL-3.0-or-later

// airi-n5vd: the VRM `aa` mouth channel must follow REAL RMS frames produced
// by the speech/TTS sink (`LipSyncController` → `LipSyncGenerator` →
// `AmplitudeTap`), not only synthetic `set_lip_sync` calls, and the additive
// safety contract (blink + lip-sync survive an emotion switch) must still hold.
//
// The PCM is a real deterministic 16-bit WAVE sine (a loud window followed by
// a silent one), decoded by `WavPcmSource` and measured by the production tap
// and generator. A recording backend stands in for the native VRM renderer so
// the exact `setLipSync` weights (the `aa` channel) are observable without a
// GPU.

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/speech/speech.dart';
import 'package:anima_control/ui/lip_sync_controller.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

/// Deterministic 16-bit mono WAVE: 100 Hz, 5 samples per 50 ms window.
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

/// A 16-bit sine window at [amplitude] full scale (peak ~32767 * amplitude).
List<int> _sineWindow({required double amplitude, int samples = 5}) {
  return List<int>.generate(
    samples,
    (i) => (math.sin(2 * math.pi * i / samples) * 32767 * amplitude).round(),
    growable: false,
  );
}

/// TTS engine that returns a real PCM WAVE source (Option C harness).
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

Map<String, dynamic> _cardWith(Map<String, dynamic> airi) => <String, dynamic>{
  'spec': 'chara_card_v3',
  'data': <String, dynamic>{
    'name': 'RMS Card',
    'extensions': <String, dynamic>{'airi': airi},
  },
};

class InMemoryResolver extends ModelAssetResolver {
  InMemoryResolver(this.asset) : super(cacheDirectory: Directory.systemTemp);
  final File asset;
  @override
  Future<ResolvedModelAsset> resolve(DisplayModel model) async =>
      ResolvedModelAsset(
        path: asset.absolute.path,
        source: 'file',
        originalValue: asset.path,
        fingerprint: 'synthetic',
        byteLength: 3,
      );
}

void main() {
  late Directory temp;
  late File asset;
  late FakeChatClient client;
  late RecordingModelBackend backend;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('rms-vrm-test-');
    asset = File('${temp.path}${Platform.pathSeparator}model.vrm')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    client = FakeChatClient();
    backend = RecordingModelBackend(ModelKind.vrm);
  });

  tearDown(() async {
    client.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> pumpStage(
    WidgetTester tester,
    LipSyncController controller,
  ) async {
    client.onCall = (action, payload) => RpcReply(
      action: action,
      ok: true,
      data: <String, dynamic>{
        'card': _cardWith(<String, dynamic>{
          'vrm': <String, dynamic>{'source': 'file', 'file': asset.path},
        }),
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageScreen(
            backends: ModelBackendRegistry(<ModelKind, ModelBackend>{
              ModelKind.vrm: backend,
            }),
            resolver: InMemoryResolver(asset),
            client: client,
            cardId: 'card-1',
            frames: controller.frames,
            actorId: 'pet',
          ),
        ),
      ),
    );
    await tester.pump();
    for (var i = 0; i < 3; i++) {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pump();
    }
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  testWidgets('real TTS RMS frames drive the VRM aa channel end to end', (
    tester,
  ) async {
    final controller = LipSyncController(
      actorId: 'pet',
      engine: _WavEngine(_wav16(
        sampleRate: 100,
        // Two windows: a loud sine (~0.67 RMS) then a silent one (0.0).
        samples: <int>[..._sineWindow(amplitude: 0.95), ...List<int>.filled(5, 0)],
      )),
    );
    addTearDown(controller.dispose);

    await pumpStage(tester, controller);
    expect(backend.loaded, hasLength(1));
    expect(backend.lipSyncWeights, isEmpty, reason: 'silent before speech');

    await controller.speak('real audio');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    // Two real windows -> two stamped frames -> two weights. Both derive from
    // measured RMS (attack 0.47 then decay toward 0), never a synthetic 1.0.
    expect(backend.lipSyncWeights, hasLength(2));
    final attack = backend.lipSyncWeights[0];
    final decay = backend.lipSyncWeights[1];
    expect(attack, closeTo(0.6717, 0.02));
    expect(decay, lessThan(attack));
    expect(decay, closeTo(0.3940, 0.02));
    for (final w in backend.lipSyncWeights) {
      expect(w, isNot(1.0), reason: 'weight must be real RMS, not synthetic');
    }
  });

  testWidgets('emotion switch keeps the real-RMS mouth and blink additive', (
    tester,
  ) async {
    final controller = LipSyncController(
      actorId: 'pet',
      engine: _WavEngine(_wav16(
        sampleRate: 100,
        samples: <int>[..._sineWindow(amplitude: 0.95), ...List<int>.filled(5, 0)],
      )),
    );
    addTearDown(controller.dispose);

    await pumpStage(tester, controller);
    await controller.speak('real audio');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(backend.lipSyncWeights, hasLength(2));
    final weightsBeforeCue = List<double>.of(backend.lipSyncWeights);

    // A daemon emotion cue (happy) and a blink-class cue arrive after speech.
    client.emitEvent(
      GatewayEventFrame(
        topic: EventTopic.emotionTag,
        rawTopic: 'emotion.tag',
        data: <String, dynamic>{
          'tag': 'happy',
          'kind': 'emotion',
          'intensity': 0.8,
          'actor_id': 'pet',
          'seq': 1,
          'ts_ms': 1700000000100,
        },
      ),
    );
    client.emitEvent(
      GatewayEventFrame(
        topic: EventTopic.emotionTag,
        rawTopic: 'emotion.tag',
        data: <String, dynamic>{
          'tag': 'blink',
          'kind': 'motion',
          'intensity': 1.0,
          'actor_id': 'pet',
          'seq': 2,
          'ts_ms': 1700000000150,
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Additive safety: the emotion switch routed both cues but never emitted a
    // new or zeroed lip-sync weight — the real-RMS `aa` weights still stand.
    expect(backend.emotions.map((c) => c.tag), <String>['happy', 'blink']);
    expect(backend.lipSyncWeights, weightsBeforeCue);
    expect(backend.lipSyncWeights, isNot(contains(0.0)));
  });
}