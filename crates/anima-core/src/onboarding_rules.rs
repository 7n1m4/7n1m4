// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Pure onboarding V3 quick-start rules, frozen from the Vue reference at
//! `packages/stage-ui/src/components/scenarios/dialogs/onboarding/v3/quick-start.vue`.
//!
//! This module is a read-only asset: it owns no store, daemon verb, wire type
//! or UI state. The completion flag `onboarding/v3-completed` must never be
//! written before the starter card (persona, vessel binding and Turn 0
//! greeting) has been committed atomically; callers own that ordering.
//! Real two-client parity still requires a Flutter consumer of these rules —
//! freezing the values in Rust alone does not make Flutter agree with Vue.
//!
//! Covered rules: the three-entry starter catalog, platform → LLM provider
//! selection, speech provider → companion voice selection, and measured
//! TTFT → pacing preset calibration.

/// One pinned entry of the official starter triad.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct StarterCompanion {
    /// Quick-start catalog id.
    pub id: &'static str,
    /// Display name shown on the companion card.
    pub name: &'static str,
    /// Title shown in the active-companion subtitle.
    pub title: &'static str,
    /// Short role tag shown on the card.
    pub tag: &'static str,
    /// Personality line shown in the active-companion subtitle.
    pub personality: &'static str,
    /// Persona card id seeded by the atomic commit.
    pub persona_card_id: &'static str,
    /// Display vessel model id bound by the atomic commit.
    pub vessel_model_id: &'static str,
    /// Default Kokoro Local voice id.
    pub kokoro_voice: &'static str,
    /// Default Pocket-TTS Local voice id.
    pub pocket_tts_voice: &'static str,
    /// Default Moss-Nano Local voice id (empty means "use Pocket voice").
    pub moss_nano_voice: &'static str,
}

/// The starter catalog in its exact Vue declaration order.
pub static STARTER_COMPANIONS: [StarterCompanion; 3] = [
    StarterCompanion {
        id: "default",
        name: "ReLU",
        title: "ReLU",
        tag: "🌸 Empathetic Companion",
        personality: "Warm, playful kitten-girl soul mate",
        persona_card_id: "default",
        vessel_model_id: "preset-live2d-2",
        kokoro_voice: "af_bella",
        pocket_tts_voice: "airi_relu",
        moss_nano_voice: "airi_relu",
    },
    StarterCompanion {
        id: "aria",
        name: "Dr. Aria",
        title: "Dr. Aria",
        tag: "🔬 Analytical Scientist",
        personality: "Rigorous science, sharp dry wit",
        persona_card_id: "aria",
        vessel_model_id: "preset-vrm-1",
        kokoro_voice: "af_sarah",
        pocket_tts_voice: "airi_aria",
        moss_nano_voice: "airi_aria",
    },
    StarterCompanion {
        id: "lupin",
        name: "Lupin",
        title: "Lupin",
        tag: "🛡️ Fierce Guardian",
        personality: "Vigilant guardian, stoic & loyal",
        persona_card_id: "lupin",
        vessel_model_id: "preset-vrm-2",
        kokoro_voice: "af_nicole",
        pocket_tts_voice: "airi_lupin",
        moss_nano_voice: "airi_lupin",
    },
];

/// Look up a starter by catalog id. Unknown ids return `None`; the caller
/// applies Vue's `starterCompanions[0]` fallback (`quick-start.vue:114-116`).
pub fn starter_companion(id: &str) -> Option<&'static StarterCompanion> {
    STARTER_COMPANIONS
        .iter()
        .find(|companion| companion.id == id)
}

/// Collapse Kokoro/Pocket/Moss aliases to their canonical local engine ids.
/// Unknown ids are returned unchanged, as in the Vue source.
///
/// Match order is the Vue order: Kokoro, then Pocket, then Moss. An id
/// containing several engine names resolves to the first match.
pub fn normalize_speech_provider_id(id: &str) -> String {
    let clean = id.to_lowercase();
    if clean.contains("kokoro") {
        return "kokoro-local".to_string();
    }
    if clean.contains("pocket") {
        return "pocket-tts-local".to_string();
    }
    if clean.contains("moss") {
        return "moss-nano-local".to_string();
    }
    id.to_string()
}

