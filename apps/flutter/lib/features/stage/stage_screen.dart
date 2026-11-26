// SPDX-License-Identifier: GPL-3.0-or-later

// Stage destination: one card's display-model surface plus the parity
// surfaces that need no native renderer — caption/subtitle overlay, background
// layers, the control-strip host and the emotion/motion cue readout.
//
// The shell picks the card; this screen supplies the production native
// backends and asset cache to [ModelStage], which owns the `cards.get` read,
// kind routing and the loud failure when the card names an unresolvable asset.
// Everything the overlays show is client-local render state; the daemon keeps
// ownership of cards, sessions and settings.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../daemon_client/daemon_client.dart';
import '../../speech/lip_sync_rms_data.dart';
import '../../ui/model_stage.dart';
import 'method_channel_backend.dart';
import 'model_asset_resolver.dart';
import 'model_backend.dart';
import 'model_runtime.dart';
import 'stage_background.dart';
import 'stage_control_strip.dart';
import 'stage_control_strip_state.dart';
import 'stage_overlay_state.dart';
import 'stage_overlays.dart';

/// Stage destination.
class StageScreen extends StatefulWidget {
  const StageScreen({
    super.key,
    required this.client,
    this.cardId,
    this.frames,
    this.actorId,
    this.backends,
    this.resolver,
    this.cacheDirectoryProvider,
    this.background,
    this.captionStyle,
    this.stripState,
    this.render,
    this.paused,
  });

  final DaemonClient client;

  /// Card to display; null renders the no-model placeholder.
  final String? cardId;

  /// Real stamped RMS frames from the local TTS pipeline, when available.
  final Stream<LipSyncRmsData>? frames;

  /// Optional actor filter for frames and emotion cues.
  final String? actorId;

  /// Optional backend registry override for embedding/tests
  final ModelBackendRegistry? backends;

  /// Optional asset resolver override for embedding/tests
  final ModelAssetResolver? resolver;

  /// Injectable model cache directory for tests; production uses the
  /// application cache directory via `path_provider`.
  final ModelCacheDirectoryProvider? cacheDirectoryProvider;

  /// Client-local backdrop; defaults to none.
  final StageBackground? background;

  /// Caption appearance; defaults to the daemon's own defaults.
  final StageCaptionStyle? captionStyle;

  /// Control-strip host state; defaults to the platform defaults.
  final StageControlStripState? stripState;

  /// Client-local render state shared with the native surface. The shell owns
  /// it so hidden stages can be paused without rebuilding the widget.
  final StageRenderState? render;

  /// Stop the ambient ticker while this stage is hidden in an IndexedStack.
  final bool? paused;

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  late final ModelBackendRegistry _backends;
  late final ModelAssetResolver _resolver;
  late final StageRenderState _render;
  late StageControlStripState _strip;
  StageRenderStateBinding? _binding;
  StreamSubscription<LipSyncRmsData>? _frameSubscription;

  @override
  void initState() {
    super.initState();
    _backends =
        widget.backends ??
        ModelBackendRegistry.fromRuntimes(
          supportedKinds: supportedModelKinds(defaultTargetPlatform).toSet(),
          create: (ModelRuntimeInfo info) =>
              MethodChannelModelBackend(info.kind, info.channelName),
        );
    _resolver = widget.resolver ??
        ModelAssetResolver(cacheDirectoryProvider: widget.cacheDirectoryProvider);
    _render = widget.render ??
        StageRenderState(
          background: widget.background ?? StageBackground.none,
          captions: widget.captionStyle ?? const StageCaptionStyle(),
          actorId: widget.actorId,
          paused: widget.paused ?? false,
        );
    _strip = widget.stripState ?? StageControlStripState();
    _render.addListener(_onRenderChanged);
    _binding = StageRenderStateBinding(client: widget.client, state: _render);
    final frames = widget.frames;
    if (frames != null) _frameSubscription = frames.listen(_render.applyFrame);
  }

  @override
  void didUpdateWidget(StageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.client != widget.client) {
      _binding?.dispose();
      _binding = StageRenderStateBinding(client: widget.client, state: _render);
    }

    if (oldWidget.actorId != widget.actorId) _render.setActorId(widget.actorId);
    if (widget.paused != null && oldWidget.paused != widget.paused) {
      _render.setPaused(widget.paused!);
    }
    if (!identical(oldWidget.render, widget.render) && widget.render != null) {
      _render = widget.render!;
    }
    if (oldWidget.background != widget.background) {
      _render.setBackground(widget.background ?? StageBackground.none);
    }
    if (oldWidget.captionStyle != widget.captionStyle) {
      _render.setCaptionStyle(widget.captionStyle ?? const StageCaptionStyle());
    }
    if (oldWidget.stripState != widget.stripState) {
      _strip = widget.stripState ?? StageControlStripState();
    }
    if (oldWidget.frames != widget.frames) {
      _frameSubscription?.cancel();
      _frameSubscription = widget.frames?.listen(_render.applyFrame);
    }
  }

  @override
  void dispose() {
    _render.removeListener(_onRenderChanged);
    if (widget.render == null) _render.dispose();
    _frameSubscription?.cancel();
    _binding?.dispose();
    super.dispose();
  }

  void _onRenderChanged() {
    if (mounted) setState(() {});
  }

  void _onStripAction(StageStripAction action) {
    // Only the expand notch has a local effect; the rest is reported intent
    // for a future daemon-owned panel dispatch.
    if (action.buttonId == '__expand') {
      _strip.setCollapsed(false);
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return StageOverlays(
      state: _render,
      strip: StageControlStrip(state: _strip, onAction: _onStripAction),
      model: ModelStage(
        client: widget.client,
        cardId: widget.cardId,
        render: _render,
        backends: _backends,
        resolver: _resolver,
        cacheDirectoryProvider: widget.cacheDirectoryProvider,
        frames: widget.frames,
        actorId: widget.actorId,
      ),
    );
  }
}
