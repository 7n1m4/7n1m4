<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# anima-stt

Native microphone capture + Silero VAD + speech-to-text clients (pure
tokio / cpal / `ort` / reqwest; no toolkit dependencies).

The crate contract — module map, the Silero v5 ONNX protocol and model-cache
location, the Linux ALSA/PipeWire capture notes, per-provider status, mic modes
and duplex behaviour, and the test story — lives in the rustdoc for
[`src/lib.rs`](src/lib.rs), [`src/capture.rs`](src/capture.rs),
[`src/vad.rs`](src/vad.rs), [`src/stt/`](src/stt) and [`src/mic.rs`](src/mic.rs)
(`cargo doc -p anima-stt --open`).
