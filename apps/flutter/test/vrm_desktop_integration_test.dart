// SPDX-License-Identifier: GPL-3.0-or-later

// Desktop-client gate for VRM rendering.
//
// The Rust half of this gate (`crates/anima-render/tests/vrm_desktop_integration.rs`)
// proves the frozen C ABI renders `AvatarSample_A.vrm` with MToon shading,
// spring bones and round-tripping sinks. This file proves the *client* half:
// the production stage path — `StageScreen` → `ModelStage` → `NativeModelSurface`
// → `ModelStageRuntime` → `MethodChannelModelBackend` — drives that same
// contract over the frozen `org.moeru.airi/anima/model/vrm` channel with the
// real bundled VRM asset, and that a platform which registers no native
// renderer fails loudly instead of painting a placeholder.
//
// The platform side is a mock method-channel handler that speaks the frozen
// contract (`load` → `textureId`, then the sink methods, then `dispose`); no
// GPU texture is claimed and no frame is fabricated. The remaining gap — no
// per-OS backend actually registers on the channel yet — is recorded in
// `docs/feature-parity-checklist.md`.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/method_channel_backend.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/features/stage/model_backend.dart';
import 'package:anima_control/features/stage/model_runtime.dart';
import 'package:anima_control/features/stage/stage_screen.dart';
import 'package:anima_control/ui/model_stage.dart';

import 'support/fakes.dart';

/// The bundled VRM the Rust gate renders through the C ABI.
final String _vrmAsset =
    '${Directory.current.parent.parent.path}'
    '${Platform.pathSeparator}packages'
    '${Platform.pathSeparator}stage-ui'
    '${Platform.pathSeparator}src'
    '${Platform.pathSeparator}assets'
    '${Platform.pathSeparator}vrm'
    '${Platform.pathSeparator}models'
    '${Platform.pathSeparator}AvatarSample-A'
    '${Platform.pathSeparator}AvatarSample_A.vrm';

const String _vrmChannel = 'org.moeru.airi/anima/model/vrm';

/// A card whose `extensions.airi.vrm` descriptor points at [path].
Map<String, dynamic> _cardWithVrm(String path) => <String, dynamic>{
  'spec': 'chara_card_v3',
  'data': <String, dynamic>{
    'name': 'VRM Stage Card',
    'extensions': <String, dynamic>{
      'airi': <String, dynamic>{
        'vrm': <String, dynamic>{'source': 'file', 'file': path},
      },
    },
  },
};

/// The platform's side of the frozen contract: it records every call and mints
/// the opaque texture id `load` returns. Nothing is drawn — the mock owns no GPU
/// texture — but the argument keys are asserted exactly as the frozen contract
/// declares them.
class _RecordingVrmPlatform {
  final List<MethodCall> calls = <MethodCall>[];
  final List<int> releasedTextures = <int>[];
  int _nextHandle = 0;
  int _nextTexture = 11;

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'load':
        final args = call.arguments as Map<Object?, Object?>;
        _nextHandle++;
        return <String, Object?>{
          'handle': 'vrm-handle-$_nextHandle',
          'textureId': _nextTexture++,
        };
      case 'dispose':
        releasedTextures.add(_nextTexture - 1);
        return null;
      default:
        return null;
    }
  }

  void install() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(_vrmChannel), (call) async => await handle(call));
  }

  void uninstall() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(MethodChannel(_vrmChannel), null);
  }
}

/// Resolves the real bundled asset without touching the user's cache.
class _BundledAssetResolver extends ModelAssetResolver {
  _BundledAssetResolver() : super(cacheDirectory: Directory.systemTemp);

  @override
  Future<ResolvedModelAsset> resolve(DisplayModel model) async {
    final file = File(model.asset!.value!);
    final bytes = await file.readAsBytes();
    return ResolvedModelAsset(
      path: file.absolute.path,
      source: 'file',
      originalValue: file.absolute.path,
      fingerprint: 'bundled-avatar-sample-a',
      byteLength: bytes.length,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _RecordingVrmPlatform platform;
  late FakeChatClient client;

  setUp(() {
    platform = _RecordingVrmPlatform();
    platform.install();
    client = FakeChatClient();
  });

  tearDown(() {
    platform.uninstall();
    client.dispose();
  });

  Future<void> pumpStage(WidgetTester tester, {required String assetPath}) async {
    client.onCall = (action, payload) => RpcReply(
      action: action,
      ok: true,
      data: <String, dynamic>{'card': _cardWithVrm(assetPath)},
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageScreen(
            client: client,
            cardId: 'card-vrm',
            backends: ModelBackendRegistry.fromRuntimes(
              create: (ModelRuntimeInfo info) =>
                  MethodChannelModelBackend(info.kind, info.channelName),
            ),
            resolver: _BundledAssetResolver(),
            actorId: 'pet-1',
          ),
        ),
      ),
    );
    // Let the card read, the asset resolve and the native load complete.
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('the desktop stage loads the bundled VRM over the frozen channel', (
    tester,
  ) async {
    expect(
      File(_vrmAsset).existsSync(),
      isTrue,
      reason: 'bundled VRM fixture missing at $_vrmAsset',
    );

    await pumpStage(tester, assetPath: _vrmAsset);

    final load = platform.calls.where((c) => c.method == 'load').single;
    expect(load.arguments, <String, Object?>{
      'path': File(_vrmAsset).absolute.path,
      'source': 'file',
    });

    // The stage is ready and paints the platform texture; nothing is faked.
    expect(find.textContaining('mouth 0%'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);
    expect(find.byType(Texture), findsOneWidget);
    expect(platform.releasedTextures, isEmpty);
  });

  testWidgets('a platform with no native VRM renderer fails loudly', (
    tester,
  ) async {
    // No mock handler is installed for this case: the channel is unregistered,
    // exactly like a desktop build where no per-OS backend registered itself.
    platform.uninstall();

    await pumpStage(tester, assetPath: _vrmAsset);

    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(
      find.textContaining('No native vrm renderer is registered'),
      findsOneWidget,
    );
    // No texture id is ever held and nothing was released.
    expect(find.byType(Texture), findsNothing);
    expect(platform.releasedTextures, isEmpty);
  });

  test('the stage never invents a texture id for an unknown kind', () {
    final registry = ModelBackendRegistry.fromRuntimes();
    expect(
      () => registry.backendFor(ModelKind.none),
      throwsA(
        isA<ModelBackendException>().having(
          (error) => error.code,
          'code',
          'unknown-kind',
        ),
      ),
    );
  });
}