/// Pick a companion's default voice for a speech engine.
///
/// Pocket uses `pocket_tts_voice`, Moss uses `moss_nano_voice` with a fallback
/// to `pocket_tts_voice`, and everything else (Kokoro and cloud providers)
/// uses `kokoro_voice`.
pub fn companion_voice(companion: &StarterCompanion, engine: &str) -> &'static str {
    match normalize_speech_provider_id(engine).as_str() {
        "pocket-tts-local" => companion.pocket_tts_voice,
        "moss-nano-local" if !companion.moss_nano_voice.is_empty() => companion.moss_nano_voice,
        "moss-nano-local" => companion.pocket_tts_voice,
        _ => companion.kokoro_voice,
    }
}

/// Resolve the initial LLM provider with the quick-start precedence rules.
///
/// An explicit non-empty draft provider wins; otherwise native platforms
/// take `apple-core-ai`, then a registered `web-llm`/`webllm` provider, then
/// `kilo` (ahead of `providers[0]`), then exactly `providers[0]` (Vue does not
/// skip empty entries), with `openai` as the final fallback.
pub fn initial_llm_provider(
    draft_provider: Option<&str>,
    native_platform: bool,
    available_providers: &[&str],
) -> String {
    if let Some(provider) = draft_provider.filter(|id| !id.is_empty()) {
        return provider.to_string();
    }
    if native_platform {
        return "apple-core-ai".to_string();
    }
    if available_providers
        .iter()
        .any(|id| *id == "web-llm" || *id == "webllm")
    {
        return "web-llm".to_string();
    }
    if available_providers.iter().any(|id| *id == "kilo") {
        return "kilo".to_string();
    }
    match available_providers.first() {
        Some(id) if !id.is_empty() => (*id).to_string(),
        _ => "openai".to_string(),
    }
}

/// Pacing preset calibrated from a measured time-to-first-token.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PacingPreset {
    /// Sub-800 ms connection: `snappy`.
    Snappy,
    /// 800–2500 ms connection: `balanced`.
    Balanced,
    /// Over 2500 ms connection: `deep` (Deep CoT).
    Deep,
}

impl PacingPreset {
    /// Stable id persisted into the onboarding draft.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Snappy => "snappy",
            Self::Balanced => "balanced",
            Self::Deep => "deep",
        }
    }
}

