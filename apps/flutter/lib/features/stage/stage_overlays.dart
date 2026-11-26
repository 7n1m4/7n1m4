// SPDX-License-Identifier: GPL-3.0-or-later

// Stage parity overlays that need no native renderer: the caption/subtitle
// bar, the background layer, and the emotion/motion cue badge. All three are
// pure functions of client-local render state; none of them reads or writes
// daemon state, and none of them stands in for an unavailable backend.

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'stage_atmosphere.dart';
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

/// Fixed number of particles per preset. Seeds come from a hash of the index,
/// so nothing is drawn from a random source and each frame allocates no state.
const int kAtmosphereParticleCount = 18;

double _atmosphereUnit(int index, int salt) {
  final mixed = ((index + 1) * 73856093) ^ (salt * 19349663);
  return (mixed & 0xFFFF) / 0xFFFF;
}

Color _atmosphereTint(StageAtmosphere preset) => switch (preset) {
  StageAtmosphere.none => const Color(0x00000000),
  StageAtmosphere.hearts => const Color(0xFFFF8FB3),
  StageAtmosphere.petals => const Color(0xFFFFC0D0),
  StageAtmosphere.stars => const Color(0xFFFFE08A),
  StageAtmosphere.bubbles => const Color(0xFFA8DCFF),
  StageAtmosphere.crosses => const Color(0xFF9BE7D8),
  StageAtmosphere.notes => const Color(0xFFD6B4FF),
};

/// Position of particle [index] in [size] after [elapsed].
///
/// Pure function of the selected preset, a fixed per-index hash and elapsed
/// time: no RNG, no daemon data and no mutable state between frames.
Offset atmosphereParticlePosition(
  StageAtmosphere preset,
  int index,
  Duration elapsed,
  Size size,
) {
  if (preset == StageAtmosphere.none || size.isEmpty) return Offset.zero;
  final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
  final x = _atmosphereUnit(index, 1);
  final y = _atmosphereUnit(index, 2);
  final phase = _atmosphereUnit(index, 3) * math.pi * 2;
  return switch (preset) {
    StageAtmosphere.hearts ||
    StageAtmosphere.bubbles ||
    StageAtmosphere.notes => Offset(
      size.width * ((x + math.sin(seconds * 0.9 + phase) * 0.05) % 1),
      size.height * (1 - ((y + seconds / 9) % 1)),
    ),
    StageAtmosphere.petals => Offset(
      size.width *
          ((x + seconds * 0.025 + math.sin(seconds + phase) * 0.04) % 1),
      size.height * ((y + seconds / 12) % 1),
    ),
    StageAtmosphere.stars => Offset(
      size.width * ((x + math.sin(seconds * 0.3 + phase) * 0.02) % 1),
      size.height * ((y + math.cos(seconds * 0.25 + phase) * 0.02) % 1),
    ),
    StageAtmosphere.crosses => Offset(
      size.width * ((x + math.sin(seconds * 0.4 + phase) * 0.03) % 1),
      size.height * ((y + seconds / 20) % 1),
    ),
    StageAtmosphere.none => Offset.zero,
  };
}

void _paintHeart(Canvas canvas, Paint fill, double radius) {
  canvas.drawPath(
    Path()
      ..moveTo(0, radius)
      ..cubicTo(
        -radius * 1.5,
        radius * 0.15,
        -radius * 0.9,
        -radius * 1.2,
        0,
        -radius * 0.45,
      )
      ..cubicTo(
        radius * 0.9,
        -radius * 1.2,
        radius * 1.5,
        radius * 0.15,
        0,
        radius,
      )
      ..close(),
    fill,
  );
}

void _paintSparkle(Canvas canvas, Paint fill, double radius) {
  final inner = radius * 0.26;
  canvas.drawPath(
    Path()
      ..moveTo(0, -radius)
      ..lineTo(inner, -inner)
      ..lineTo(radius, 0)
      ..lineTo(inner, inner)
      ..lineTo(0, radius)
      ..lineTo(-inner, inner)
      ..lineTo(-radius, 0)
      ..lineTo(-inner, -inner)
      ..close(),
    fill,
  );
}

