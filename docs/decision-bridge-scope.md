<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Bridge scope — speech/hearing/MCP/ACP/Discord (daemon RPC vs client-local vs unsupported)

- **Status:** accepted (2026-11-21, ponytail)
- **Bead:** `airi-wxp.1.8` (child of epic `airi-wxp.1`)
- **Scope:** Which peripheral bridges become daemon RPCs, which stay client-local, and which are unsupported. No bridge moves without its own implementation issue.
- **Authority:** This decision is **authoritative for bridge / audio-hardware ownership** and **supersedes §2 decision 7 of `docs/design-flutter-godot-pivot.md`** ("The daemon owns VAD/STT → LLM → TTS and emits events") for the audio path. Rationale: that ADR row was explicitly recorded as a *net-new intent* — no audio was pumped into the pipeline and `anima-daemon` linked none of `anima-stt` / `anima-llm` / `anima-speech` — and decision 10 of the same ADR makes the daemon a remote-capable, headless core (mobile is a thin client), so the daemon host has no microphone or speaker hardware. This bridge-specific, ratified decision (bead `airi-wxp.1.8`, closed) is the narrower and later resolution and therefore governs. The LLM stage may remain daemon-owned, but the mic-capture/VAD and playback halves of the pipeline are client-local; there is no single daemon-owned VAD→STT→TTS audio path.

## Decision table

| Bridge | Scope | Rationale | Trust/privacy | Owner |
|---|---|---|---|---|
| Speech (STT/TTS) | Client-local | Audio capture/playback is device-bound; daemon has no audio hardware access. | Audio never leaves client unless opted into cloud STT provider. | Client (Flutter/Godot) |
| Hearing (microphone VAD) | Client-local | VAD runs on device audio stream; daemon cannot observe mic. | Same as speech. | Client |
| MCP (tool servers) | Daemon RPC | Tool invocation is stateful and shared across clients; daemon owns the registry. | Tool results may contain PII; daemon is trust boundary. | Daemon (anima-daemon) |
| ACP (agent control plane) | Daemon RPC | Agent lifecycle/state is daemon-owned; clients are views. | Agent state persists server-side. | Daemon |
| Discord | Client-local (bot stays in app) | Discord bot token is user-secret; running in daemon would widen blast radius and couple daemon to Discord API churn. | Token stays on client device. | Client (stage-tamagotchi) |

## Consequences

- No bulk migration: each bridge that becomes a daemon RPC needs its own implementation issue.
- Speech/hearing never move to daemon; Discord bot stays in the desktop app. This resolves the conflict with `design-flutter-godot-pivot.md` §2 decision 7 — that ADR row is superseded here for the audio path (see Authority above); the LLM stage can still be daemon-owned, but capture/VAD and playback stay on the client.
- MCP and ACP are the only daemon-RPC bridges; their RPC shapes follow the core RPC contract.
- Wire-event ownership follows the bridge split: `emotion.tag` stays **daemon-published** (derived from the daemon-owned LLM token stream / ACT markers), while `lip_sync.rms` is **not** published by the daemon — thin clients must generate it locally from local TTS playback, since the daemon has no mic/audio hardware. Until Flutter/Godot produce it, client-side lip-sync animation is a known parity gap; do not claim it as complete.

## Verification

- Doc present at `docs/decision-bridge-scope.md`.
- Bead `airi-wxp.1.8` closed after ratification.