// SPDX-License-Identifier: GPL-3.0-or-later

//! Native microphone capture, Silero VAD and speech-to-text clients.
//!
//! No toolkit dependencies — pure tokio / cpal / `ort` / reqwest. The model
//! download paths live on [`vad::model_path`] and
//! [`stt::whisper_local::model_path`]; the ALSA / PulseAudio / PipeWire capture
//! notes live on [`capture`].
//!
//! Module map:
//!
//! - [`capture`]: [`AudioCapture::start`] — cpal input → 16 kHz mono f32 →
//!   s16 PCM as `broadcast::Receiver<PcmChunk>` (`capture.rx`), 512-sample
//!   chunks (32 ms, the VAD window), peak/RMS meter via
//!   [`AudioCapture::level`] / [`AudioCapture::level_handle`].
//! - [`vad`]: [`SileroVad`] ONNX inference plus [`VadHysteresis`], a pure
//!   speech/silence state machine, and the [`VadEvent`] vocabulary.
//! - [`stt`]: the whole-blob [`stt::SttClient`] trait plus streaming
//!   [`stt::SttStream`] sessions over the shared [`stt::SttEvent`] vocabulary.
//! - [`stt::openai`]: [`stt::OpenAiTranscribeClient`] — OpenAI-compatible
//!   multipart transcription (also Groq).
//! - [`stt::deepgram`]: [`stt::DeepgramStreamingClient`] — Deepgram WS
//!   streaming.
//! - [`stt::aliyun`]: [`stt::AliyunNlsClient`] — Alibaba Cloud NLS
//!   `SpeechTranscriber` WS streaming.
//! - [`stt::whisper_local`]: [`stt::WhisperLocalClient`] — on-device
//!   whisper.cpp whole-blob transcription.
//! - [`mic`]: [`MicService`] — start/stop capture, fan frames to the VAD, PTT
//!   and Auto modes, broadcast [`MicEvent`]s.
//!
//! # Testing
//!
//! `cargo test -p anima-stt --all-targets`. The hysteresis state machine is
//! deterministic and needs no model; the OpenAI-compatible path runs against an
//! in-process mock TCP server (`tests/common/mod.rs`, raw HTTP/1.1); the
//! hardware capture test skips when no usable input device exists (CI VMs).
//! Silero and Whisper tests skip gracefully when their model cannot be
//! obtained; set `SILERO_SKIP_DOWNLOAD=1` /
//! `AIRI_QT_WHISPER_SKIP_DOWNLOAD=1` to exercise only the cache-hit path.
//!
//! # Deliberately out of scope
//!
//! - Echo cancellation / duplex self-listening (the
//!   [`mic::MicConfig::duck_while_speaking`] hook only sheds frames).
//! - Composer transcript injection (bridge wiring, later phase).
//! - Resampling: non-16 kHz devices error out.
//! - Aliyun AK/SK token exchange — [`stt::AliyunNlsConfig::token`] is
//!   pre-issued.
//! - Hot-swapping streaming providers mid-session.

pub mod capture;
pub mod mic;
pub mod stt;
pub mod vad;

pub use capture::{AudioCapture, AudioLevel, CaptureConfig, CaptureError, PcmChunk};
pub use mic::{MicConfig, MicError, MicEvent, MicMode, MicService, StreamingStt, SttConfig};
pub use stt::{
    AliyunNlsClient, AliyunNlsConfig, DeepgramStreamingClient, OpenAiTranscribeClient, SttClient,
    SttError, SttEvent, SttRequest, SttStream, WhisperLocalClient,
};
pub use vad::{SileroVad, VadConfig, VadEvent, VadHysteresis};
