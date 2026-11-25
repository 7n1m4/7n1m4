<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Guide: client-local TTS runtime setup (Flutter only)

Companion to [`decision-client-local-tts-pcm.md`](./decision-client-local-tts-pcm.md) (ratified Option B: on-device Piper-class TTS exposing PCM; Option C: real WAVE decode as fallback/test harness). This guide covers the **user-supplied binaries and models** the thin clients need. It does not claim full app-level runtime wiring or test results; check [`feature-parity-checklist.md`](./feature-parity-checklist.md) for status. Godot/C# TTS runtime is historical/retired and no longer actively configured.

## No binaries or models in the repository

No proprietary binaries, TTS executables, ONNX models, voice assets, or generated audio blobs are committed to this repo. The clients reference locally installed/downloaded files. If an engine asset is missing, the engine fails loudly (`TtsEngineUnavailable` on Flutter; Godot/C# path is historical/retired) — never substitute synthetic amplitudes or a fake PCM source. Option C fixtures are deterministic **real** WAVE files generated for tests, not TTS output.

## Recognized engines

| Client | Engine seam | What actually produces PCM | Status of runtime wiring |
| --- | --- | --- | --- |
| Flutter | `PiperTtsEngine` (`apps/flutter/lib/speech/piper_tts_engine.dart`) | Local `piper` CLI writes a WAVE file; `WavPcmSource` decodes it in-process | Engine seam only: the app does not select it yet |
| Flutter | `SherpaTtsEngine` + `SherpaLoader` (`apps/flutter/lib/speech/sherpa_tts_engine.dart`) | `package:sherpa_onnx` `OfflineTts.generate()` returns real f32 samples | Adapter is optional; no `sherpa_onnx` dependency in `pubspec.yaml` and no app-level loader registration yet |
| Godot | `PiperTtsEngine` (`godot/scripts/Audio/PiperTtsEngine.cs`) | Local `piper` CLI writes a WAVE file; `WavPcmReader` decodes it | Historical/retired: no active config |
| Both | `WavPcmSource` / `WavPcmReader` (Option C) | Decode a real WAVE asset/file | Available as deterministic test harness and explicit decoded-file fallback |

## Piper (both clients)

Versions checked when this guide was written (2026-11-24): upstream `rhasspy/piper` latest release `2023.11.14-2`, `rhasspy/piper-voices` hub revision `e5349433ed883a32f893a434dc43a6c66b95ef7c`. Pin the same versions in a deployment so a model/binary refresh cannot silently change audio or licensing terms; re-run the license checks below when bumping either.

1. Install a `piper` executable. The pinned upstream release publishes, among others, `piper_linux_x86_64.tar.gz`, `piper_macos_aarch64.tar.gz`, and `piper_windows_amd64.zip` at <https://github.com/rhasspy/piper/releases/tag/2023.11.14-2>. Extract the archive outside the repo and either put the executable on `PATH` or set `PIPER_PATH` to its absolute path. Linux example (the archive contains `piper/piper`; Windows contains `piper/piper.exe`):

   ```sh
   # Outside the repository checkout.
   curl -fL -o piper.tar.gz \
     https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz
   sha256sum piper.tar.gz       # record the digest from a trusted source / your supplier
   tar -xzf piper.tar.gz
   ./piper/piper --help
   export PIPER_PATH="$PWD/piper/piper"
   ```

   Verify the archive hash against a trusted source before running the binary; the plugin seams do not verify checksums themselves.

2. Download a voice (model + sidecar config) from <https://huggingface.co/rhasspy/piper-voices>, e.g. `en_US-lessac-medium.onnx` and `en_US-lessac-medium.onnx.json`. Keep both files together; the sidecar carries sample rate/voice metadata. To pin the same hub revision as this guide:

   ```sh
   export PIPER_VOICES_REV=e5349433ed883a32f893a434dc43a6c66b95ef7c
   curl -fL -o en_US-lessac-medium.onnx \
     "https://huggingface.co/rhasspy/piper-voices/resolve/${PIPER_VOICES_REV}/en/en_US/lessac/medium/en_US-lessac-medium.onnx"
   curl -fL -o en_US-lessac-medium.onnx.json \
     "https://huggingface.co/rhasspy/piper-voices/resolve/${PIPER_VOICES_REV}/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"
   export PIPER_MODEL="$PWD/en_US-lessac-medium.onnx"
   ```

   Optional but recommended: save the resolved file digests (e.g. `sha256sum en_US-lessac-medium.onnx*`) alongside your deployment manifest. A direct smoke check with the installed binary, before involving either client, is `printf 'hello\n' | "$PIPER_PATH" --model "$PIPER_MODEL" --output_file /tmp/piper-smoke.wav`; verify the result is a real RIFF/WAVE file (`file /tmp/piper-smoke.wav`). This is a genuine engine synthesis check, not a fixture, and is **not** a claim that this project's client tests were run.

   Note the CLI shape used by both seams: `piper --model <PIPER_MODEL> --output_file <temp.wav>` with the spoken text written to the process's stdin (the Flutter engine does this; the Godot/C# engine was historical). The downloaded release binary must accept that shape. The Godot/C# engine (historical/retired) exposed `sampleRate` (constructor override; default `DefaultSampleRate = 22050`) separately from the model's sidecar; Flutter derives sample rate from the decoded WAVE header.

3. Set environment variables before launching the client:

   | Variable | Meaning | Default |
   | --- | --- | --- |
   | `PIPER_PATH` | Path to the `piper` executable | `piper` (resolved via `PATH`) |
   | `PIPER_MODEL` | Path to the downloaded `.onnx` voice model | unset — Flutter/Godot throw a configuration error rather than guessing |
   | `PIPER_SAMPLE_RATE` | Godot only: expected sample rate (Hz) of the synthesized WAV; must be a positive integer | `22050` |

   Set `PIPER_SAMPLE_RATE` to the rate in the voice sidecar when it differs from 22050 Hz; Godot passes it to `PiperTtsEngine`, which rejects a WAV whose decoded rate differs (the sample rate is not read from the sidecar at runtime). An invalid or non-positive value fails client startup loudly instead of being ignored. Constructor arguments override these variables (`PiperTtsEngine(executable:, modelPath:)` in Dart; `PiperTtsEngine(piperPath:, modelPath:, sampleRate:)` in C#); the Dart seam has no sample-rate environment override. No daemon setting or gateway RPC supplies these paths; they are local process configuration only.

## sherpa-onnx (Flutter, optional adapter)

Version reference at guide time: `k2-fsa/sherpa-onnx` release `v2.0.3` (the Flutter engine comment names `package:sherpa_onnx` 2.0.3). Treat that as a compatibility target, not a lockfile change: this repo's `pubspec.yaml` deliberately has no TTS dependency.

1. Add `package:sherpa_onnx` (target 2.0.3) to the Flutter app that wants this engine; the core package intentionally does not depend on it so builds work without the native library. Confirm the plugin's native/shared-library prerequisites for the target platform from its package documentation.
2. Download a compatible VITS/Piper-class `.onnx` model plus its `tokens.txt` (and a lexicon, if that model requires one). Use the model vendor's release/Hugging Face page; do not copy model files into the repo. Pin a revision or specific release asset and record its digest in your deployment manifest.
3. Pass paths via `SherpaTtsConfig(model:, tokens:, lexicon:, numThreads:, speakerId:, speed:)` — there are **no environment variables** for these in the current seam. Implement a `SherpaLoader` adapter around the plugin's `OfflineTts` and call `registerSherpaLoader(loader)` at app startup; `SherpaTtsEngine.initialize()` then loads bindings and validates the reported sample rate. Without a registered loader it throws `TtsEngineUnavailable`.

## Verify licenses before shipping

"Downloadable" does not mean "redistributable with this app". Check these in the exact artifact/version you use, and record the outcome in your downstream distribution's notices:

1. **Piper runtime**: upstream is MIT (`https://github.com/rhasspy/piper/blob/master/LICENSE.md`). Verify the tag/release archive you actually downloaded still carries that license; the GitHub release binary may have additional bundled-dependency notices.
2. **Piper voices**: the `rhasspy/piper-voices` hub declares MIT at the repository level (`https://huggingface.co/rhasspy/piper-voices/blob/main/README.md`), but individual voice directories carry their own `MODEL_CARD` with dataset licenses that can differ (for example `en/en_US/lessac/medium/MODEL_CARD` points to the Blizzard 2013 Lessac dataset license; voices may also be Apache-2.0 or CC-BY-SA). Read the `MODEL_CARD` next to the exact `.onnx` file at your pinned revision and check any linked dataset license before redistribution or commercial use.
3. **sherpa-onnx runtime**: Apache-2.0 (`https://github.com/k2-fsa/sherpa-onnx/blob/master/LICENSE`). Check the plugin package's own LICENSE and third-party notices for the native library you ship.
4. **sherpa-onnx models**: each model repository has its own license (often a Creative Commons variant or a research-only license). Read the model card/LICENSE in that repository; do not assume the runtime's Apache-2.0 covers the weights.

When in doubt, keep the asset user-supplied (paths above) instead of bundling it. No license check is performed at runtime; verification is a distribution-time responsibility.

## Proving text → PCM → RMS → sink honestly

- Flutter: build a real `TtsEngine`/explicit `WavPcmSource`, call `synthesizeToSource(text)`, then `LipSyncGenerator(actorId:, source:, abort:).frames()`. The frames carry `{actor_id, level, seq, ts_ms}` with client-stamped monotonic `seq` and epoch-ms `ts_ms`. There is no Flutter renderer sink yet; the honest proof ends at the frame stream.
- Godot: `Main.cs` builds an `ITtsEngine` for completed assistant turns and `LocalSpeechPipeline` feeds it through `PcmLipSyncDriver` into `IPetRenderer.SetLipSync(level)` → `LipSyncSmoother` → renderer node state, while playing the same PCM. The shipped `GenericPetRenderer` exposes that state as scale/tint/animation key; the VRM/Live2D backends are stubs without vendored addons.
- The RMS window is 50 ms, non-overlapping, at the PCM source's own sample rate; `level = min(1, sqrt(mean(x²)))` with a partial-tail flush, silence/drain when aborted, and exactly one terminal `Done` on natural completion (no `Done` after abort). Do not feed fabricated samples through this path to claim engine coverage.
