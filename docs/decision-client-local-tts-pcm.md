<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Client-local TTS/PCM engine for Flutter and Godot

- **Status:** accepted (2026-11-24, user-ratified; bead `airi-4ab`)
- **Bead:** `airi-4ab` (blocks `airi-xpy`, which blocks `airi-b2q`)
- **Scope:** which concrete engine/source produces client-local TTS PCM so each thin client can generate `lip_sync.rms` envelopes. No code changes in this doc; implementation is tracked by `airi-xpy`. (Ratified 2026-11-24.)
- **Runtime setup:** see [`guide-client-local-tts-runtime.md`](./guide-client-local-tts-runtime.md) for reproducible downloads, environment/config names, and license verification steps.

## Context

`docs/decision-bridge-scope.md:24` (accepted, authoritative for audio-hardware ownership) requires each thin client to generate `lip_sync.rms` from its **own local TTS playback**; the daemon never publishes it. Verified current state:

- Neither client has any audio path. `apps/flutter/pubspec.yaml:9-22` declares no audio/TTS dependency; Flutter has no renderer at all and subscribes only to `token.delta` (`apps/flutter/lib/daemon_client/daemon_client.dart:280-295`). Godot has the full *consumer* half — `Main.cs:179-181` routes `lip_sync.rms` → `IPetRenderer.SetLipSync(level)` → `LipSyncSmoother` (120 ms decay, port of `crates/anima-render/src/vrm/lipsync.rs`) — but nothing feeds it, and `rg` over `godot/` finds zero `AudioStreamPlayer`/`AudioServer`/TTS references.
- The reference RMS algorithm is `crates/anima-speech/src/tap.rs`: 50 ms non-overlapping windows at the source's own sample rate, `level = min(1.0, sqrt(sum(x²)/count))` over interleaved samples, one emission per window plus a partial-tail flush, silent drain while aborted, exactly one `Done` per sentence. In-tree cadence is ~15–40 Hz (`anima-speech/src/types.rs:118-120`).
- Godot already has the matching smoothing sink; Flutter has neither producer nor consumer.

> **Historical note (ratification-time snapshot):** the bullets above describe the state when this decision was ratified. The `airi-xpy` seam work has since added `apps/flutter/lib/speech/` and `godot/scripts/Audio/` (option B engine adapters, option C WAVE decoders, and RMS taps), and `airi-0v8` wired the engine path: Flutter exposes usable Piper/sherpa seams and Godot's `Main.cs` hosts a Piper-backed `LocalSpeechPipeline` that feeds its renderer. Flutter still has no renderer and the Godot backends remain generic stubs; see the runtime guide and `docs/feature-parity-checklist.md` for current status rather than treating this snapshot as live state.

## Options considered

| Criterion | A. Platform TTS + PCM tap | B. On-device model (sherpa-onnx / Piper) | C. Explicit audio-file playback + PCM reader |
|---|---|---|---|
| PCM access for RMS | **Asymmetric, mostly absent.** Android `TextToSpeech.synthesizeToFile()` can dump a wav and Windows SAPI can stream to a file, but iOS/macOS `AVSpeechSynthesizer` and web SpeechSynthesis expose nothing; a live tap means redirecting OS voice output. Fails the real-PCM test criterion on iOS/macOS/web. | **Strong.** Synthesizer returns raw PCM/float arrays directly (sherpa-onnx `OfflineTts.generate()` / Piper via onnxruntime); the tap wraps the buffer with no OS involvement. | **Strongest.** Decode is fully in-process (Godot `AudioStreamGenerator` / Flutter PCM-capable player); every sample is readable pre-output. |
| Cross-platform | Android/iOS/macOS/Windows all have TTS, but each needs its own tap and some cannot tap at all. | sherpa-onnx: Android/iOS/Linux/macOS/Windows; Piper same via onnxruntime. Godot C# and Dart both have bindings or a small FFI shim. | Trivially cross-platform (decode + play is already a solved path on both engines). |
| Dependency / licensing | No new binary. | onnxruntime + model artifacts; **constraint: no proprietary binaries committed** — models ship as downloaded assets with per-vendor license verification, not repo blobs. | A PCM-capable decoder dependency (Godot built-in `AudioStreamWAV`; Flutter PCM-capable player). |
| Latency | OS-dependent; acceptable for pet speech. | Low (offline, in-process); sherpa-onnx streams sentence-by-sentence. | Lowest (pre-rendered). |
| Offline | Full. | Full. | Full. |
| Unblocks a real (non-fake) envelope test? | **No** on at least iOS/macOS/web — no PCM to sample. | Yes — PCM from the synthesizer is real audio. | Yes — PCM from the decoded file is real audio. |

## Decision

**Option B — on-device Piper-class TTS exposing PCM — is the primary path; Option C (audio-file playback with PCM reader) is the accepted fallback and the testability harness.**

Option B produces PCM by construction and matches the daemon's existing speech-provider shape (OpenAI-compatible synth → PCM, see `crates/anima-speech/src/synth.rs:16-26`, the `SpeechSynthesizer` trait returning an `AudioStream`). Option C is kept because it is the smallest thing that unblocks `airi-b2q`'s test today with zero new engine dependencies, and it doubles as the deterministic fixture path for B's tests.

