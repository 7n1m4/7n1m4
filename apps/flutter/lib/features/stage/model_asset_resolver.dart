// SPDX-License-Identifier: GPL-3.0-or-later

// Turns a card's model descriptor into a local file the native renderer can
// open. No model bytes are committed: local files are used in place, remote
// http(s) assets are downloaded through an injectable client into a
// content-named cache with atomic rename. Everything is injectable so tests
// never touch the network or the real user cache.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'model_failure.dart';
import '../../ui/model_stage.dart';

/// A resolved asset ready for the native backend.
class ResolvedModelAsset {
  const ResolvedModelAsset({
    required this.path,
    required this.source,
    required this.originalValue,
    required this.fingerprint,
    required this.byteLength,
  });

  /// Absolute path to a local file the native renderer can open.
  final String path;

  /// Original descriptor source (`file` or `url`).
  final String source;

  /// Original descriptor value, for diagnostics.
  final String originalValue;

  /// Stable content fingerprint used as the cache key.
  final String fingerprint;

  final int byteLength;
}

/// Thrown when an asset cannot be resolved. Carries a stable code and a
/// user-safe message; transport details stay inside the caught error.
class ModelAssetException implements ModelFailure {
  const ModelAssetException(this.code, this.message);

  @override
  final String code;
  @override
  final String message;

  @override
  String toString() => 'ModelAssetException($code): $message';
}

/// Downloads remote model bytes. Injected so tests can feed synthetic bytes
/// and production can supply an HTTP client without this module depending on
/// a networking package.
typedef ModelAssetDownloader = Future<List<int>> Function(Uri uri);

/// Supplies the base directory for downloaded model bytes. Production uses
/// path_provider's application cache directory; tests inject a temp directory.
typedef ModelCacheDirectoryProvider = Future<Directory> Function();

/// Application cache subdirectory for remote model bytes.
///
/// `Directory.systemTemp` is deliberately not used: the OS evicts temp files
/// between runs, which breaks offline stage use and forces redownloads.
/// The base provider is injectable; a failed lookup is a loud
/// [ModelAssetException] with a stable `cache-directory` code.
Future<Directory> modelCacheDirectory({
  ModelCacheDirectoryProvider? base,
}) async {
  try {
    final root = await (base ?? getApplicationCacheDirectory)();
    return Directory('${root.path}${Platform.pathSeparator}model-cache');
  } on Object catch (error) {
    throw ModelAssetException(
      'cache-directory',
      'The model cache directory is unavailable: $error',
    );
  }
}

/// Resolves [DisplayModel] assets against a deterministic cache directory.
class ModelAssetResolver {
  ModelAssetResolver({
    Directory? cacheDirectory,
    ModelCacheDirectoryProvider? cacheDirectoryProvider,
    ModelAssetDownloader? downloader,
    String Function(List<int> bytes)? fingerprint,
  })  : _cacheDirectory = cacheDirectory != null
            ? _fixedDirectory(cacheDirectory)
            : cacheDirectoryProvider ?? modelCacheDirectory,
        _downloader = downloader,
        _fingerprint = fingerprint ?? _defaultFingerprint {}

  /// Resolved on demand so a failed path_provider lookup only affects a remote
  /// asset that actually needs the cache.
  final ModelCacheDirectoryProvider _cacheDirectory;
  final ModelAssetDownloader? _downloader;

  static ModelCacheDirectoryProvider _fixedDirectory(Directory directory) =>
      () async => directory;

  final String Function(List<int> bytes) _fingerprint;

  /// A stable, collision-resistant cache key without a crypto dependency:
  /// two independent 64-bit FNV-1a passes over complementary seeds.
  /// This is a cache key, NOT a security hash; assets are user-supplied and
  /// the native renderer validates its own formats.
  static String _defaultFingerprint(List<int> bytes) {
    var a = 0xcbf29ce484222325;
    var b = 0x9e3779b97f4a7c15;
    for (final byte in bytes) {
      a = ((a ^ byte) * 0x100000001b3) & 0xffffffffffffffff;
      b = ((b + byte + (b << 6) + (b >> 2)) & 0xffffffffffffffff);
    }
    return a.toRadixString(16).padLeft(16, '0') +
        b.toRadixString(16).padLeft(16, '0');
  }

  /// Resolve a validated descriptor. Throws [ModelAssetException] for a
  /// missing/invalid ref, a missing local file, or a download failure.
  Future<ResolvedModelAsset> resolve(DisplayModel model) async {
    final problem = model.problem;
    if (problem != null) {
      throw ModelAssetException(model.problemCode ?? 'invalid-asset', problem);
    }
    final ref = model.asset!;
    final value = ref.value!.trim();
    return ref.source == 'url' ? _resolveRemote(value) : _resolveLocal(value);
  }

  Future<ResolvedModelAsset> _resolveLocal(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw const ModelAssetException(
        'missing-asset',
        'The model file does not exist on this device.',
      );
    }
    final bytes = await file.readAsBytes();
    return ResolvedModelAsset(
      path: file.absolute.path,
      source: 'file',
      originalValue: path,
      fingerprint: _fingerprint(bytes),
      byteLength: bytes.length,
    );
  }

  Future<ResolvedModelAsset> _resolveRemote(String value) async {
    final downloader = _downloader;
    if (downloader == null) {
      throw const ModelAssetException(
        'no-downloader',
        'Remote model assets need a downloader in this build.',
      );
    }
    final cache = await _cacheDirectory();
    final key = _fingerprint(value.codeUnits);
    final target = File('${cache.path}${Platform.pathSeparator}$key.bin');
    final List<int> bytes;
    try {
      bytes = await target.exists()
          ? await target.readAsBytes()
          : await downloader(Uri.parse(value));
    } catch (error) {
      throw ModelAssetException(
        'download-failed',
        'The model could not be downloaded (${error.runtimeType}).',
      );
    }
    if (!await target.exists()) {
      await cache.create(recursive: true);
      // Atomic rename: a partially written cache entry is never visible to
      // the renderer (port of anima-render's bundle cache, without the ZIP).
      final temp = File('${target.path}.tmp');
      try {
        await temp.writeAsBytes(bytes, flush: true);
        await temp.rename(target.path);
      } catch (error) {
        try {
          if (await temp.exists()) await temp.delete();
        } on Object {
          // Best-effort cleanup; the original error is the one that matters.
        }
        throw ModelAssetException(
          'cache-failed',
          'The model could not be cached (${error.runtimeType}).',
        );
      }
    }
    return ResolvedModelAsset(
      path: target.absolute.path,
      source: 'url',
      originalValue: value,
      fingerprint: _fingerprint(bytes),
      byteLength: bytes.length,
    );
  }
}
