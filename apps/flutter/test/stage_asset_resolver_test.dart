// SPDX-License-Identifier: GPL-3.0-or-later

// Hermetic coverage for the model asset seam. No network, no committed model:
// local files are synthetic temp files and remote bytes come from an injected
// downloader. Cache entries are content-named and atomically renamed.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:anima_control/features/stage/model_asset_resolver.dart';
import 'package:anima_control/ui/model_stage.dart';

DisplayModel _model(String source, String value) => DisplayModel(
  kind: ModelKind.vrm,
  asset: ModelAssetRef(kind: ModelKind.vrm, source: source, value: value),
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('stage-asset-test-');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('a local file resolves to its absolute path and fingerprint', () async {
    final file = File('${temp.path}${Platform.pathSeparator}model.vrm');
    await file.writeAsBytes(<int>[1, 2, 3, 4]);
    final resolver = ModelAssetResolver(cacheDirectory: temp);

    final asset = await resolver.resolve(_model('file', file.path));

    expect(asset.path, file.absolute.path);
    expect(asset.source, 'file');
    expect(asset.byteLength, 4);
    expect(asset.fingerprint, isNotEmpty);
    expect(
      await File(
        '${temp.path}${Platform.pathSeparator}${asset.fingerprint}.bin',
      ).exists(),
      isFalse,
      reason: 'local files are used in place, never copied into the cache',
    );
  });

  test('a missing local file is a loud missing-asset error', () async {
    final resolver = ModelAssetResolver(cacheDirectory: temp);
    expect(
      () => resolver.resolve(_model('file', '${temp.path}/absent.vrm')),
      throwsA(
        isA<ModelAssetException>().having(
          (error) => error.code,
          'code',
          'missing-asset',
        ),
      ),
    );
  });

  test('the same remote bytes hit the cache once with one download', () async {
    var downloads = 0;
    final resolver = ModelAssetResolver(
      cacheDirectory: temp,
      downloader: (uri) async {
        downloads++;
        expect(uri.scheme, 'https');
        return <int>[9, 8, 7];
      },
    );

    final first = await resolver.resolve(
      _model('url', 'https://example.com/a.vrm'),
    );
    final second = await resolver.resolve(
      _model('url', 'https://example.com/a.vrm'),
    );

    expect(downloads, 1);
    expect(first.fingerprint, second.fingerprint);
    expect(first.path, second.path);
    expect(File(first.path).existsSync(), isTrue);
    expect(second.byteLength, 3);
  });

  test('a download failure is typed and leaves no cache entry', () async {
    final resolver = ModelAssetResolver(
      cacheDirectory: temp,
      downloader: (uri) => throw StateError('socket text'),
    );

    await expectLater(
      resolver.resolve(_model('url', 'https://example.com/a.vrm')),
      throwsA(
        isA<ModelAssetException>().having(
          (error) => error.code,
          'code',
          'download-failed',
        ),
      ),
    );
    expect(temp.listSync().where((entity) => entity is File), isEmpty);
  });

  test('remote assets without a downloader fail loudly', () async {
    final resolver = ModelAssetResolver(cacheDirectory: temp);
    await expectLater(
      resolver.resolve(_model('url', 'https://example.com/a.vrm')),
      throwsA(
        isA<ModelAssetException>().having(
          (error) => error.code,
          'code',
          'no-downloader',
        ),
      ),
    );
  });

  test('an invalid descriptor never reaches the resolver', () async {
    final resolver = ModelAssetResolver(cacheDirectory: temp);
    await expectLater(
      resolver.resolve(_model('url', 'ftp://example.com/a.vrm')),
      throwsA(
        isA<ModelAssetException>().having(
          (error) => error.code,
          'code',
          'invalid-asset',
        ),
      ),
    );
  });
}
