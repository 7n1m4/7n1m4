<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# anima-speech

AIRI text-to-speech (TTS) lane — Rust port of the AIRI speech provider registry.

The crate contract — the provider trait and pipeline, the 26-id catalog with
per-provider port status, the configuration example, known gaps and the test
story — lives in the rustdoc for [`src/lib.rs`](src/lib.rs) and the per-family
client docs (`client_openai`, `client_elevenlabs`, `client_unspeech`,
`client_voicevox`, `client_polly`, `client_kokoro`, …)
(`cargo doc -p anima-speech --open`).
