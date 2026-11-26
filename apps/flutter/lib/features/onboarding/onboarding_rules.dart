// SPDX-License-Identifier: GPL-3.0-or-later

/// Pure onboarding V3 quick-start rules, frozen from the Vue reference at
/// `packages/stage-ui/src/components/scenarios/dialogs/onboarding/v3/quick-start.vue`
/// and mirrored from `crates/anima-core/src/onboarding_rules.rs`.
///
/// This library is a read-only asset: it owns no store, no daemon verb, no wire
/// type and no UI state. It never writes `onboarding/v3-completed` (the caller
/// owns that ordering after the starter card has been committed atomically),
/// performs no first-run routing and makes no `cards.create` call. Real
/// two-client parity still needs a Flutter consumer of these rules; freezing
/// the values alone does not make Flutter agree with Vue.
///
/// Covered groups: the three-entry starter catalog, platform -> LLM provider
/// selection, speech provider -> companion voice selection, and measured
/// TTFT -> pacing preset calibration.
library;

/// One pinned entry of the official starter triad.
///
/// Mirrors the `StarterCompanion` interface in `quick-start.vue:49-59`. An
/// empty [mossNanoVoice] means "use [pocketTtsVoice]" (Vue's optional
/// `defaultMossVoice`).
final class StarterCompanion {
  /// Create a frozen catalog entry.
  const StarterCompanion({
    required this.id,
    required this.name,
    required this.title,
    required this.tag,
    required this.personality,
    required this.personaCardId,
    required this.vesselModelId,
    required this.kokoroVoice,
    required this.pocketTtsVoice,
    required this.mossNanoVoice,
  });

  /// Quick-start catalog id.
  final String id;

  /// Display name shown on the companion card.
  final String name;

  /// Title shown in the active-companion subtitle.
  final String title;

  /// Short role tag shown on the card.
  final String tag;

  /// Personality line shown in the active-companion subtitle.
  final String personality;

  /// Persona card id seeded by the atomic commit.
  final String personaCardId;

  /// Display vessel model id bound by the atomic commit.
  final String vesselModelId;

  /// Default Kokoro Local voice id.
  final String kokoroVoice;

  /// Default Pocket-TTS Local voice id.
  final String pocketTtsVoice;

  /// Default Moss-Nano Local voice id (empty means "use Pocket voice").
  final String mossNanoVoice;
}

/// The starter catalog in its exact Vue declaration order
/// (`quick-start.vue:61-103`).
const List<StarterCompanion> starterCompanions = <StarterCompanion>[
  StarterCompanion(
    id: 'default',
    name: 'ReLU',
    title: 'ReLU',
    tag: '🌸 Empathetic Companion',
    personality: 'Warm, playful kitten-girl soul mate',
    personaCardId: 'default',
    vesselModelId: 'preset-live2d-2',
    kokoroVoice: 'af_bella',
    pocketTtsVoice: 'airi_relu',
    mossNanoVoice: 'airi_relu',
  ),
  StarterCompanion(
    id: 'aria',
    name: 'Dr. Aria',
    title: 'Dr. Aria',
    tag: '🔬 Analytical Scientist',
    personality: 'Rigorous science, sharp dry wit',
    personaCardId: 'aria',
    vesselModelId: 'preset-vrm-1',
    kokoroVoice: 'af_sarah',
    pocketTtsVoice: 'airi_aria',
    mossNanoVoice: 'airi_aria',
  ),
  StarterCompanion(
    id: 'lupin',
    name: 'Lupin',
    title: 'Lupin',
    tag: '🛡️ Fierce Guardian',
    personality: 'Vigilant guardian, stoic & loyal',
    personaCardId: 'lupin',
    vesselModelId: 'preset-vrm-2',
    kokoroVoice: 'af_nicole',
    pocketTtsVoice: 'airi_lupin',
    mossNanoVoice: 'airi_lupin',
  ),
];

