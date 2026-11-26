// SPDX-License-Identifier: GPL-3.0-or-later

// The Dart half of the frozen native render/texture contract.
//
// Dart never sees vertices, draws or pages. It drives one loaded model through
// a small lifecycle (load / setLipSync / setEmotion / setAmbientPhase /
// dispose) over the frozen method channel `org.moeru.airi/anima/model/<kind>`
// and holds only the opaque integer texture id the platform returns. The
// platform side (crates/anima-render/cpp/render_contract.{h,cpp}) registers
// one GPU texture per model and releases it on dispose.

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// The frozen method-channel prefix; the full channel is `<prefix><kind>`.
const String kAnimaRenderChannelPrefix = 'org.moeru.airi/anima/model/';

/// A loaded native model's render surface: an opaque GPU texture id plus the
/// lifecycle methods that drive it.
///
/// The instance is obtained from [FlutterAnimaRender.load] and is the only
/// object the stage holds. [textureId] is the integer the platform minted for
/// this model's output; [dispose] releases the native resources and the
/// texture. [dispose] is idempotent.
class NativeRenderTexture {
  NativeRenderTexture._(
    this._channel,
    this._handle,
    this.textureId,
    this._onTextureReleased,
  );

  final MethodChannel _channel;
  final String _handle;
  final int textureId;
  final void Function(int textureId)? _onTextureReleased;

  bool _disposed = false;

  /// Set a continuous mouth-open weight in `[0, 1]`.
  Future<void> setLipSync(double weight) => _invoke('setLipSync', <String, dynamic>{
    'handle': _handle,
    'weight': weight,
  });

  /// Apply one expression/motion cue by semantic tag.
  Future<void> setEmotion({
    required String tag,
    required String kind,
    required double intensity,
    required int seq,
    required int tsMs,
  }) => _invoke('setEmotion', <String, dynamic>{
    'handle': _handle,
    'tag': tag,
    'kind': kind,
    'intensity': intensity,
    'seq': seq,
    'tsMs': tsMs,
  });

  /// Set a continuous idle/ambient motion phase in `[0, 1]`.
  Future<void> setAmbientPhase(double phase) => _invoke('setAmbientPhase', <String, dynamic>{
    'handle': _handle,
    'phase': phase,
  });

  /// Release the native model and its texture. Idempotent; a disposed
  /// instance ignores further calls.
  Future<void> dispose() async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>('dispose', <String, dynamic>{'handle': _handle});
    } on MissingPluginException {
      throw const NativeRenderException(
        'runtime-unavailable',
        'No native renderer is registered on this platform.',
      );
    } on PlatformException catch (error) {
      throw NativeRenderException(
        error.code.isEmpty ? 'native-error' : error.code,
        error.message ?? 'The native renderer failed.',
      );
    } finally {
      _disposed = true;
      _onTextureReleased?.call(textureId);
    }
  }

  /// Whether [dispose] has already run.
  bool get isDisposed => _disposed;

  Future<void> _invoke(String method, Map<String, dynamic> args) async {
    if (_disposed) return;
    try {
      await _channel.invokeMethod<void>(method, args);
    } on MissingPluginException {
      throw const NativeRenderException(
        'runtime-unavailable',
        'No native renderer is registered on this platform.',
      );
    } on PlatformException catch (error) {
      throw NativeRenderException(
        error.code.isEmpty ? 'native-error' : error.code,
        error.message ?? 'The native renderer failed.',
      );
    }
  }
}

/// A loud, typed native-renderer failure.
class NativeRenderException implements Exception {
  const NativeRenderException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'NativeRenderException($code): $message';
}

/// The plugin entry point: loads models of one kind and hands back opaque
/// [NativeRenderTexture] handles. Construct one per kind with the frozen
/// channel name.
class FlutterAnimaRender {
  FlutterAnimaRender(this.kind, [this._onTextureReleased])
    : channel = MethodChannel('$kAnimaRenderChannelPrefix$kind');

  /// The model kind suffix (`vrm`, `spine`, `mmd`, `live2d`).
  final String kind;
  final MethodChannel channel;
  final void Function(int textureId)? _onTextureReleased;

  /// Load the model at [assetPath] (a local file or bundle root) and return
  /// its render surface. Throws [NativeRenderException] on failure; never
  /// returns a handle to an unloaded model.
  Future<NativeRenderTexture> load(String assetPath) async {
    Map<dynamic, dynamic>? reply;
    try {
      reply = await channel.invokeMethod<Map<dynamic, dynamic>>('load', <String, dynamic>{
        'path': assetPath,
      });
    } on MissingPluginException {
      throw const NativeRenderException(
        'runtime-unavailable',
        'No native renderer is registered on this platform.',
      );
    } on PlatformException catch (error) {
      throw NativeRenderException(
        error.code.isEmpty ? 'native-error' : error.code,
        error.message ?? 'The native renderer failed.',
      );
    }
    if (reply == null) {
      throw const NativeRenderException(
        'invalid-handle',
        'The native renderer returned no reply.',
      );
    }
    final id = reply['handle'];
    if (id is! String || id.isEmpty) {
      throw const NativeRenderException(
        'invalid-handle',
        'The native renderer returned no model handle.',
      );
    }
    final texture = reply['textureId'];
    if (texture is! int) {
      throw const NativeRenderException(
        'invalid-texture',
        'The native renderer returned no texture id.',
      );
    }
    return NativeRenderTexture._(
      channel,
      id,
      texture,
      _onTextureReleased,
    );
  }
}

/// The [Texture] widget the stage paints for a [NativeRenderTexture].
///
/// The stage never sees the texture id directly; it holds the
/// [NativeRenderTexture] and renders this widget, which is bound to
/// [NativeRenderTexture.textureId].
Widget buildNativeRenderTextureWidget(NativeRenderTexture texture) {
  return Texture(textureId: texture.textureId);
}