// SPDX-License-Identifier: GPL-3.0-or-later

// Concrete platform-channel adapter for each native model renderer. The Dart
// side owns lifecycle and sink semantics; the platform side owns decoding,
// GPU textures and animation. The channel names declared in model_runtime.dart
// are the cross-language contract for these methods and argument keys.

import 'dart:async';

import 'package:flutter/services.dart';

import 'model_backend.dart';
import 'model_expression.dart';
import 'model_runtime.dart';
import '../../ui/model_stage.dart';
import 'model_asset_resolver.dart';

/// Calls one native renderer over a dedicated method channel.
///
/// Channel: `org.moeru.airi/anima/model/<kind>` (see [ModelRuntimeInfo]).
/// Methods: `load(path)`, `setLipSync(handle, weight)`,
/// `setEmotion(handle, tag, kind, intensity, seq, tsMs)`, `dispose(handle)`.
/// A failed call is surfaced as [ModelBackendException], never swallowed.
class MethodChannelModelBackend implements ModelBackend {
  MethodChannelModelBackend(
    this.kind,
    this.channelName, {
    MethodChannel? channel,
  }) : _channel = channel ?? MethodChannel(channelName);

  @override
  final ModelKind kind;
  final String channelName;
  final MethodChannel _channel;

  @override
  Future<NativeModelHandle> load(ResolvedModelAsset asset) async {
    final reply = await _call<Map<dynamic, dynamic>>('load', <String, dynamic>{
      'path': asset.path,
      'source': asset.source,
    });
    final id = reply['handle'];
    if (id is! String || id.isEmpty) {
      throw const ModelBackendException(
        'invalid-handle',
        'The native renderer returned no model handle.',
      );
    }
    final texture = reply['textureId'];
    return NativeModelHandle(id, textureId: texture is int ? texture : null);
  }

  @override
  Future<void> setLipSync(NativeModelHandle handle, double weight) =>
      _call<void>('setLipSync', <String, dynamic>{
        'handle': handle.id,
        'weight': weight,
      });

  @override
  Future<void> setEmotion(NativeModelHandle handle, StageExpressionCue cue) =>
      _call<void>('setEmotion', <String, dynamic>{
        'handle': handle.id,
        'tag': cue.tag,
        'kind': cue.kind,
        'intensity': cue.intensity,
        'seq': cue.seq,
        'tsMs': cue.tsMs,
      });

  @override
  Future<void> setAmbientPhase(NativeModelHandle handle, double phase) =>
      _call<void>('setAmbientPhase', <String, dynamic>{
        'handle': handle.id,
        'phase': phase,
      });

  @override
  Future<void> dispose(NativeModelHandle handle) =>
      _call<void>('dispose', <String, dynamic>{'handle': handle.id});

  Future<T> _call<T>(String method, Map<String, dynamic> arguments) async {
    try {
      final result = await _channel.invokeMethod<T>(method, arguments);
      return result as T;
    } on MissingPluginException {
      throw ModelBackendException(
        'runtime-unavailable',
        'No native ${kind.name} renderer is registered on this platform.',
      );
    } on PlatformException catch (error) {
      throw ModelBackendException(
        error.code.isEmpty ? 'native-error' : error.code,
        error.message ?? 'The native ${kind.name} renderer failed.',
      );
    }
  }
}