/// Look up a starter by catalog id. Unknown ids return `null`; the caller
/// applies Vue's `starterCompanions[0]` fallback (`quick-start.vue:115`).
StarterCompanion? starterCompanion(String id) {
  for (final companion in starterCompanions) {
    if (companion.id == id) return companion;
  }
  return null;
}

/// Collapse Kokoro/Pocket/Moss aliases to their canonical local engine ids.
/// Unknown ids are returned unchanged, as in the Vue source.
///
/// Match order is the Vue order: Kokoro, then Pocket, then Moss. An id
/// containing several engine names resolves to the first match.
String normalizeSpeechProviderId(String id) {
  final clean = id.toLowerCase();
  if (clean.contains('kokoro')) return 'kokoro-local';
  if (clean.contains('pocket')) return 'pocket-tts-local';
  if (clean.contains('moss')) return 'moss-nano-local';
  return id;
}

/// Pick a companion's default voice for a speech engine.
///
/// Pocket uses [StarterCompanion.pocketTtsVoice], Moss uses
/// [StarterCompanion.mossNanoVoice] with a fallback to
/// [StarterCompanion.pocketTtsVoice], and everything else (Kokoro and cloud
/// providers) uses [StarterCompanion.kokoroVoice]. Mirrors
/// `getCompanionVoice` at `quick-start.vue:148-155`.
String companionVoice(StarterCompanion companion, String engine) {
  return switch (normalizeSpeechProviderId(engine)) {
    'pocket-tts-local' => companion.pocketTtsVoice,
    'moss-nano-local' when companion.mossNanoVoice.isNotEmpty =>
      companion.mossNanoVoice,
    'moss-nano-local' => companion.pocketTtsVoice,
    _ => companion.kokoroVoice,
  };
}

/// Resolve the initial LLM provider with the quick-start precedence rules.
///
/// An explicit non-empty draft provider wins; otherwise native platforms take
/// `apple-core-ai` ([nativePlatform] is Vue's `isIOSNative.value`). All entries
/// are then scanned for `web-llm`/`webllm` and `kilo` (ahead of `providers[0]`);
/// if neither is registered, `providers[0]` is used, and an empty first entry
/// falls back to `openai`. Mirrors `getInitialProvider` at
/// `quick-start.vue:307-325`.
String initialLlmProvider(
  String? draftProvider,
  bool nativePlatform,
  List<String> availableProviders,
) {
  final draft = draftProvider;
  if (draft != null && draft.isNotEmpty) return draft;
  if (nativePlatform) return 'apple-core-ai';
  if (availableProviders.any((id) => id == 'web-llm' || id == 'webllm')) {
    return 'web-llm';
  }
  if (availableProviders.contains('kilo')) return 'kilo';
  final first = availableProviders.isEmpty ? null : availableProviders.first;
  if (first != null && first.isNotEmpty) return first;
  return 'openai';
}

/// Pacing preset calibrated from a measured time-to-first-token.
enum PacingPreset {
  /// Sub-800 ms connection: `snappy`.
  snappy,

  /// 800-2500 ms connection: `balanced`.
  balanced,

  /// Over 2500 ms connection: `deep` (Deep CoT).
  deep;

  /// Stable id persisted into the onboarding draft.
  String get id => switch (this) {
    PacingPreset.snappy => 'snappy',
    PacingPreset.balanced => 'balanced',
    PacingPreset.deep => 'deep',
  };
}

/// Map a measured TTFT in milliseconds to a pacing preset.
///
/// Mirrors `elapsed < 800 ? 'snappy' : elapsed > 2500 ? 'deep' : 'balanced'`:
/// 799 ms is snappy, 800 and 2500 ms are balanced, 2501 ms is deep.
PacingPreset pacingForTtftMs(int ttftMs) {
  if (ttftMs < 800) return PacingPreset.snappy;
  if (ttftMs > 2500) return PacingPreset.deep;
  return PacingPreset.balanced;
}
