// SPDX-License-Identifier: GPL-3.0-or-later

/// Display-time cleanup for AIRI LLM markers.
///
/// Ported from `stripMarkers` in
/// `packages/stage-ui/src/composables/response-categoriser.ts` so the Flutter
/// bubble shows the same text as the Vue stage. Only call this when rendering
/// text: the raw accumulated turn must stay intact for GenUI parsing.
final RegExp _closedMarker = RegExp(r'<\|[\s\S]*?\|>');

/// NOTICE: older AIRI card prompts taught some models to close ACT-family tags
/// with a plain `>` instead of `|>`. Strip those legacy markers too so they
/// never leak into the UI — kept in sync with the Vue helper's second pass.
final RegExp _legacyMarker = RegExp(
  r'<\|(?:ACTOR|ACT|DELAY|STICKER|llm_[\w:-])[^\r\n>]*>',
  caseSensitive: false,
);

/// Removes `<|...|>` blocks (including multiline) and legacy ACT-family tags
/// closed with a plain `>`, leaving every other character untouched.
String stripMarkers(String text) =>
    text.replaceAll(_closedMarker, '').replaceAll(_legacyMarker, '');