Concretely:

1. Godot: add a Piper/sherpa-onnx-style on-device synth (C# binding or a small native shim) whose PCM output feeds an `AudioStreamGenerator` for playback **and** the RMS tap; feed `SetLipSync(level)` from the tap. Keep `LipSyncSmoother` untouched.
2. Flutter: same shape once `airi-xpy` scopes the Flutter renderer (Flutter currently has no renderer — this is a known gap, not a surprise); until then Flutter's generator emits only the RMS stream + event frames.
3. Both clients mirror `AmplitudeTap`'s math exactly: 50 ms windows, non-overlapping, `min(1.0, sqrt(mean(x²)))`, one frame per window, partial-tail flush, `Done` on natural end, silence while aborted.
4. Client-generated frames use the existing wire shape `LipSyncRmsData { actor_id, level, seq, ts_ms }` with client-stamped monotonic `seq` and epoch-ms `ts_ms` (the daemon stamps these on its own bus; a client-local generator must do the same itself). Godot's current `Main.cs` subscription to daemon-published `lip_sync.rms` becomes dead once local generation lands — remove the subscription in `airi-xpy`, keep the decode path for parity tests.
5. No proprietary binaries or models are committed to the repo; model artifacts are downloaded assets with per-vendor license verification.

## Runtime shapes landed so far

The `airi-xpy` seams and the `airi-0v8` runtime wiring below bundle no binary or model:

- Flutter: `PiperTtsEngine` (local `piper` CLI → real WAVE → `WavPcmSource`), `SherpaTtsEngine` (optional `package:sherpa_onnx` adapter injected via `SherpaLoaderRegistry`/`registerSherpaLoader`), `TtsEngine`, `PcmSource`, `AmplitudeTap`, and `LipSyncGenerator`. `pubspec.yaml` still has no TTS dependency, so the sherpa-onnx path is unavailable until an app supplies the plugin; the Piper CLI path needs local binary/model files. An opt-in runtime test uses `PIPER_MODEL` (with optional `PIPER_PATH`) to exercise real Piper output when present; it is skipped otherwise.
- Godot: `PiperTtsEngine` (local `piper` CLI → real WAVE → `WavPcmReader`), `ITtsEngine`, `IPcmSource`, `AmplitudeTap`, `PcmLipSyncDriver`, and the pure-managed `LocalSpeechPipeline` (`SpeakAsync` → tap → `IPetRenderer.SetLipSync`). `Main.cs` enables the Piper-backed `LocalSpeechPipeline` when `PIPER_MODEL` is set, plays its PCM through `AudioStreamPlayer`, and feeds the renderer through the RMS tap; without a model the scene runs silently.
- Option C in both clients reads a real WAVE file into PCM; it is a deterministic harness/decoded-file fallback, not synthesized TTS output.
- Authorship of local frames: client-stamped `seq`/`ts_ms` in the `LipSyncRmsData` shape, as required above. Godot's daemon-event decode path is retained for parity tests; `Main.cs` no longer subscribes to daemon `lip_sync.rms` because it generates local RMS from speech and feeds it to the renderer.

Recognized download sources, env/config names (`PIPER_PATH`, `PIPER_MODEL`, `SherpaTtsConfig` paths, Godot's `sampleRate` constructor argument), and per-vendor license checks are documented in [`guide-client-local-tts-runtime.md`](./guide-client-local-tts-runtime.md). Those checks are distribution-time responsibilities; no license verification happens at runtime.

## Tradeoffs accepted

- New dependency surface on both clients (onnxruntime-class runtime + model download). This is the price of real PCM; Option A's zero-dependency appeal does not survive its own criterion.
- Model voice quality and language coverage are bounded by the chosen vendor; revisit if a better-licensed model appears.
- Flutter needs a renderer before end-to-end lip-sync is observable there; `airi-b2q` is satisfied per-client with what each client has (Godot: renderer + observable mouth/scale; Flutter: RMS stream + frames, renderer gap tracked separately).

## Verification

- This doc at `docs/decision-client-local-tts-pcm.md` with status accepted (ratification-time evidence only; no new test claims here).
- `airi-4ab` closed with the ratification comment; `airi-xpy` updated with the implementation target (Piper-class on-device synth + `AmplitudeTap` mirror per client; Option C as fallback/test harness). Implementation target recorded on `airi-xpy` 2026-11-24: per client, (1) on-device Piper-class synth producing raw PCM, (2) `AmplitudeTap` mirror (50 ms non-overlapping windows, `min(1.0, sqrt(mean(x²)))`, one frame per window + tail flush, silence while aborted, exactly one terminal Done), (3) feed the existing lip-sync sink (Godot: `IPetRenderer.SetLipSync`; Flutter: renderer gap tracked separately), (4) client-stamped monotonic `seq` + epoch-ms `ts_ms` in `LipSyncRmsData` shape. Option C (audio-file playback + PCM reader) is the deterministic test harness.
- `airi-b2q` unblocked once `airi-xpy` lands.
