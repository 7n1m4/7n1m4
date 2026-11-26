// SPDX-License-Identifier: GPL-3.0-or-later

// The seam between the client-local stage runtime and each native renderer.
// A backend owns one loaded model and translates the small runtime vocabulary
// (load / lip-sync / emotion / ambient / dispose) into calls on the platform side. It
// knows nothing about cards, daemon RPC or asset discovery.

import 'model_asset_resolver.dart';
import 'model_failure.dart';
import 'model_expression.dart';
import 'model_runtime.dart';
import '../../ui/model_stage.dart';

/// Identity of a loaded native model instance.
class NativeModelHandle {
  const NativeModelHandle(this.id, {this.textureId});

  final String id;

  /// Optional Flutter GPU/PlatformView texture id used by the surface widget.
  final int? textureId;
}

/// Adapter to one platform model renderer (VRM, Spine, MMD, Live2D).
abstract class ModelBackend {
  /// Kind this adapter can load.
  ModelKind get kind;

  /// Load [asset] and return an opaque handle. Must throw on failure; never
  /// return a handle to an unloaded model.
  Future<NativeModelHandle> load(ResolvedModelAsset asset);

  /// Set a continuous mouth-open weight in `[0, 1]`.
  Future<void> setLipSync(NativeModelHandle handle, double weight);

  /// Apply one expression/motion cue by semantic tag.
  Future<void> setEmotion(NativeModelHandle handle, StageExpressionCue cue);

  /// Set a continuous idle/ambient motion phase in `[0, 1]`.
  /// Backends without an ambient channel keep the default no-op below.
  Future<void> setAmbientPhase(NativeModelHandle handle, double phase);

  /// Release all native resources for [handle]. Must be idempotent.
  Future<void> dispose(NativeModelHandle handle);
}

/// A backend that cannot load anything, used when the runtime is blocked by
/// licensing or an absent native library. It reports the reason loudly so the
/// stage never paints a fabricated model.
class UnavailableModelBackend implements ModelBackend {
  const UnavailableModelBackend(this.kind, this.blocker);

  @override
  final ModelKind kind;

  final ModelRuntimeBlocker blocker;

  @override
  Future<NativeModelHandle> load(ResolvedModelAsset asset) async {
    throw ModelBackendException(
      'runtime-unavailable',
      blocker == ModelRuntimeBlocker.cubismLicense
          ? 'Live2D needs a user-fetched Cubism Core; the runtime is not '
                'available in this build.'
          : 'The native renderer for ${kind.name} is not available in this build.',
    );
  }

  @override
  Future<void> setLipSync(NativeModelHandle handle, double weight) async {}

  @override
  Future<void> setEmotion(
    NativeModelHandle handle,
    StageExpressionCue cue,
  ) async {}

  @override
  Future<void> setAmbientPhase(NativeModelHandle handle, double phase) async {}

  @override
  Future<void> dispose(NativeModelHandle handle) async {}
}

/// A loud, typed native-renderer failure.
class ModelBackendException implements ModelFailure {
  const ModelBackendException(this.code, this.message);

  @override
  final String code;
  @override
  final String message;

  @override
  String toString() => 'ModelBackendException($code): $message';
}

/// Registry mapping a kind to its backend. Injected into the runtime so tests
/// substitute a recording backend without platform channels.
class ModelBackendRegistry {
  ModelBackendRegistry(Map<ModelKind, ModelBackend> backends)
    : _backends = Map<ModelKind, ModelBackend>.unmodifiable(backends);

  final Map<ModelKind, ModelBackend> _backends;

  /// Builds the default registry: unavailable adapters are still registered
  /// so a blocked kind fails loudly instead of throwing a missing-key error.
  factory ModelBackendRegistry.fromRuntimes({
    ModelBackend Function(ModelRuntimeInfo info)? create,
    Set<ModelKind>? supportedKinds,
  }) {
    final backends = <ModelKind, ModelBackend>{};
    for (final info in kModelRuntimes) {
      final blocker = info.blocker ??
          (supportedKinds != null && !supportedKinds.contains(info.kind)
              ? ModelRuntimeBlocker.missingRuntime
              : null);
      backends[info.kind] = blocker == null
          ? create?.call(info) ??
                UnavailableModelBackend(
                  info.kind,
                  ModelRuntimeBlocker.missingRuntime,
                )
          : UnavailableModelBackend(info.kind, blocker);
    }
    return ModelBackendRegistry(backends);
  }

  ModelBackend backendFor(ModelKind kind) {
    final backend = _backends[kind];
    if (backend == null) {
      throw ModelBackendException(
        'unknown-kind',
        'No native renderer is registered for ${kind.name}.',
      );
    }
    return backend;
  }
}

/// A minimal in-memory backend for widget tests. Records the exact sink calls
/// so the runtime's smoothing and cue semantics are observable without a GPU.
class RecordingModelBackend implements ModelBackend {
  RecordingModelBackend(this.kind);

  @override
  final ModelKind kind;

  final List<double> lipSyncWeights = <double>[];
  final List<StageExpressionCue> emotions = <StageExpressionCue>[];
  final List<double> ambientPhases = <double>[];
  final List<ResolvedModelAsset> loaded = <ResolvedModelAsset>[];
  final List<NativeModelHandle> disposed = <NativeModelHandle>[];
  int _next = 0;
  Future<void> Function(ResolvedModelAsset)? onLoad;

  @override
  Future<NativeModelHandle> load(ResolvedModelAsset asset) async {
    await onLoad?.call(asset);
    loaded.add(asset);
    return NativeModelHandle(
      'recording-${kind.name}-${_next++}',
      textureId: _next,
    );
  }

  @override
  Future<void> setLipSync(NativeModelHandle handle, double weight) async {
    lipSyncWeights.add(weight);
  }

  @override
  Future<void> setEmotion(
    NativeModelHandle handle,
    StageExpressionCue cue,
  ) async {
    emotions.add(cue);
  }

  @override
  Future<void> setAmbientPhase(NativeModelHandle handle, double phase) async {
    ambientPhases.add(phase);
  }

  @override
  Future<void> dispose(NativeModelHandle handle) async {
    disposed.add(handle);
  }
}
