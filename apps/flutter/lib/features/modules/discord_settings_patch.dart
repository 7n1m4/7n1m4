// SPDX-License-Identifier: GPL-3.0-or-later

// Token-safe bridge from the daemon's masked `settings.get('discord')` view to
// a write PATCH. The daemon stores the bot token write-only: a read returns
// `hasToken` instead of `token`, and a PATCH that omits or echoes a mask keeps
// the stored credential. This helper makes that shape the only one a thin
// client can produce, so a blank editor field can never wipe a configured bot.

/// Editable enum fields and their only accepted values, mirrored from
/// `DiscordSettings` in `crates/anima-core/src/settings.rs`. Shared with the
/// editor so the dropdown options and the write gate cannot drift apart.
const Map<String, List<String>> discordChoiceValues = <String, List<String>>{
  'executionMode': <String>['local', 'remote'],
  'chatMode': <String>['followup', 'steer', 'collect'],
  'voiceMode': <String>['puppet', 'voicenote', 'none'],
  'voiceCall': <String>['classic', 'gemini', 'off'],
};

/// Build a typed PATCH from a token-free masked view plus user edits.
///
/// Pure: no I/O, no widget state, no mutation of [maskedView] or [edits].
///
/// - `hasToken` is a read-only hint, never a writable field, so it is dropped.
/// - `token` is write-only: one coming from a read (or from [edits]) is dropped
///   so echoing a mask or a stale value cannot rotate or wipe the credential.
/// - Enum fields are emitted only when their value is in [discordChoiceValues];
///   an unknown value is dropped entirely and the daemon keeps the stored one.
/// - Every other key is carried through, so sibling/future keys round-trip.
/// - A token is emitted only from [typedToken], and only when non-blank.
Map<String, dynamic> buildDiscordPatch(
  Map<String, dynamic> maskedView, {
  Map<String, dynamic> edits = const <String, dynamic>{},
  String? typedToken,
}) {
  final merged = <String, dynamic>{...maskedView, ...edits};
  final patch = <String, dynamic>{};
  merged.forEach((key, value) {
    if (key == 'token' || key == 'hasToken') return;
    final allowed = discordChoiceValues[key];
    if (allowed != null && (value is! String || !allowed.contains(value))) {
      return;
    }
    patch[key] = value;
  });
  if (typedToken != null && typedToken.trim().isNotEmpty) {
    patch['token'] = typedToken;
  }
  return patch;
}
