// SPDX-License-Identifier: GPL-3.0-or-later

// Stage parity overlays that need no native renderer: the caption/subtitle
// bar, the background layer, and the emotion/motion cue badge. All three are
// pure functions of client-local render state; none of them reads or writes
// daemon state, and none of them stands in for an unavailable backend.

import 'dart:io';

import 'package:flutter/material.dart';

import 'stage_background.dart';
import 'stage_caption_overlay.dart';
import 'stage_overlay_state.dart';

/// The stage background layer (Vue `RendererStage.vue` `showBackground` +
/// `useBackgroundStore`).
///
/// `none` paints nothing, a tint paints a flat color, and an image is decoded
/// from a local file the resolver already validated. A missing or unreadable
/// file is a loud failure rather than an invented gradient.
class StageBackgroundLayer extends StatelessWidget {
  const StageBackgroundLayer({super.key, required this.background});

  final StageBackground background;

  @override
  Widget build(BuildContext context) {
    return switch (background.kind) {
      StageBackgroundKind.none => const SizedBox.shrink(),
      StageBackgroundKind.tint => Positioned.fill(
        child: ColoredBox(color: Color(background.tint ?? 0xFF171717)),
      ),
      StageBackgroundKind.image => Positioned.fill(
        child: Image.file(
          File(background.imagePath!),
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              const _BackgroundFailure(
                message: 'The stage background image could not be decoded.',
              ),
        ),
      ),
    };
  }
}

class _BackgroundFailure extends StatelessWidget {
  const _BackgroundFailure({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ColoredBox(
      color: scheme.errorContainer,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(Icons.error_outline, color: scheme.error),
              const SizedBox(width: 8),
              Flexible(
                child: Text(message, style: TextStyle(color: scheme.error)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The stage's emotion/motion cue badge.
///
/// The native backend already blended the cue; this badge is the client-local
/// readout of what is on screen (Vue shows the same state in the stage HUD).
/// `motion` and `vfx` cues are labelled as such and never as facial
/// expressions (`crates/anima-channel/src/wire.rs` `CueKind`).
class StageCueBadge extends StatelessWidget {
  const StageCueBadge({super.key, required this.state});

  final StageRenderState state;

  @override
  Widget build(BuildContext context) {
    final cue = state.cue;
    final scheme = Theme.of(context).colorScheme;
    final label = switch (state.cueChannel) {
      null => 'mouth ${(state.frame?.level ?? 0).round()}%',
      StageCueChannel.emotion => 'emotion ${cue!.tag}',
      StageCueChannel.motion => 'motion ${cue!.tag}',
      StageCueChannel.vfx => 'vfx ${cue!.tag}',
    };
    return Positioned(
      left: 12,
      bottom: 12,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: scheme.surface.withValues(alpha: 0.8),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(label, style: Theme.of(context).textTheme.bodySmall),
      ),
    );
  }
}

/// Everything the stage paints around the model surface.
///
/// Order is back-to-front: background, the model (supplied by the caller),
/// captions, the cue badge and the control strip. [model] is required because
/// the stage never substitutes anything for an unavailable renderer.
class StageOverlays extends StatelessWidget {
  const StageOverlays({
    super.key,
    required this.model,
    required this.state,
    this.strip,
  });

  final Widget model;
  final StageRenderState state;

  /// Control-strip host, when the shell mounts one.
  final Widget? strip;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        StageBackgroundLayer(background: state.background),
        if (state.showModel) model,
        if (state.captionStyle.isVisible)
          StageCaptionOverlay(
            caption: state.caption,
            style: state.captionStyle,
          ),
        if (strip != null) strip!,
      ],
    );
  }
}
