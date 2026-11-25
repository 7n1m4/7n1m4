// SPDX-License-Identifier: GPL-3.0-or-later

// Caption/subtitle overlay for the Flutter stage. Behavior ported from the
// Vue reference (`packages/stage-ui/src/components/scenes/CaptionPanel.vue`):
// speaker nameplate, sentence-sync segments with an active accent, a
// top/bottom docking edge, opacity and font-scale from the daemon's
// `captions` settings section. `head` docking is a bottom alias (the
// head-tethered plank needs a renderer this client does not have yet).
//
// The widget is pure: it renders a [StageCaptionSnapshot] and never reads or
// writes daemon state.

import 'package:flutter/material.dart';

import 'stage_overlay_state.dart';

/// The stage caption/subtitle overlay.
class StageCaptionOverlay extends StatelessWidget {
  const StageCaptionOverlay({
    super.key,
    required this.caption,
    this.style = const StageCaptionStyle(),
    this.alignment = Alignment.bottomCenter,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  });

  final StageCaptionSnapshot caption;
  final StageCaptionStyle style;
  final Alignment alignment;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (!style.isVisible || caption.isEmpty) {
      return const SizedBox.shrink();
    }
    final text = caption.segments.isEmpty
        ? caption.speakerText
        : caption.segments.map((segment) => segment.text).join(' ');
    if (text.trim().isEmpty) return const SizedBox.shrink();

    final bar = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: scheme.scrim.withValues(alpha: style.alpha * 0.85),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: scheme.onSurface.withValues(alpha: style.alpha * 0.12),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (caption.speakerText.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                caption.speakerText,
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: scheme.onPrimary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (caption.segments.isEmpty)
            Text(text, style: _bodyStyle(context))
          else
            for (final segment in caption.segments)
              Text(
                segment.text,
                style: _bodyStyle(context).copyWith(
                  color: segment.isActive && segment.color.isNotEmpty
                      ? _parseAccent(segment.color)
                      : null,
                  fontWeight: segment.isActive
                      ? FontWeight.w700
                      : FontWeight.w500,
                ),
              ),
        ],
      ),
    );

    return Align(
      alignment: style.isTop ? Alignment.topCenter : alignment,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Transform.scale(
          scale: style.scale,
          alignment: style.isTop ? Alignment.topCenter : Alignment.bottomCenter,
          child: bar,
        ),
      ),
    );
  }

  /// Parses a `#RRGGBB`/`#AARRGGBB` accent. Anything else is not a color the
  /// stage invented: the caller's default text color is used instead.
  static Color? _parseAccent(String value) {
    var hex = value.trim();
    if (hex.startsWith('#')) hex = hex.substring(1);
    if (hex.length != 6 && hex.length != 8) return null;
    final parsed = int.tryParse(hex, radix: 16);
    if (parsed == null) return null;
    return Color(hex.length == 6 ? 0xFF000000 | parsed : parsed);
  }

  TextStyle _bodyStyle(BuildContext context) =>
      (Theme.of(context).textTheme.bodyLarge ?? const TextStyle()).copyWith(
        color: Theme.of(context).colorScheme.onPrimary,
        height: 1.35,
      );
}
