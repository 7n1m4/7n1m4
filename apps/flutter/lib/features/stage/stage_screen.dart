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
import 'dart:io';

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
    this.background,
    this.captionStyle,
    this.stripState,
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

  /// Client-local backdrop; defaults to none.
  final StageBackground? background;

  /// Caption appearance; defaults to the daemon's own defaults.
  final StageCaptionStyle? captionStyle;

  /// Control-strip host state; defaults to the platform defaults.
  final StageControlStripState? stripState;

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
          create: (ModelRuntimeInfo info) =>
              MethodChannelModelBackend(info.kind, info.channelName),
        );
    _resolver =
        widget.resolver ??
        ModelAssetResolver(cacheDirectory: Directory.systemTemp);
    _render = StageRenderState(
      background: widget.background ?? StageBackground.none,
      captions: widget.captionStyle ?? const StageCaptionStyle(),
      actorId: widget.actorId,
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
    _render.dispose();
    _frameSubscription?.cancel();
    _binding?.dispose();
    super.dispose();
  }

  void _onRenderChanged() {
    if (mounted) setState(() {});
  }

  void _onStripAction(StageStripAction action) {
    // The strip reports intent; the daemon owns the state behind it. Only the
    // transient host state is mutated locally.
    switch (action.buttonId) {
      case '__expand':
        _strip.setCollapsed(false);
      default:
        _strip.togglePanel(action.buttonId);
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return StageOverlays(
      state: _render,
      strip: StageControlStrip(state: _strip, onAction: _onStripAction),
      model: ModelStage(
        client: widget.client,
        cardId: widget.cardId,
        backends: _backends,
        resolver: _resolver,
        frames: widget.frames,
        actorId: widget.actorId,
        render: _render,
      ),
    );
  }
}
