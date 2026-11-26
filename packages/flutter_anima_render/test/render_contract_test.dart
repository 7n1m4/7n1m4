// SPDX-License-Identifier: GPL-3.0-or-later

// Plugin-level coverage of the frozen native render/texture contract: the
// platform mints a texture id on `load` and releases it on `dispose`, and Dart
// only ever holds the opaque integer. No GPU and no real platform channel are
// involved; the channel is a mock that records the calls.

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_anima_render/flutter_anima_render.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channelName = '${kAnimaRenderChannelPrefix}spine';
  final channel = MethodChannel(channelName);
  late List<MethodCall> calls;
  late List<int> releasedTextures;

  setUp(() {
    calls = <MethodCall>[];
    releasedTextures = <int>[];
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'load') {
            return <String, dynamic>{'handle': 'h-1', 'textureId': 7};
          }
          return null;
        });
  });

  tearDown(() {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('load mints an opaque texture id; dispose releases it once', () async {
    final plugin = FlutterAnimaRender('spine', releasedTextures.add);

    final texture = await plugin.load('/models/synthetic.bundle');

    // Dart holds only the opaque integer id the platform returned.
    expect(texture.textureId, 7);
    expect(texture.isDisposed, isFalse);
    expect(calls.map((c) => c.method), <String>['load']);
    expect(calls.single.arguments, <String, dynamic>{'path': '/models/synthetic.bundle'});

    await texture.dispose();

    expect(texture.isDisposed, isTrue);
    expect(releasedTextures, <int>[7]);
    expect(calls.map((c) => c.method), <String>['load', 'dispose']);
    expect((calls.last.arguments as Map<Object?, Object?>)['handle'], 'h-1');

    // Idempotent: a second dispose does not release again or call the channel.
    await texture.dispose();
    expect(releasedTextures, <int>[7]);
    expect(calls.map((c) => c.method), <String>['load', 'dispose']);
  });

  test('the opaque texture id is the platform-minted output surface', () async {
    final plugin = FlutterAnimaRender('spine', releasedTextures.add);
    // A real backend reports multiple page ids and hands back the last
    // (shaded output) id as the handle's textureId. Dart must not substitute
    // the first page just because it is numerically smaller.
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'load') {
            return <String, dynamic>{'handle': 'h-2', 'textureId': 42};
          }
          return null;
        });

    final texture = await plugin.load('/models/synthetic.bundle');
    expect(texture.textureId, 42, reason: 'Dart holds only the platform-minted output id');

    await texture.dispose();
    expect(releasedTextures, <int>[42]);
  });

  test('sinks forward the frozen argument keys to the platform', () async {
    final plugin = FlutterAnimaRender('spine');
    final texture = await plugin.load('/models/synthetic.bundle');
    calls.clear();

    await texture.setLipSync(0.5);
    await texture.setEmotion(tag: 'happy', kind: 'emotion', intensity: 0.8, seq: 42, tsMs: 1700000000200);
    await texture.setAmbientPhase(0.25);

    expect(calls.map((c) => c.method), <String>[
      'setLipSync',
      'setEmotion',
      'setAmbientPhase',
    ]);
    expect(calls[0].arguments, <String, dynamic>{'handle': 'h-1', 'weight': 0.5});
    expect(calls[1].arguments, <String, dynamic>{
      'handle': 'h-1',
      'tag': 'happy',
      'kind': 'emotion',
      'intensity': 0.8,
      'seq': 42,
      'tsMs': 1700000000200,
    });
    expect(calls[2].arguments, <String, dynamic>{'handle': 'h-1', 'phase': 0.25});
  });

  test('a missing native renderer fails loudly with a typed error', () async {
    TestWidgetsFlutterBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    final plugin = FlutterAnimaRender('spine');

    await expectLater(
      plugin.load('/models/synthetic.bundle'),
      throwsA(
        isA<NativeRenderException>().having(
          (e) => e.code,
          'code',
          'runtime-unavailable',
        ),
      ),
    );
  });
}