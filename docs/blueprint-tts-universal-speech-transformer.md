# Universal Speech Transformer — Architecture

Architecture-level pointer. The capability is the UST middleware that cleans and normalizes
text before any TTS dispatch so roleplay markup, emoji and kaomoji are not vocalized by
standard cloud providers. It is a checkbox-list panel in the left column of the Speech Module,
not a standalone page.

Source of truth for the core constraints, rule catalog (narrative brackets, visual symbols,
sanitization), pipeline order, state wiring and the `speech()` execution hook now lives in
`packages/stage-ui/src/stores/modules/README-speech-transformer.md`, implemented by
`applyUSTTransformations` in `packages/stage-ui/src/stores/modules/speech.ts`.

Historical status: implemented (UST V2/V3 rule set) with per-profile settings and a
playground preview.

## Relevant Skills

- [[airi-audio-pipeline]]
