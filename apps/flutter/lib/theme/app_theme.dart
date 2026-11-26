// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Companion palette constants shared by surfaces that paint directly
/// (cards, chat bubbles). Theme-driven surfaces should use [Theme.of] instead.
abstract final class AppTheme {
  static const Color canvas = Color(0xFF0E1117);
  static const Color surface = Color(0xFF171B24);
  static const Color subtle = Color(0xFF9AA4B2);

  /// Build the application [ThemeData] from a `settings.get('theme')` map.
  ///
  /// Missing or malformed fields fall back to the daemon's own serde defaults
  /// (`ThemeSettings` in `crates/anima-core/src/settings.rs`): hue 220.44,
  /// chroma multiplier 1.0, dark true. Nothing is invented client-side.
  static ThemeData fromSettings(Map<String, dynamic> settings) {
    return fromParsed(AppThemeSettings.fromSettings(settings));
  }

  /// Build [ThemeData] from parsed daemon theme settings.
  static ThemeData fromParsed(AppThemeSettings settings) {
    final brightness = settings.dark ? Brightness.dark : Brightness.light;
    final seed = seedColor(settings.hue, settings.chromaMultiplier);
    final scheme = ColorScheme.fromSeed(seedColor: seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: settings.dark ? canvas : scheme.surface,
      visualDensity: VisualDensity.adaptivePlatformDensity,
    );
  }

  /// Convert the daemon's OKLCH hue/chroma into a Material 3 seed colour.
  ///
  /// The daemon stores an OKLCH hue angle and a chroma multiplier, not an RGB
  /// hex. Material's seed-based scheme consumes RGB, so we keep the hue and
  /// derive a bounded saturation/chroma at a mid-tone lightness. This is an
  /// approximation of the Vue OKLCH palette, not a second source of settings.
  static Color seedColor(double hue, double chromaMultiplier) {
    // Mirrors packages/stage-ui/src/stores/settings/theme.ts's
    // getEffectiveChroma(): base chroma varies with the hue angle.
    final degrees = ((hue % 360) + 360) % 360;
    final chroma = (0.18 + math.cos(degrees * math.pi / 180.0) * 0.04) *
        chromaMultiplier;
    // Clamp to the sRGB-safe range used by HSLColor (0..1).
    final saturation = chroma.clamp(0.0, 1.0).toDouble();
    return HSLColor.fromAHSL(1.0, degrees, saturation, 0.5).toColor();
  }
}

/// Parsed view of the daemon's `settings/theme` section.
///
/// The daemon is the only writer; this struct only decodes what it returns.
/// Missing/invalid fields use the daemon's serde defaults rather than local
/// preferences, so a partial reply behaves exactly like a default daemon.
@immutable
class AppThemeSettings {
  const AppThemeSettings({
    required this.hue,
    required this.hueDynamic,
    required this.chromaMultiplier,
    required this.dark,
  });

  /// Default values from `anima_core::settings::ThemeSettings`.
  static const AppThemeSettings daemonDefaults = AppThemeSettings(
    hue: 220.44,
    hueDynamic: false,
    chromaMultiplier: 1.0,
    dark: true,
  );

  final double hue;
  final bool hueDynamic;
  final double chromaMultiplier;
  final bool dark;

  /// Decode one `settings.get('theme')` reply. Each field is validated at the
  /// same boundary: a wrong type falls back to the daemon's default for that
  /// field, never to an arbitrary palette value.
  factory AppThemeSettings.fromSettings(Map<String, dynamic> settings) {
    return AppThemeSettings(
      hue: _number(settings['hue'], daemonDefaults.hue),
      hueDynamic: settings['hueDynamic'] is bool
          ? settings['hueDynamic'] as bool
          : daemonDefaults.hueDynamic,
      chromaMultiplier: _number(
        settings['chromaMultiplier'],
        daemonDefaults.chromaMultiplier,
      ),
      dark: settings['dark'] is bool ? settings['dark'] as bool : daemonDefaults.dark,
    );
  }

  static double _number(Object? value, double fallback) {
    if (value is num && value.isFinite) return value.toDouble();
    return fallback;
  }

  @override
  bool operator ==(Object other) =>
      other is AppThemeSettings &&
      other.hue == hue &&
      other.hueDynamic == hueDynamic &&
      other.chromaMultiplier == chromaMultiplier &&
      other.dark == dark;

  @override
  int get hashCode =>
      Object.hash(hue, hueDynamic, chromaMultiplier, dark);
}
