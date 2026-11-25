// SPDX-License-Identifier: GPL-3.0-or-later

// End-to-end coverage of the canonical stage seam: StageScreen supplies native
// backends, ModelStage routes the card descriptor, and NativeModelSurface
// pumps real stamped lip-sync frames and daemon emotion cues into the backend.
// All assets are synthetic; no platform channel or network is involved.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

Map<String, dynamic> _cardWith(Map<String, dynamic> airi) => <String, dynamic>{
  'spec': 'chara_card_v3',
  'data': <String, dynamic>{
    'name': 'Stage Card',
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
  late StreamController<LipSyncRmsData> frames;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-surface-test-');
    asset = File('${temp.path}${Platform.pathSeparator}model.vrm')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    client = FakeChatClient();
    backend = RecordingModelBackend(ModelKind.vrm);
    frames = StreamController<LipSyncRmsData>.broadcast();
  });

  tearDown(() async {
    await frames.close();
    client.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> pumpStage(WidgetTester tester) async {
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
            frames: frames.stream,
            actorId: 'pet-1',
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('a valid card loads natively through the single stage seam', (
    tester,
  ) async {
    await pumpStage(tester);

    expect(backend.loaded, hasLength(1));
    expect(backend.loaded.single.path, asset.absolute.path);
    expect(find.textContaining('mouth 0%'), findsOneWidget);
    expect(find.text('No display model'), findsNothing);
    expect(find.byIcon(Icons.error_outline), findsNothing);
  });

  testWidgets('real lip-sync frames and emotion cues reach the backend', (
    tester,
  ) async {
    await pumpStage(tester);

    frames.add(
      const LipSyncRmsData(
        actorId: 'pet-1',
        level: 0.6,
        seq: 1,
        tsMs: 1700000000000,
      ),
    );
    await settle(tester);

    client.emitEvent(
      GatewayEventFrame(
        topic: EventTopic.emotionTag,
        rawTopic: 'emotion.tag',
        data: <String, dynamic>{
          'tag': 'happy',
          'kind': 'emotion',
          'intensity': 0.8,
          'actor_id': 'pet-1',
          'seq': 42,
          'ts_ms': 1700000000200,
        },
      ),
    );
    await settle(tester);

    expect(backend.lipSyncWeights, hasLength(1));
    expect(backend.lipSyncWeights.single, 0.6);
    expect(backend.emotions, hasLength(1));
    expect(backend.emotions.single.tag, 'happy');
    // The readout shows the latest cue channel once one has arrived.
    expect(find.text('emotion happy'), findsOneWidget);
  });

  testWidgets('wrong-actor cues and frames never animate the model', (
    tester,
  ) async {
    await pumpStage(tester);

    frames.add(
      const LipSyncRmsData(
        actorId: 'someone-else',
        level: 1.0,
        seq: 1,
        tsMs: 1700000000000,
      ),
    );
    client.emitEvent(
      GatewayEventFrame(
        topic: EventTopic.emotionTag,
        rawTopic: 'emotion.tag',
        data: <String, dynamic>{
          'tag': 'angry',
          'kind': 'emotion',
          'intensity': 1.0,
          'actor_id': 'someone-else',
          'seq': 43,
          'ts_ms': 1700000000300,
        },
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(backend.lipSyncWeights, isEmpty);
    expect(backend.emotions, isEmpty);
  });

  testWidgets('a native load failure is loud, never a placeholder', (
    tester,
  ) async {
    backend.onLoad = (asset) async => throw StateError('secret platform text');
    await pumpStage(tester);

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.textContaining('StateError'), findsOneWidget);
    expect(find.textContaining('secret platform text'), findsNothing);
  });
}
