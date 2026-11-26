// SPDX-License-Identifier: GPL-3.0-or-later

// Parity coverage for the stage's non-renderer surfaces: caption overlay,
// background layers, control-strip host and idle/cue state. Everything is
// driven from client-local state; the daemon is a fake and no asset, frame or
// renderer is fabricated.

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/model_expression.dart';
import 'package:anima_control/features/stage/model_runtime.dart';
import 'package:anima_control/features/stage/stage_background.dart';
import 'package:anima_control/features/stage/stage_caption_overlay.dart';
import 'package:anima_control/features/stage/stage_control_strip.dart';
import 'package:anima_control/features/stage/stage_control_strip_state.dart';
import 'package:anima_control/features/stage/stage_overlay_state.dart';
import 'package:anima_control/features/stage/stage_overlays.dart';
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

StageExpressionCue _cue({
  String tag = 'happy',
  String kind = 'emotion',
  double intensity = 0.8,
  String actorId = 'pet-1',
  int seq = 1,
}) => StageExpressionCue(
  tag: tag,
  kind: kind,
  intensity: intensity,
  actorId: actorId,
  seq: seq,
  tsMs: 1700000000000 + seq,
);

void main() {
  late Directory temp;
  late File asset;
  late FakeChatClient client;
  late RecordingModelBackend backend;
  late StreamController<LipSyncRmsData> frames;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-parity-test-');
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

  Future<void> pumpStage(
    WidgetTester tester, {
    StageBackground background = StageBackground.none,
    StageCaptionStyle captionStyle = const StageCaptionStyle(),
  }) async {
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
            background: background,
            captionStyle: captionStyle,
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

  group('StageCaptionController', () {
    test(
      'a turn accumulates deltas and the terminal marker keeps the text',
      () {
        final controller = StageCaptionController();
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': 'Hello ',
          'seq': 1,
        });
        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': 'world',
          'seq': 2,
        });
        expect(controller.snapshot.segments.single.text, 'Hello world');

        controller.applyTokenDelta(<String, dynamic>{
          'message_id': 'm1',
          'delta': '',
          'final': true,
          'seq': 3,
        });
        expect(controller.snapshot.segments.single.text, 'Hello world');
      },
    );

    test('a new message id resets the buffer and replayed seq is ignored', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'first',
        'seq': 1,
      });
      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm1',
        'delta': 'first',
        'seq': 1,
      });
      expect(controller.snapshot.segments.single.text, 'first');

      controller.applyTokenDelta(<String, dynamic>{
        'message_id': 'm2',
        'delta': 'second',
        'seq': 2,
      });
      expect(controller.snapshot.segments.single.text, 'second');
    });

    test('malformed frames never spoof a caption', () {
      final controller = StageCaptionController();
      controller.applyTokenDelta(<String, dynamic>{'delta': 42});
      expect(controller.snapshot.isEmpty, isTrue);
    });
  });

  group('display model resolution', () {
    test('the nested modules.displayModelId wins over a stale top-level id', () {
      final model = DisplayModel.fromCard(_cardWith(<String, dynamic>{
        'displayModelId': 'stale-id',
        'modules': <String, dynamic>{'displayModelId': 'nested-id'},
      }));
      expect(model.kind, ModelKind.none);
      expect(model.displayModelId, 'nested-id');
    });

    test('a top-level id is still read when modules has no value', () {
      final model = DisplayModel.fromCard(_cardWith(<String, dynamic>{
        'displayModelId': 'legacy-id',
        'modules': <String, dynamic>{},
      }));
      expect(model.displayModelId, 'legacy-id');
    });
  });

  test('active_state.displayModelId is the canonical restore value', () {
    final model = DisplayModel.fromCard(_cardWith(<String, dynamic>{
      'modules': <String, dynamic>{'displayModelId': 'stale-module'},
      'active_state': <String, dynamic>{'displayModelId': 'active-model'},
    }));
    expect(model.displayModelId, 'active-model');
  });

  test('an active_state-only card restores its display model', () {
    final model = DisplayModel.fromCard(_cardWith(<String, dynamic>{
      'active_state': <String, dynamic>{'displayModelId': 'active-only'},
    }));
    expect(model.displayModelId, 'active-only');
  });

  group('StageCaptionStyle', () {
    test('reads the daemon captions section shape', () {
      final style = StageCaptionStyle.fromSettings(<String, dynamic>{
        'docking': 'top',
        'font_size': 150,
        'opacity': 40,
      });
      expect(style.docking, StageCaptionDocking.top);
      expect(style.isTop, isTrue);
      expect(style.scale, 1.5);
      expect(style.alpha, 0.4);
    });

    test('only implemented docking edges are recognized', () {
      expect(StageCaptionStyle.dockingFrom('none'), StageCaptionDocking.none);
      expect(StageCaptionStyle.dockingFrom('top'), StageCaptionDocking.top);
      expect(StageCaptionStyle.dockingFrom('head'), StageCaptionDocking.bottom);
      expect(
        const StageCaptionStyle(docking: StageCaptionDocking.none).isVisible,
        isFalse,
      );
    });
  });

  group('platform model choices', () {
    test('unsupported kinds have no usable runtime on this platform', () {
      final supported = supportedModelKinds(
        defaultTargetPlatform,
        registeredKinds: <ModelKind>{ModelKind.vrm},
      );
      expect(supported, <ModelKind>[ModelKind.vrm]);
      for (final kind in <ModelKind>[
        ModelKind.live2d,
        ModelKind.mmd,
        ModelKind.spine,
      ]) {
        expect(supported, isNot(contains(kind)));
        expect(
          modelKindSupported(
            defaultTargetPlatform,
            kind,
            registeredKinds: <ModelKind>{ModelKind.vrm},
          ),
          isFalse,
        );
      }
    });
  });

  group('StageBackground', () {
    test('hex tints parse with and without alpha', () {
      expect(StageBackground.tintFromHex('#101010').tint, 0xFF101010);
      expect(StageBackground.tintFromHex('#80101010').tint, 0x80101010);
      expect(
        StageBackground.tintFromHex('nope').kind,
        StageBackgroundKind.none,
      );
    });

    test('a local image resolves; a remote one fails loudly', () async {
      const resolver = StageBackgroundResolver();
      final resolved = await resolver.resolve(imagePath: asset.path);
      expect(resolved.kind, StageBackgroundKind.image);
      expect(resolved.imagePath, asset.absolute.path);

      await expectLater(
        resolver.resolve(imagePath: 'https://example.com/bg.png'),
        throwsA(
          isA<StageBackgroundException>().having(
            (e) => e.code,
            'code',
            'remote-background',
          ),
        ),
      );
      await expectLater(
        resolver.resolve(tint: 'not-a-color'),
        throwsA(
          isA<StageBackgroundException>().having(
            (e) => e.code,
            'code',
            'invalid-tint',
          ),
        ),
      );
    });
  });

  group('StageControlStripState', () {
    test('defaults to the daemon enabled buttons and catalog order', () {
      final state = StageControlStripState();
      expect(state.activeButtons, <String>['stage', 'caption']);
      state.toggle('stage');
      expect(state.activeButtons, <String>['caption']);
      state.toggle('stage');
      expect(state.activeButtons, <String>['stage', 'caption']);
    });

    test('settings round-trip the camelCase control-strip section', () {
      final settings = StageControlStripSettings.fromSettings(<String, dynamic>{
        'dockedEdge': 'left',
        'collapsed': true,
        'captionOpen': false,
        'backgroundTint': '#123456',
        'buttons': <Map<String, dynamic>>[
          <String, dynamic>{'id': 'stage', 'enabled': true},
          <String, dynamic>{'id': 'chat', 'enabled': false},
          <String, dynamic>{'id': 'caption', 'enabled': true},
          <String, dynamic>{'id': 'unknown-button', 'enabled': true},
        ],
      });
      expect(settings.strip.edge, StageStripEdge.left);
      expect(settings.strip.collapsed, isTrue);
      expect(settings.strip.activeButtons, <String>['stage', 'caption']);
      expect(settings.captionStyle.isVisible, isFalse);
      expect(settings.backgroundTint, '#123456');
    });
  });

  group('StageRenderState', () {
    test('frames and cues are dropped for the wrong actor or a replay', () {
      final state = StageRenderState(actorId: 'pet-1');
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'other', level: 1, seq: 1, tsMs: 1),
        ),
        isFalse,
      );
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'pet-1', level: 1, seq: 1, tsMs: 1),
        ),
        isTrue,
      );
      expect(
        state.applyFrame(
          const LipSyncRmsData(actorId: 'pet-1', level: 0.2, seq: 1, tsMs: 2),
        ),
        isFalse,
      );

      expect(state.applyCue(_cue(actorId: 'other')), isFalse);
      expect(state.applyCue(_cue(seq: 2)), isTrue);
      expect(state.applyCue(_cue(seq: 2)), isFalse);
      expect(state.cueChannel, StageCueChannel.emotion);
      expect(state.applyCue(_cue(kind: 'motion', tag: 'wave', seq: 3)), isTrue);
      expect(state.cueChannel, StageCueChannel.motion);
    });

    test('idle phase is a paused-aware triangle wave', () {
      final state = StageRenderState();
      expect(state.idlePhase, 0, reason: 'the clock has not been ticked yet');
      state.setPaused(true);
      expect(state.idlePhase, 0);
      state.setPaused(false);
      final quarter = const StageIdleMotion().phaseAt(
        const Duration(seconds: 1),
      );
      expect(quarter, closeTo(1 / 3, 1e-9));
    });
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 10));
    }
  }

  group('StageOverlays', () {
    testWidgets('a tint background paints and the caption bar renders text', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageOverlays(
              state: StageRenderState(
                background: const StageBackground(
                  kind: StageBackgroundKind.tint,
                  tint: 0xFF101010,
                ),
              ),
              model: const ColoredBox(color: Color(0xFF202020)),
            ),
          ),
        ),
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is ColoredBox && widget.color == const Color(0xFF101010),
        ),
        findsOneWidget,
      );
      expect(find.byType(StageCaptionOverlay), findsOneWidget);
      expect(find.byType(StageCueBadge), findsNothing);
    });

    testWidgets('captions render the speaker and the active segment', (
      tester,
    ) async {
      final state = StageRenderState();
      state.captions.setSpeaker('Anima');
      state.captions.setSegments(const <CaptionSegment>[
        CaptionSegment(text: 'Hello', color: '#ff0000'),
        CaptionSegment(text: 'world'),
      ]);
      state.captions.setActiveSentence(0);
      state.setBackground(
        const StageBackground(kind: StageBackgroundKind.tint, tint: 0xFF101010),
      );

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageOverlays(
              state: state,
              model: const ColoredBox(color: Color(0xFF202020)),
            ),
          ),
        ),
      );

      expect(find.text('Anima'), findsOneWidget);
      expect(find.text('Hello'), findsOneWidget);
      expect(find.text('world'), findsOneWidget);
      final rich = tester.widget<Text>(find.text('Hello'));
      expect(rich.style?.fontWeight, FontWeight.w700);
    });

    testWidgets('a hidden caption docking renders no bar', (tester) async {
      final state = StageRenderState(
        captions: const StageCaptionStyle(docking: StageCaptionDocking.none),
      );
      state.captions.setSpeaker('Anima');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageOverlays(
              state: state,
              model: const ColoredBox(color: Color(0xFF202020)),
            ),
          ),
        ),
      );
      expect(find.byType(StageCaptionOverlay), findsNothing);
      expect(find.text('Anima'), findsNothing);
      expect(find.byType(StageCueBadge), findsNothing);
    });
  });

  group('StageScreen integration', () {
    testWidgets('the strip, captions, background and cue badge share state', (
      tester,
    ) async {
      await pumpStage(
        tester,
        background: const StageBackground(
          kind: StageBackgroundKind.tint,
          tint: 0xFF101010,
        ),
      );

      expect(find.byType(StageControlStrip), findsOneWidget);
      expect(find.byIcon(Icons.theater_comedy_outlined), findsOneWidget);
      // The surface always mounts one readout; it shows mouth level until a
      // cue arrives.
      expect(find.byType(StageCueBadge), findsOneWidget);

      frames.add(
        const LipSyncRmsData(
          actorId: 'pet-1',
          level: 0.6,
          seq: 1,
          tsMs: 1700000000000,
        ),
      );
      await tester.pump();
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
      expect(find.text('emotion happy'), findsOneWidget);

      client.emitEvent(
        GatewayEventFrame(
          topic: EventTopic.tokenDelta,
          rawTopic: 'token.delta',
          data: <String, dynamic>{
            'session_id': 's1',
            'message_id': 'm1',
            'delta': 'Hello ',
            'seq': 1,
            'final': false,
          },
        ),
      );
      await tester.pump();
      client.emitEvent(
        GatewayEventFrame(
          topic: EventTopic.tokenDelta,
          rawTopic: 'token.delta',
          data: <String, dynamic>{
            'session_id': 's1',
            'message_id': 'm1',
            'delta': 'world',
            'seq': 2,
            'final': true,
          },
        ),
      );
      await settle(tester);
      expect(find.text('Hello world'), findsOneWidget);
    });

    testWidgets('a motion cue is never labelled a facial emotion', (
      tester,
    ) async {
      // The shared render state is fresh per pump; the badge is static.
      await pumpStage(tester);
      await tester.pump(const Duration(milliseconds: 100));
      client.emitEvent(
        GatewayEventFrame(
          topic: EventTopic.emotionTag,
          rawTopic: 'emotion.tag',
          data: <String, dynamic>{
            'tag': 'wave',
            'kind': 'motion',
            'intensity': 0.5,
            'actor_id': 'pet-1',
            'seq': 7,
            'ts_ms': 1700000000300,
          },
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('motion wave'), findsOneWidget);
      expect(find.textContaining('emotion'), findsNothing);
    });

    testWidgets('a daemon vfx cue reaches the stage cue channel', (
      tester,
    ) async {
      await pumpStage(tester);
      client.emitEvent(
        GatewayEventFrame(
          topic: EventTopic.emotionTag,
          rawTopic: 'emotion.tag',
          data: <String, dynamic>{
            'tag': 'fire',
            'kind': 'vfx',
            'intensity': 0.7,
            'actor_id': 'pet-1',
            'seq': 11,
            'ts_ms': 1700000000400,
          },
        ),
      );
      await settle(tester);
      // The daemon payload parsed into a real cue, the binding applied it to
      // the shared render state, and the badge labels its vfx channel.
      expect(find.text('vfx fire'), findsOneWidget);
      expect(find.textContaining('emotion'), findsNothing);
      expect(backend.emotions.single.kind, 'vfx');
      expect(backend.emotions.single.tag, 'fire');
      expect(backend.emotions.single.isNonFacial, isTrue);
      expect(backend.emotions.single.isMotion, isFalse);
      expect(stageCueChannel(backend.emotions.single), StageCueChannel.vfx);
    });

    testWidgets('the strip reports intent without inventing daemon state', (
      tester,
    ) async {
      await pumpStage(tester);
      final strip = StageControlStripState();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StageControlStrip(
              state: strip,
              onAction: (action) => strip.toggle(action.buttonId),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byIcon(Icons.chat_bubble_outline), findsNothing);
      await tester.pump();
      await tester.tap(find.byIcon(Icons.theater_comedy_outlined));
      await tester.pump();
      expect(strip.isEnabled('stage'), isFalse);
      expect(strip.activeButtons, <String>['caption']);
    });
  });
}
