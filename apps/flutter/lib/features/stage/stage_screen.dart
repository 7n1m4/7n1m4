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
import 'model_stage_state.dart';
import 'presence_status_chip.dart';
import 'resource_status_island.dart';
import 'stage_atmosphere.dart';
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
    this.boundSessionId,
    this.stripState,
    this.render,
    this.paused,
    this.resourceStatus = ModelStageStatus.none,
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

  /// Active chat session whose `token.delta` frames may drive captions.
  /// Null keeps the binding's self-learn fallback for callers that do not
  /// plumb the shell's session.
  final String? boundSessionId;

  /// Control-strip host state; defaults to the platform defaults.
  final StageControlStripState? stripState;

  /// Client-local render state shared with the native surface. The shell owns
  /// it so hidden stages can be paused without rebuilding the widget.
  final StageRenderState? render;

  /// Stop the ambient ticker while this stage is hidden in an IndexedStack.
  final bool? paused;

  /// Model-loading status for the delayed resource-status pill. The native
  /// runtime owns the live value; the shell supplies it when wired. `none`
  /// keeps the pill hidden with no behavior change for existing callers.
  final ModelStageStatus resourceStatus;

  @override
  State<StageScreen> createState() => _StageScreenState();
}

class _StageScreenState extends State<StageScreen> {
  late final ModelBackendRegistry _backends;
  late final ModelAssetResolver _resolver;
  late StageRenderState _render;
  StageRenderState? _boundRender;
  late StageControlStripState _strip;
  StageRenderStateBinding? _binding;
  StreamSubscription<LipSyncRmsData>? _frameSubscription;
  late ModelStageStatus _resourceStatus;

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
    if (widget.render != null &&
        (widget.background != null ||
            widget.captionStyle != null ||
            widget.actorId != null ||
            widget.paused != null)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !identical(_render, widget.render)) return;
        if (widget.background != null) {
          _render.setBackground(widget.background!);
        }
        if (widget.captionStyle != null) {
          _render.setCaptionStyle(widget.captionStyle!);
        }
        if (widget.actorId != null) _render.setActorId(widget.actorId);
        if (widget.paused != null) _render.setPaused(widget.paused!);
      });
    }
    _render.addListener(_onRenderChanged);
    _resourceStatus = widget.resourceStatus;
    _strip = widget.stripState ?? StageControlStripState();
    _boundRender = _render;
    _binding = StageRenderStateBinding(
      client: widget.client,
      state: _render,
      boundSessionId: widget.boundSessionId,
    );
    final frames = widget.frames;
    if (frames != null) _frameSubscription = frames.listen(_render.applyFrame);
  }

  /// Retarget the caption session filter in place. The stage mounts before a
  /// chat session is chosen, so the filter must follow the shell's id. Dispose
  /// queues its unsubscribe before any await, so a session-only recreate would
  /// tear down and re-subscribe the topic; retargeting in place avoids caption
  /// churn and needless daemon RPCs.
  void _rebindSessionFilter() {
    _binding?.setBoundSessionId(widget.boundSessionId);
  }

  /// Replace the event-lane binding when its client or render surface changes.
  /// Both are fixed for a binding's lifetime, so unlike a session change these
  /// really do need a fresh subscribe.
  void _recreateBinding() {
    _binding?.dispose();
    _binding = StageRenderStateBinding(
      client: widget.client,
      state: _render,
      boundSessionId: widget.boundSessionId,
    );
  }

  @override
  void didUpdateWidget(StageScreen oldWidget) {
    super.didUpdateWidget(oldWidget);

    final clientChanged = oldWidget.client != widget.client;
    final renderChanged =
        !identical(oldWidget.render, widget.render) && widget.render != null;
    final sessionChanged = oldWidget.boundSessionId != widget.boundSessionId;

    // An injected status (tests/embeds) wins over the live runtime report.
    if (widget.resourceStatus != oldWidget.resourceStatus) {
      _resourceStatus = widget.resourceStatus;
    }

    if (oldWidget.actorId != widget.actorId) _render.setActorId(widget.actorId);
    if (widget.paused != null && oldWidget.paused != widget.paused) {
      _render.setPaused(widget.paused!);
    }
    if (renderChanged) {
      _render.removeListener(_onRenderChanged);
      if (oldWidget.render == null) _render.dispose();
      _render = widget.render!;
      _render.addListener(_onRenderChanged);
      _boundRender = _render;
      _frameSubscription?.cancel();
      _frameSubscription = widget.frames?.listen(_render.applyFrame);
      if (widget.paused != null) _render.setPaused(widget.paused!);
      if (widget.background != null) {
        _render.setBackground(widget.background!);
      }
      if (widget.captionStyle != null) {
        _render.setCaptionStyle(widget.captionStyle!);
      }
    }

    // Recreate once, after `_render` is settled, with the latest session. A
    // session-only change never reaches here: it retargets the existing
    // binding, avoiding a duplicate rebind when the render also changed.
    if (clientChanged || renderChanged) {
      _recreateBinding();
    } else if (sessionChanged) {
      _rebindSessionFilter();
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
    _boundRender?.removeListener(_onRenderChanged);
    if (_boundRender != widget.render) _boundRender?.dispose();
    _frameSubscription?.cancel();
    _binding?.dispose();
    super.dispose();
  }

  void _onRenderChanged() {
    if (mounted) setState(() {});
  }

  void _onModelStatus(ModelStageStatus status) {
    if (!mounted || widget.resourceStatus != ModelStageStatus.none) return;
    if (_resourceStatus == status) return;
    setState(() => _resourceStatus = status);
  }

  void _onStripAction(StageStripAction action) {
    switch (action.buttonId) {
      case '__expand':
        _strip.setCollapsed(false);
        setState(() {});
      case 'stage':
        _strip.togglePanel('stage');
        setState(() {});
      case 'caption':
        _strip.togglePanel('caption');
        final open = _strip.openPanel == 'caption';
        final current = _render.captionStyle;
        _render.setCaptionStyle(
          StageCaptionStyle(
            enabled: current.enabled,
            docking: open
                ? StageCaptionDocking.bottom
                : StageCaptionDocking.none,
            fontSize: current.fontSize,
            opacity: current.opacity,
          ),
        );
        setState(() {});
      default:
        // Unknown ids are reported intent only; nothing to apply locally.
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        StageOverlays(
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
            onStatus: _onModelStatus,
          ),
        ),
        // Top-left picker; the presence chip owns the top-right and the cue
        // badge the bottom-left of this stack.
        Positioned(
          left: 12,
          top: 12,
          // Bound the chip row so it cannot grow under the top-right
          // presence chip on narrow screens.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: StageAtmosphereSelector(
              selected: _render.atmosphere,
              onChanged: (p) => _render.setAtmosphere(p),
            ),
          ),
        ),
        Positioned(
          right: 12,
          top: 12,
          child: PresenceStatusChip(client: widget.client),
        ),
        ResourceStatusIsland(status: _resourceStatus),
      ],
    );
  }
}
