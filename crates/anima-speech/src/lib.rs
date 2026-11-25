// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! AIRI speech (TTS) crate — P5 lane.
//!
//! Port of the AIRI speech provider registry (`packages/stage-ui/src/stores/providers/registry/speech.ts`)
//! to Rust: provider-family clients, an LRU disk cache, and a rodio-based playback pipeline
//! with lip-sync amplitude events on a broadcast bus.
//!
//! - [`SpeechSynthesizer`]: the provider trait. Implementations are plain HTTP clients
//!   (plus one noop) and one in-process ONNX engine, [`KokoroSynthesizer`]; the
//!   in-process/WASM adapters the Vue app has (Moss, Pocket TTS, Ming) are not here.
//! - [`build_tts_client`]: config → `Arc<dyn SpeechSynthesizer>`; [`TTS_PROVIDER_DEFS`]
//!   is the full registry catalog (26 ids) with per-provider port status.
//! - [`SpeechPipeline`]: text → synthesize (or cache) → decode → amplitude tap → sink,
//!   emitting [`SpeechEvent`]s (`Started` / `Amplitude` / `Done` / `Aborted` / `Error`).
//! - [`SpeechAudioCache`]: disk LRU (200 entries / 50 MB), keyed by
//!   `sha256(scope | model | voice | format | speed | pitch | text)`.
//! - [`list_output_devices`]: rodio/cpal output device names; the pipeline selects a
//!   device via [`RodioSinkFactory::new`] and falls back to the default.
//! - [`CaptureSinkFactory`]: test sink that drains samples into memory (used by the
//!   mock end-to-end test).
//!
//! Layering: no toolkit, no `airi-core`. The stage bridge (airi-slint) consumes `SpeechEvent`s
//! on its own thread — wire-up is a later integration step, not this crate's concern.
//!
//! # Provider support
//!
//! [`TTS_PROVIDER_DEFS`] is the catalog; per-family wire notes live on each client
//! module (`client_openai`, `client_elevenlabs`, `client_unspeech`, `client_voicevox`,
//! `client_player2`, `client_minimax`, `client_mimo`, `client_gemini`,
//! `client_openrouter`, `client_polly`, `client_kokoro`, `client_noop`).
//!
//! - **Ported:** every OpenAI-compatible id (`openai-audio-speech`,
//!   `openai-compatible-audio-speech`, `comet-api-speech`, `xai-audio-speech`,
//!   `airi-audio-server`, `chatterbox`, `index-tts-vllm`), `elevenlabs`,
//!   the unspeech-proxy ids (`microsoft-speech`, `deepgram-tts`,
//!   `alibaba-cloud-model-studio`, `volcengine`), the VOICEVOX family
//!   (`voicevox`, `aivis-speech`), `player2-speech`, `minimax-speech`,
//!   `mimo-audio-speech`, `google-gemini-audio-speech`, `openrouter-audio-speech`,
//!   and `speech-noop` (a 44-byte silent WAV, no network).
//! - **Partial:** `aws-polly-tts` (SigV4 signed locally with HMAC-SHA256, covered by
//!   unit tests only — never verified against live AWS) and `kokoro-local`
//!   (in-process ONNX; model + voices fetched on first run, never committed).
//! - **Unsupported:** `moss-nano-local`, `pocket-tts-local`, `ming3-local` (in-process
//!   adapters, no wire contract) and `virtual-audio-studio` (Vue-only FX composition).
//!   They stay in the catalog so a UI can enumerate and explain them;
//!   [`build_tts_client`] yields [`SpeechError::UnsupportedProvider`] with the reason.
//!
//! # Configuration
//!
//! ```no_run
//! use anima_speech::{build_tts_client, TtsProviderConfig};
//!
//! let client = build_tts_client(TtsProviderConfig {
//!     id: "openai-audio-speech".into(),
//!     kind: None,
//!     api_key: Some("sk-…".into()),
//!     base_url: None,           // catalog default (https://api.openai.com/v1/)
//!     model: None,              // catalog default (tts-1)
//!     voice: None,
//!     extra: Default::default(),
//! })?;
//! # Ok::<(), anima_speech::SpeechError>(())
//! ```
//!
//! For Polly, `api_key` is the Access Key ID and `extra.secret_access_key` /
//! `extra.region` (default `us-east-1`) are required. For unspeech Volcengine,
//! `extra.app_id` is required. `extra.extra_body` (object, wire-shaped keys) is merged
//! into unspeech requests verbatim.
//!
//! # Known gaps
//!
//! - No streaming-into-playback: every client collects bytes, then decodes. Lip-sync
//!   amplitude events fire from the decoded sample stream, so they track audible output
//!   regardless.
//! - `Amplitude` events fire in sample-aligned windows, not on wall-clock pacing; with a
//!   real rodio sink the mixer pulls at playback rate, so they are wall-clock-aligned in
//!   practice.
//! - The AWS Polly signature is unverified against the live service, and
//!   VOICEVOX/AivisSpeech/Player2 have no sandbox here — their ports are byte-faithful
//!   from the Vue/xsai sources but not desk-verified against live engines.
//! - The cache key mixes `speed`/`pitch` on top of the plan's literal
//!   `sha256(provider|model|voice|format|text)`; they alter the audio bytes and the Vue
//!   cache does the same.
//! - `speech-noop` emits WAV silence rather than an empty buffer (an empty buffer does not
//!   decode), which differs from the Vue provider whose output never reaches a decoder.
//! - `anima-core` does not re-export this crate yet (integration step for a later phase),
//!   and the stage app does not depend on it — `--smoke` (the GUI tour) is unaffected.
//! - The plan said "27 providers"; this repo's registry defines **26** ids.
//!
//! # Testing
//!
//! `cargo test -p anima-speech --all-targets` — Polly signing unit tests plus a
//! mock-TTS end-to-end test: a `mockito` server answers `POST /v1/audio/speech` with a
//! canned WAV, and the test asserts the request payload (model/input/voice + Bearer),
//! ≥ 3 amplitude events, Started/Done/Error events, disk-cache persistence (exactly one
//! HTTP hit across two speaks) and graceful `Error` mapping for HTTP 500. The abort test
//! uses a stash sink to verify `Cancel → Aborted` with `Done` suppressed.

mod cache;
mod client_common;
mod client_elevenlabs;
mod client_gemini;
mod client_kokoro;
mod client_mimo;
mod client_minimax;
mod client_noop;
mod client_openai;
mod client_openrouter;
mod client_player2;
mod client_polly;
mod client_unspeech;
mod client_voicevox;
mod config;
mod error;
mod pipeline;
mod player;
mod synth;
mod tap;
mod types;
mod wav;

pub use cache::{CachedAudio, SpeechAudioCache};
pub use client_kokoro::{KokoroConfig, KokoroSynthesizer, DEFAULT_VOICE, SAMPLE_RATE};
pub use config::{
    build_tts_client, build_tts_client_with_voice, find_tts_provider, tts_provider_ids,
    tts_provider_map, TtsProviderConfig, TtsProviderDef, TtsProviderKind, TtsStatus,
    TTS_PROVIDER_DEFS,
};
pub use error::SpeechError;
pub use pipeline::{CacheStats, SpeechPipeline};
pub use player::{list_output_devices, CaptureSinkFactory, RodioSinkFactory, SpeechSinkFactory};
pub use synth::SpeechSynthesizer;
pub use tap::{AmplitudeTap, BoxedSource};
pub use types::{AudioFormat, AudioStream, SentenceId, SpeechEvent, SynthesizeOptions};
pub use wav::wav_from_pcm16;