void _paintPlus(Canvas canvas, Paint fill, double radius) {
  final bar = radius * 0.3;
  canvas.drawRect(
    Rect.fromCenter(center: Offset.zero, width: radius * 1.6, height: bar),
    fill,
  );
  canvas.drawRect(
    Rect.fromCenter(center: Offset.zero, width: bar, height: radius * 1.6),
    fill,
  );
}

void _paintNote(Canvas canvas, Paint fill, double radius) {
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(-radius * 0.35, radius * 0.6),
      width: radius,
      height: radius * 0.7,
    ),
    fill,
  );
  final stem = Paint()
    ..color = fill.color
    ..style = PaintingStyle.stroke
    ..strokeWidth = radius * 0.22
    ..strokeCap = StrokeCap.round;
  canvas.drawLine(
    Offset(radius * 0.12, radius * 0.6),
    Offset(radius * 0.12, -radius),
    stem,
  );
  canvas.drawLine(
    Offset(radius * 0.12, -radius),
    Offset(radius * 0.7, -radius * 0.6),
    stem,
  );
}

/// Deterministic particle layer. `none` paints nothing; every other preset
/// paints a fixed set of shapes whose positions/twinkle are derived from
/// [elapsed] and the preset only. Animation follows the stage's existing
/// ambient ticker (`StageRenderState.tickAmbient`) — this adds no second clock.
class StageAtmospherePainter extends CustomPainter {
  const StageAtmospherePainter({required this.preset, required this.elapsed});

  final StageAtmosphere preset;
  final Duration elapsed;

  @override
  void paint(Canvas canvas, Size size) {
    if (preset == StageAtmosphere.none || size.isEmpty) return;
    final seconds = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final tint = _atmosphereTint(preset);
    for (var i = 0; i < kAtmosphereParticleCount; i++) {
      final position = atmosphereParticlePosition(preset, i, elapsed, size);
      final phase = _atmosphereUnit(i, 3) * math.pi * 2;
      final radius = 4 + 7 * _atmosphereUnit(i, 4);
      final twinkle = 0.55 + 0.45 * math.sin(seconds * 2 + phase);
      final fill = Paint()
        ..color = tint.withValues(alpha: (0.35 + 0.5 * twinkle).clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;
      canvas.save();
      canvas.translate(position.dx, position.dy);
      switch (preset) {
        case StageAtmosphere.hearts:
          _paintHeart(canvas, fill, radius);
        case StageAtmosphere.petals:
          canvas.rotate(seconds * 0.4 + phase);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset.zero,
              width: radius * 2,
              height: radius,
            ),
            fill,
          );
        case StageAtmosphere.stars:
          _paintSparkle(canvas, fill, radius);
        case StageAtmosphere.bubbles:
          canvas.drawCircle(Offset.zero, radius, fill);
          canvas.drawCircle(
            Offset(-radius * 0.3, -radius * 0.3),
            radius * 0.2,
            Paint()..color = const Color(0x80FFFFFF),
          );
        case StageAtmosphere.crosses:
          _paintPlus(canvas, fill, radius);
        case StageAtmosphere.notes:
          _paintNote(canvas, fill, radius);
        case StageAtmosphere.none:
          break;
      }
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant StageAtmospherePainter oldDelegate) =>
      oldDelegate.preset != preset || oldDelegate.elapsed != elapsed;
}

/// The atmosphere layer, mounted between the background and the model.
class StageAtmosphereLayer extends StatelessWidget {
  const StageAtmosphereLayer({super.key, required this.state});

  final StageRenderState state;

  @override
  Widget build(BuildContext context) {
    if (state.atmosphere == StageAtmosphere.none) {
      return const SizedBox.shrink();
    }
    return IgnorePointer(
      child: CustomPaint(
        key: const Key('stage-atmosphere-particles'),
        painter: StageAtmospherePainter(
          preset: state.atmosphere,
          elapsed: state.paused ? Duration.zero : state.ambientElapsed,
        ),
        child: const SizedBox.expand(),
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
/// Order is back-to-front: background, the client-local atmosphere particles,
/// the model (supplied by the caller), captions and the control strip. [model]
/// is required because the stage never substitutes anything for an
/// unavailable renderer.
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
        StageAtmosphereLayer(state: state),
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
