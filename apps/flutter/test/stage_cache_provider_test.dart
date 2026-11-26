// SPDX-License-Identifier: GPL-3.0-or-later

// The model cache must live in the application cache directory, never in
// Directory.systemTemp. The directory provider is injected so these tests
// never touch the real user cache or a platform method channel.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/ui/model_stage.dart';
import 'package:anima_control/features/stage/stage_screen.dart';

import 'support/fakes.dart';

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-cache-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('modelCacheDirectory appends model-cache to the injected base', () async {
    final directory = await modelCacheDirectory(base: () async => temp);

    expect(directory.path, '${temp.path}${Platform.pathSeparator}model-cache');
  });

  test('a failed cache-directory lookup fails loudly', () async {
    await expectLater(
      modelCacheDirectory(
        base: () async => throw const FileSystemException('no cache path'),
      ),
      throwsA(
        isA<ModelAssetException>()
            .having((e) => e.code, 'code', 'cache-directory')
            .having((e) => e.message, 'message', contains('no cache path')),
      ),
    );
  });

  test('the injected cache provider stores downloaded model bytes there', () async {
    var bases = 0;
    final resolver = ModelAssetResolver(
      cacheDirectoryProvider: () async {
        bases++;
        return temp;
      },
      downloader: (uri) async => <int>[1, 2, 3],
    );
    final model = DisplayModel(
      kind: ModelKind.vrm,
      asset: ModelAssetRef(
        kind: ModelKind.vrm,
        source: 'url',
        value: 'https://example.com/a.vrm',
      ),
    );

    final asset = await resolver.resolve(model);

    expect(bases, 1);
    expect(asset.path, startsWith(temp.path));
    expect(File(asset.path).existsSync(), isTrue);
    expect(asset.byteLength, 3);
  });

  testWidgets('a failed cache-directory lookup stays a quiet stage error', (
    tester,
  ) async {
    final client = FakeChatClient();
    addTearDown(client.dispose);
    client.onCall = (action, payload) => RpcReply(
      action: action,
      ok: true,
      data: <String, dynamic>{},
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StageScreen(
            client: client,
            cacheDirectoryProvider: () async =>
                throw const FileSystemException('no cache path'),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));

    expect(find.text('No display model'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
