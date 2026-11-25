// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local render state for one display model. The daemon owns card state;
// this machine owns only what happens on this device after `cards.get`:
// resolving, loading, showing, and disposing a native model instance.

import 'model_backend.dart' show NativeModelHandle;
import 'model_asset_resolver.dart';
import 'model_expression.dart';
import 'model_failure.dart';

/// Lifecycle of one client-local model instance.
enum ModelStageStatus {
  /// No card or no model named by the card.
  none,

  /// Resolving the descriptor to a local asset.
  resolving,

  /// Native backend is loading the asset.
  loading,

  /// Native handle is live and can receive lip-sync and emotion cues.
  ready,

  /// A loud, typed failure; no model is shown.
  failed,
}

/// Immutable snapshot of [ModelStageRuntime] state.
class ModelStageSnapshot {
  const ModelStageSnapshot({
    required this.status,
    this.handle,
    this.asset,
    this.error,
    this.lipSyncWeight = 0,
    this.emotion,
    this.ambientElapsed = Duration.zero,
  });

  final ModelStageStatus status;
  final NativeModelHandle? handle;
  final ResolvedModelAsset? asset;
  final Object? error;
  final double lipSyncWeight;
  final StageExpressionCue? emotion;

  /// Elapsed wall-clock time while this model has been the active stage model.
  final Duration ambientElapsed;

  bool get isReady => status == ModelStageStatus.ready;
}

/// A loud, typed stage-runtime failure. Nothing is fabricated in its place.
class ModelStageRuntimeException implements ModelFailure {
  const ModelStageRuntimeException(this.code, this.message);

  @override
  final String code;
  @override
  final String message;

  @override
  String toString() => 'ModelStageRuntimeException($code): $message';
}
