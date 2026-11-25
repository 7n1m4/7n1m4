// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local orchestration for one display model: resolve once, load once,
// route lip-sync and emotion sinks, dispose on model change. The daemon is the
// sole owner of card state; nothing here writes back to it.

import 'dart:async';

import 'model_asset_resolver.dart';
import 'model_backend.dart';
import 'model_expression.dart';
import 'model_stage_state.dart';
import '../../speech/lip_sync_rms_data.dart';

import '../../ui/model_stage.dart';

/// Drives one model's lifecycle and client-local sinks.
///
/// The interface is deliberately small: `load`, `lipSync`, `emotion`, `clear`,
/// `dispose`. Callers never see cache paths, texture ids or method channels.
/// Stale async results are dropped by a monotonically increasing generation.
class ModelStageRuntime {
  ModelStageRuntime({
    required this._resolver,
    required this._backends,
    void Function(ModelStageSnapshot snapshot)? onChanged,
  }) : _onChanged = onChanged;

  final ModelAssetResolver _resolver;
  final ModelBackendRegistry _backends;
  void Function(ModelStageSnapshot)? _onChanged;

  int _generation = 0;
  ModelStageSnapshot _snapshot = const ModelStageSnapshot(
    status: ModelStageStatus.none,
  );

  NativeModelHandle? _handle;
  ModelBackend? _backend;
  final LipSyncSmoother _smoother = LipSyncSmoother();
  Duration _ambientElapsed = Duration.zero;
  int? _lastFrameSeq;
  int? _lastCueSeq;
  double? _lastAmbientPhase;

  ModelStageSnapshot get snapshot => _snapshot;

  void setOnChanged(void Function(ModelStageSnapshot snapshot)? callback) =>
      _onChanged = callback;

  /// Load the model named by [model], replacing any previous instance.
  /// Errors are captured in [ModelStageStatus.failed]; they never escape as
  /// an unhandled future.
  Future<void> load(DisplayModel model) async {
    final generation = ++_generation;
    await _clearHandle();
    if (model.kind == ModelKind.none) {
      _publish(const ModelStageSnapshot(status: ModelStageStatus.none));
      return;
    }
    _publish(const ModelStageSnapshot(status: ModelStageStatus.resolving));
    try {
      final asset = await _resolver.resolve(model);
      if (generation != _generation) return;
      _publish(
        ModelStageSnapshot(status: ModelStageStatus.loading, asset: asset),
      );
      final backend = _backends.backendFor(model.kind);
      final handle = await backend.load(asset);
      if (generation != _generation) {
        await backend.dispose(handle);
        return;
      }
      _backend = backend;
      _handle = handle;
      _publish(
        ModelStageSnapshot(
          status: ModelStageStatus.ready,
          handle: handle,
          asset: asset,
        ),
      );
    } catch (error) {
      if (generation != _generation) return;
      _publish(
        ModelStageSnapshot(status: ModelStageStatus.failed, error: error),
      );
    }
  }

  /// Apply a real, client-stamped RMS frame. Frames for other actors or with
  /// non-monotonic seq values are ignored so replayed audio cannot animate the
  /// mouth. The native backend receives a continuous weight in `[0, 1]`.
  Future<void> lipSync(LipSyncRmsData frame, {String? actorId}) async {
    if (actorId != null && frame.actorId != actorId) return;
    final last = _lastFrameSeq;
    if (last != null && frame.seq <= last) return;
    final handle = _handle;
    if (handle == null || _snapshot.status != ModelStageStatus.ready) return;
    _lastFrameSeq = frame.seq;
    final weight = _smoother.tick(frame.level, 1 / 30);
    await _backend!.setLipSync(handle, weight);
    _publish(
      ModelStageSnapshot(
        status: ModelStageStatus.ready,
        handle: handle,
        asset: _snapshot.asset,
        lipSyncWeight: weight,
        emotion: _snapshot.emotion,
      ),
    );
  }

  /// Apply one parsed `emotion.tag` cue. Stale/replayed cues are ignored; the
  /// backend decides how to blend expressions so unmanaged mouth/blink morphs
  /// survive an emotion switch.
  Future<void> emotion(StageExpressionCue cue) async {
    final last = _lastCueSeq;
    if (last != null && cue.seq <= last) return;
    final handle = _handle;
    if (handle == null || _snapshot.status != ModelStageStatus.ready) return;
    _lastCueSeq = cue.seq;
    await _backend!.setEmotion(handle, cue);
    _publish(
      ModelStageSnapshot(
        status: ModelStageStatus.ready,
        handle: handle,
        asset: _snapshot.asset,
        lipSyncWeight: _snapshot.lipSyncWeight,
        emotion: cue,
      ),
    );
  }

  /// Apply an ambient phase to the model. Returns early when not ready or when
  /// the phase is unchanged.
  Future<void> ambient(double phase, {Duration elapsed = Duration.zero}) async {
    final handle = _handle;
    if (handle == null || _snapshot.status != ModelStageStatus.ready) return;
    if (elapsed <= _ambientElapsed) return;
    if (phase == _lastAmbientPhase) return;
    _ambientElapsed = elapsed;
    _lastAmbientPhase = phase;
    await _backend!.setAmbientPhase(handle, phase);
    _publish(
      ModelStageSnapshot(
        status: ModelStageStatus.ready,
        handle: handle,
        asset: _snapshot.asset,
        lipSyncWeight: _snapshot.lipSyncWeight,
        emotion: _snapshot.emotion,
        ambientElapsed: elapsed,
      ),
    );
  }

  /// Clear the model and release its native handle.
  Future<void> clear() async {
    _generation++;
    await _clearHandle();
    _lastFrameSeq = null;
    _lastCueSeq = null;
    _ambientElapsed = Duration.zero;
    _lastAmbientPhase = null;
    _smoother.reset();
    _publish(const ModelStageSnapshot(status: ModelStageStatus.none));
  }

  Future<void> dispose() => clear();

  Future<void> _clearHandle() async {
    final handle = _handle;
    final backend = _backend;
    _handle = null;
    _backend = null;
    _ambientElapsed = Duration.zero;
    _lastAmbientPhase = null;
    if (handle != null && backend != null) {
      await backend.dispose(handle);
    }
  }

  void _publish(ModelStageSnapshot snapshot) {
    _snapshot = snapshot;
    _onChanged?.call(snapshot);
  }
}
