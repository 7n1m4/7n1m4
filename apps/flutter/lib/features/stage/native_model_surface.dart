// SPDX-License-Identifier: GPL-3.0-or-later

// The Flutter surface for one loaded native model. It owns only client-local
// render state: the DaemonClient supplies `cards.get` and the `emotion.tag`
// lane, the resolver provides a local file, and the native side draws into the
// texture id returned by the backend.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import 'model_asset_resolver.dart';
import 'model_backend.dart';
import 'model_expression.dart';
import 'model_failure.dart';
import 'model_stage_runtime.dart';
import 'model_stage_state.dart';
import 'stage_overlay_state.dart';
import 'stage_overlays.dart';
import '../../daemon_client/daemon_client.dart';
import '../../speech/lip_sync_rms_data.dart';
import '../../ui/model_stage.dart';

/// Renders [model] with an injected native backend registry.
///
/// [frames], when provided, must be real `LipSyncRmsData` from the local TTS
/// pipeline (`LipSyncController.frames`). No frames are fabricated and no
/// model is painted until the native handle is ready.
class NativeModelSurface extends StatefulWidget {
  const NativeModelSurface({
    super.key,
    required this.client,
    required this.model,
    required this.backends,
    required this.resolver,
    this.frames,
    this.actorId,
    this.render,
  });

  final DaemonClient client;
  final DisplayModel model;
  final ModelBackendRegistry backends;
  final ModelAssetResolver resolver;

  /// Real stamped RMS frames from the local TTS pipeline, when available.
  final Stream<LipSyncRmsData>? frames;

  /// Optional actor filter for frames and emotion cues.
  final String? actorId;

  /// Client-local render state shared with the stage shell's overlays. When
  /// null the surface keeps a private one.
  final StageRenderState? render;

  @override
  State<NativeModelSurface> createState() => _NativeModelSurfaceState();
}

class _NativeModelSurfaceState extends State<NativeModelSurface>
    with SingleTickerProviderStateMixin {
  late final ModelStageRuntime _runtime;
  Ticker? _ambientTicker;
  StreamSubscription<LipSyncRmsData>? _frameSubscription;
  void Function()? _unsubscribe;
  StageRenderState? _privateRender;
  ModelStageSnapshot _snapshot = const ModelStageSnapshot(
    status: ModelStageStatus.resolving,
  );

  StageRenderState get _render =>
      widget.render ??
      (_privateRender ??= StageRenderState(actorId: widget.actorId));

  @override
  void initState() {
    super.initState();
    // Mount-time only: this runs inside initState, so it must not notify.
    _render.setActorId(widget.actorId, notify: false);
    _runtime = ModelStageRuntime(
      resolver: widget.resolver,
      backends: widget.backends,
      onChanged: _onChanged,
    );
    _unsubscribe = widget.client.onEvent(_onEvent);
    final frames = widget.frames;
    if (frames != null) {
      _frameSubscription = frames.listen(_onFrame);
    }
    _runtime.load(widget.model);
    _syncAmbientTicker();
  }

  void _onAmbientTick(Duration elapsed) {
    _render.tickAmbient(elapsed);
    _runtime.ambient(_render.idlePhase, elapsed: _render.ambientElapsed);
  }

  void _syncAmbientTicker() {
    if (_snapshot.status == ModelStageStatus.ready &&
        !_render.paused &&
        TickerMode.of(context)) {
      _ambientTicker ??= createTicker(_onAmbientTick);
      if (!_ambientTicker!.isActive) _ambientTicker!.start();
    } else {
      _ambientTicker?.stop();
    }
  }

  @override
  void didUpdateWidget(NativeModelSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _unsubscribe?.call();
      _unsubscribe = widget.client.onEvent(_onEvent);
    }
    if (oldWidget.actorId != widget.actorId) {
      _render.beginFollowing(actorId: widget.actorId);
    }
    if (oldWidget.model.kind != widget.model.kind ||
        oldWidget.model.asset?.value != widget.model.asset?.value) {
      _runtime.load(widget.model);
    }
    if (oldWidget.frames != widget.frames) {
      _frameSubscription?.cancel();
      _frameSubscription = widget.frames?.listen(_onFrame);
    }
  }

  @override
  void dispose() {
    _ambientTicker?.dispose();
    _ambientTicker = null;
    _frameSubscription?.cancel();
    _unsubscribe?.call();
    _runtime.dispose();
    // The shared render state belongs to the stage shell; only a private one
    // is owned here.
    _privateRender?.dispose();
    super.dispose();
  }

  void _onChanged(ModelStageSnapshot snapshot) {
    if (!mounted) return;
    setState(() => _snapshot = snapshot);
    _syncAmbientTicker();
  }

  void _onFrame(LipSyncRmsData frame) {
    _render.applyFrame(frame);
    _runtime.lipSync(frame, actorId: widget.actorId);
  }

  void _onEvent(GatewayEventFrame event) {
    if (event.topic != EventTopic.emotionTag) return;
    final cue = parseExpressionCue(event.data, actorId: widget.actorId);
    if (cue == null) return;
    _render.applyCue(cue);
    _runtime.emotion(cue);
  }

  @override
  Widget build(BuildContext context) {
    return switch (_snapshot.status) {
      ModelStageStatus.failed => _Failure(snapshot: _snapshot),
      ModelStageStatus.ready => _Ready(snapshot: _snapshot, render: _render),
      ModelStageStatus.none ||
      ModelStageStatus.resolving ||
      ModelStageStatus.loading => const Center(
        child: CircularProgressIndicator(),
      ),
    };
  }
}

class _Ready extends StatelessWidget {
  const _Ready({required this.snapshot, required this.render});

  final ModelStageSnapshot snapshot;
  final StageRenderState render;

  @override
  Widget build(BuildContext context) {
    final handle = snapshot.handle!;
    final textureId = handle.textureId;
    final subtle = Theme.of(context).colorScheme.onSurfaceVariant;
    return Semantics(
      label: 'Native model ready',
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (textureId != null)
            SizedBox.expand(child: Texture(textureId: textureId))
          else
            Center(
              child: Icon(Icons.view_in_ar_outlined, size: 96, color: subtle),
            ),
          // Always mounted: the readout is 'mouth N%' until a cue arrives.
          StageCueBadge(state: render),
        ],
      ),
    );
  }
}

class _Failure extends StatelessWidget {
  const _Failure({required this.snapshot});

  final ModelStageSnapshot snapshot;

  String _message(Object? error) {
    if (error is ModelFailure) return error.message;
    return 'The native model could not be loaded '
        '(${error?.runtimeType ?? 'unknown error'}).';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Semantics(
        label: 'Model stage error: ${_message(snapshot.error)}',
        child: Card(
          color: colorScheme.errorContainer,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(Icons.error_outline, color: colorScheme.error),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    _message(snapshot.error),
                    style: TextStyle(color: colorScheme.error),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
