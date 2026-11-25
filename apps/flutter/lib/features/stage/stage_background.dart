// SPDX-License-Identifier: GPL-3.0-or-later

// Client-local stage background state. Ported from the Vue background store
// (`packages/stage-ui/src/stores/background.ts`): a stage backdrop is either
// absent (`none`), a flat tint, or an image the user supplied. Only the
// client-local selection lives here — the daemon owns cards and settings, and
// no background verb exists on the wire, so nothing is written back.

import 'dart:io';

import 'model_failure.dart';

/// What the stage paints behind the model.
enum StageBackgroundKind { none, tint, image }

/// A resolved stage backdrop.
class StageBackground {
  const StageBackground({
    required this.kind,
    this.tint,
    this.imagePath,
    this.fingerprint,
  });

  /// No backdrop: the stage shows whatever is behind the window.
  static const StageBackground none = StageBackground(
    kind: StageBackgroundKind.none,
  );

  final StageBackgroundKind kind;

  /// `0xAARRGGBB` for [StageBackgroundKind.tint].
  final int? tint;

  /// Absolute local path for [StageBackgroundKind.image].
  final String? imagePath;

  /// Content fingerprint of the image, when one was resolved.
  final String? fingerprint;

  /// Parse a stored `background_tint` hex string (`#RRGGBB` / `#AARRGGBB`).
  /// Returns null for anything else so the caller can fall back to
  /// [StageBackground.none] instead of painting an invented color.
  static StageBackground tintFromHex(String? hex) {
    if (hex == null) return StageBackground.none;
    var value = hex.trim();
    if (value.startsWith('#')) value = value.substring(1);
    if (value.length != 6 && value.length != 8) return StageBackground.none;
    final parsed = int.tryParse(value, radix: 16);
    if (parsed == null) return StageBackground.none;
    final argb = value.length == 6 ? 0xFF000000 | parsed : parsed;
    return StageBackground(kind: StageBackgroundKind.tint, tint: argb);
  }

  @override
  String toString() => switch (kind) {
    StageBackgroundKind.none => 'StageBackground(none)',
    StageBackgroundKind.tint =>
      'StageBackground(tint, ${tint?.toRadixString(16)})',
    StageBackgroundKind.image => 'StageBackground(image, $imagePath)',
  };
}

/// A loud, typed background failure. An unresolvable backdrop is never
/// replaced by an invented one.
class StageBackgroundException implements ModelFailure {
  const StageBackgroundException(this.code, this.message);

  @override
  final String code;
  @override
  final String message;

  @override
  String toString() => 'StageBackgroundException($code): $message';
}

/// Resolves a client-local backdrop descriptor into something paintable.
///
/// [tint] is `#RRGGBB`/`#AARRGGBB`; [imagePath] is a local file. A remote
/// background URL is a loud failure: this build has no background downloader
/// and inventing one would silently fetch user data.
class StageBackgroundResolver {
  const StageBackgroundResolver();

  Future<StageBackground> resolve({String? tint, String? imagePath}) async {
    final image = imagePath?.trim() ?? '';
    if (image.isEmpty) {
      final parsed = StageBackground.tintFromHex(tint);
      if (parsed.kind == StageBackgroundKind.none && tint != null) {
        throw StageBackgroundException(
          'invalid-tint',
          'The stage background tint "$tint" is not a hex color.',
        );
      }
      return parsed;
    }
    if (image.startsWith('http://') || image.startsWith('https://')) {
      throw const StageBackgroundException(
        'remote-background',
        'Remote stage backgrounds need a downloader in this build.',
      );
    }
    final file = File(image);
    if (!await file.exists()) {
      throw const StageBackgroundException(
        'missing-background',
        'The stage background file does not exist on this device.',
      );
    }
    final length = await file.length();
    return StageBackground(
      kind: StageBackgroundKind.image,
      imagePath: file.absolute.path,
      fingerprint: '${file.absolute.path}:${length}',
    );
  }
}
