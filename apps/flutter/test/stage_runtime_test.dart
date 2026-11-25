// SPDX-License-Identifier: GPL-3.0-or-later

// Runtime lifecycle and sink semantics with fully synthetic assets and a
// recording backend: no GPU, no daemon, no model bytes on disk.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/method_channel_backend.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/model_expression.dart';
import 'package:anima_control/features/stage/model_stage_runtime.dart';
import 'package:anima_control/features/stage/model_stage_state.dart';
import 'package:anima_control/speech/lip_sync_rms_data.dart';
import 'package:anima_control/ui/model_stage.dart';

DisplayModel _vrm(String value) => DisplayModel(
  kind: ModelKind.vrm,
  asset: ModelAssetRef(kind: ModelKind.vrm, source: 'file', value: value),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File asset;
  late RecordingModelBackend backend;
  late List<ModelStageSnapshot> snapshots;
  late ModelStageRuntime runtime;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-runtime-test-');
    asset = File('${temp.path}${Platform.pathSeparator}model.vrm')
      ..writeAsBytesSync(<int>[1, 2, 3]);
    backend = RecordingModelBackend(ModelKind.vrm);
    snapshots = <ModelStageSnapshot>[];
    runtime = ModelStageRuntime(
      resolver: ModelAssetResolver(cacheDirectory: temp),
      backends: ModelBackendRegistry(<ModelKind, ModelBackend>{
        ModelKind.vrm: backend,
      }),
      onChanged: snapshots.add,
    );
  });

  tearDown(() async {
    await runtime.dispose();
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test(
    'load publishes resolving, loading, ready and disposes on clear',
    () async {
      await runtime.load(_vrm(asset.path));

      expect(snapshots.map((s) => s.status), <ModelStageStatus>[
        ModelStageStatus.resolving,
        ModelStageStatus.loading,
        ModelStageStatus.ready,
      ]);
      expect(backend.loaded, hasLength(1));
      expect(runtime.snapshot.handle, isNotNull);
      expect(runtime.snapshot.asset!.byteLength, 3);

      await runtime.clear();

      expect(backend.disposed, hasLength(1));
      expect(runtime.snapshot.status, ModelStageStatus.none);
    },
  );

  test('a missing asset fails loudly and never reaches the backend', () async {
    await runtime.load(_vrm('${temp.path}/missing.vrm'));

    expect(runtime.snapshot.status, ModelStageStatus.failed);
    expect(runtime.snapshot.error, isA<ModelAssetException>());
    expect(backend.loaded, isEmpty);
  });

  test(
    'a blocked Live2D runtime fails loudly instead of faking a model',
    () async {
      final blocked = ModelBackendRegistry.fromRuntimes();
      final live2dRuntime = ModelStageRuntime(
        resolver: ModelAssetResolver(cacheDirectory: temp),
        backends: blocked,
      );
      addTearDown(live2dRuntime.dispose);

      await live2dRuntime.load(
        DisplayModel(
          kind: ModelKind.live2d,
          asset: ModelAssetRef(
            kind: ModelKind.live2d,
            source: 'file',
            value: asset.path,
          ),
        ),
      );

      expect(live2dRuntime.snapshot.status, ModelStageStatus.failed);
      final error = live2dRuntime.snapshot.error;
      expect(error, isA<ModelBackendException>());
      expect((error as ModelBackendException).code, 'runtime-unavailable');
      expect(error.message, contains('Cubism Core'));
    },
  );

  test(
    'lip-sync frames are smoothed and stale/other-actor frames ignored',
    () async {
      await runtime.load(_vrm(asset.path));

      await runtime.lipSync(
        const LipSyncRmsData(actorId: 'pet-1', level: 0.75, seq: 5, tsMs: 1000),
      );
      await runtime.lipSync(
        const LipSyncRmsData(actorId: 'other', level: 1.0, seq: 6, tsMs: 1001),
        actorId: 'pet-1',
      );
      await runtime.lipSync(
        const LipSyncRmsData(actorId: 'pet-1', level: 1.0, seq: 4, tsMs: 1002),
      );

      expect(backend.lipSyncWeights, hasLength(1));
      expect(backend.lipSyncWeights.single, 0.75);
      expect(runtime.snapshot.lipSyncWeight, 0.75);
    },
  );

  test(
    'emotion cues are routed once and replayed seq values are ignored',
    () async {
      await runtime.load(_vrm(asset.path));
      final cue = StageExpressionCue(
        tag: 'happy',
        kind: 'emotion',
        intensity: 0.8,
        actorId: 'pet-1',
        seq: 42,
        tsMs: 1700000000200,
      );

      await runtime.emotion(cue);
      await runtime.emotion(cue);

      expect(backend.emotions, hasLength(1));
      expect(backend.emotions.single, cue);
      expect(runtime.snapshot.emotion, cue);
    },
  );

  test('ambient phases reach the backend once and reset on clear', () async {
    await runtime.load(_vrm(asset.path));

    await runtime.ambient(0.25, elapsed: const Duration(milliseconds: 16));
    await runtime.ambient(0.25, elapsed: const Duration(milliseconds: 16));
    await runtime.ambient(0.5, elapsed: const Duration(milliseconds: 33));
    await runtime.ambient(0.75, elapsed: const Duration(milliseconds: 16));

    expect(backend.ambientPhases, <double>[0.25, 0.5]);
    expect(runtime.snapshot.ambientElapsed, const Duration(milliseconds: 33));

    await runtime.clear();
    await runtime.load(_vrm(asset.path));
    await runtime.ambient(0.25, elapsed: const Duration(milliseconds: 16));

    expect(backend.ambientPhases, <double>[0.25, 0.5, 0.25]);
  });

  test('method-channel backend errors are typed and loud', () async {
    final backend = MethodChannelModelBackend(
      ModelKind.vrm,
      'org.moeru.airi/anima/model/test-missing',
    );
    final channelRuntime = ModelStageRuntime(
      resolver: ModelAssetResolver(cacheDirectory: temp),
      backends: ModelBackendRegistry(<ModelKind, ModelBackend>{
        ModelKind.vrm: backend,
      }),
    );
    addTearDown(channelRuntime.dispose);

    await channelRuntime.load(_vrm(asset.path));

    expect(channelRuntime.snapshot.status, ModelStageStatus.failed);
    final error = channelRuntime.snapshot.error;
    expect(error, isA<ModelBackendException>());
    expect((error as ModelBackendException).code, 'runtime-unavailable');
  });
}