/// Map a measured TTFT in milliseconds to a pacing preset.
///
/// Mirrors `elapsed < 800 ? 'snappy' : elapsed > 2500 ? 'deep' : 'balanced'`:
/// 799 ms is snappy, 800 and 2500 ms are balanced, 2501 ms is deep.
pub fn pacing_for_ttft_ms(ttft_ms: u64) -> PacingPreset {
    if ttft_ms < 800 {
        PacingPreset::Snappy
    } else if ttft_ms > 2500 {
        PacingPreset::Deep
    } else {
        PacingPreset::Balanced
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starter_catalog_is_exact() {
        let expected = [
            (
                "default",
                "ReLU",
                "ReLU",
                "🌸 Empathetic Companion",
                "Warm, playful kitten-girl soul mate",
                "default",
                "preset-live2d-2",
                "af_bella",
                "airi_relu",
                "airi_relu",
            ),
            (
                "aria",
                "Dr. Aria",
                "Dr. Aria",
                "🔬 Analytical Scientist",
                "Rigorous science, sharp dry wit",
                "aria",
                "preset-vrm-1",
                "af_sarah",
                "airi_aria",
                "airi_aria",
            ),
            (
                "lupin",
                "Lupin",
                "Lupin",
                "🛡️ Fierce Guardian",
                "Vigilant guardian, stoic & loyal",
                "lupin",
                "preset-vrm-2",
                "af_nicole",
                "airi_lupin",
                "airi_lupin",
            ),
        ];

        assert_eq!(STARTER_COMPANIONS.len(), 3);
        let actual_ids: Vec<&str> = STARTER_COMPANIONS
            .iter()
            .map(|companion| companion.id)
            .collect();
        assert_eq!(actual_ids, ["default", "aria", "lupin"]);

        for (companion, row) in STARTER_COMPANIONS.iter().zip(expected) {
            assert_eq!(
                (
                    companion.id,
                    companion.name,
                    companion.title,
                    companion.tag,
                    companion.personality,
                    companion.persona_card_id,
                    companion.vessel_model_id,
                    companion.kokoro_voice,
                    companion.pocket_tts_voice,
                    companion.moss_nano_voice,
                ),
                row,
                "catalog entry mismatch for {}",
                companion.id
            );
            assert_eq!(
                starter_companion(companion.id),
                Some(companion),
                "catalog lookup failed for {}",
                companion.id
            );
        }
        assert!(starter_companion("unknown").is_none());
    }

    #[test]
    fn speech_engine_aliases_normalize_in_vue_order() {
        let cases = [
            ("kokoro-local", "kokoro-local"),
            ("KOKORO Q4", "kokoro-local"),
            ("pocket-tts-local", "pocket-tts-local"),
            ("Pocket-French", "pocket-tts-local"),
            ("moss-nano-local", "moss-nano-local"),
            ("My-Moss-Engine", "moss-nano-local"),
            ("moss-pocket", "pocket-tts-local"),
            ("kokoro-moss", "kokoro-local"),
            ("OpenAI", "OpenAI"),
            ("", ""),
        ];
        for (engine, expected) in cases {
            assert_eq!(
                normalize_speech_provider_id(engine),
                expected,
                "engine {engine}"
            );
        }
    }

    #[test]
    fn companion_voices_match_vue_per_engine() {
        // Slot 0 = Kokoro, 1 = Pocket, 2 = Moss; aliases and unknown cloud
        // engines follow the same mapping as their canonical ids.
        let engines = [
            ("kokoro-local", 0),
            ("pocket-tts-local", 1),
            ("moss-nano-local", 2),
            ("KOKORO Q8", 0),
            ("Pocket English", 1),
            ("moss-tts", 2),
            ("elevenlabs", 0),
        ];
        for companion in &STARTER_COMPANIONS {
            for (engine, slot) in engines {
                let voices = [
                    companion.kokoro_voice,
                    companion.pocket_tts_voice,
                    companion.moss_nano_voice,
                ];
                assert_eq!(
                    companion_voice(companion, engine),
                    voices[slot],
                    "{} on {engine}",
                    companion.id
                );
            }
        }

        // Moss falls back to Pocket when the companion has no Moss voice.
        let mut no_moss = STARTER_COMPANIONS[0];
        no_moss.moss_nano_voice = "";
        assert_eq!(
            companion_voice(&no_moss, "moss-nano-local"),
            no_moss.pocket_tts_voice
        );
    }

    #[test]
    fn initial_provider_precedence_and_fallback() {
        let cases = [
            (
                "draft wins over native Apple",
                Some("groq"),
                true,
                &["web-llm", "kilo"][..],
                "groq",
            ),
            ("empty draft is ignored", Some(""), false, &["kilo"], "kilo"),
            (
                "native Apple wins over web-llm and kilo",
                None,
                true,
                &["web-llm", "kilo"][..],
                "apple-core-ai",
            ),
            (
                "web-llm wins over first provider",
                None,
                false,
                &["openai", "web-llm"][..],
                "web-llm",
            ),
            (
                "webllm alias is accepted",
                None,
                false,
                &["webllm", "kilo"][..],
                "web-llm",
            ),
            (
                "kilo wins over providers[0]",
                None,
                false,
                &["kilo", "openai"][..],
                "kilo",
            ),
            (
                "kilo wins even when first provider is another cloud",
                None,
                false,
                &["groq", "kilo"][..],
                "kilo",
            ),
            (
                "first provider when no preferred id exists",
                None,
                false,
                &["groq", "anthropic"][..],
                "groq",
            ),
            (
                "empty first provider falls back to openai like Vue",
                None,
                false,
                &["", "groq"][..],
                "openai",
            ),
            (
                "empty registry falls back to openai",
                None,
                false,
                &[][..],
                "openai",
            ),
            (
                "all empty provider ids fall back to openai",
                None,
                false,
                &["", ""][..],
                "openai",
            ),
        ];

        for (name, draft, native_apple, providers, expected) in cases {
            assert_eq!(
                initial_llm_provider(draft, native_apple, providers),
                expected,
                "{name}"
            );
        }
    }

    #[test]
    fn ttft_pacing_boundaries_are_exact() {
        let cases = [
            (0, "snappy"),
            (799, "snappy"),
            (800, "balanced"),
            (2500, "balanced"),
            (2501, "deep"),
            (u64::MAX, "deep"),
        ];
        for (ttft_ms, expected) in cases {
            assert_eq!(
                pacing_for_ttft_ms(ttft_ms).as_str(),
                expected,
                "{ttft_ms} ms"
            );
        }
    }
}
