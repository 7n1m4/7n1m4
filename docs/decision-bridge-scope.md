<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Bridge scope — speech/hearing/MCP/ACP/Discord (daemon RPC vs client-local vs unsupported)

- **Status:** accepted (2026-11-21, ponytail)
- **Bead:** `airi-wxp.1.8` (child of epic `airi-wxp.1`)
- **Scope:** Which peripheral bridges become daemon RPCs, which stay client-local, and which are unsupported. No bridge moves without its own implementation issue.

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
- Speech/hearing never move to daemon; Discord bot stays in the desktop app.
- MCP and ACP are the only daemon-RPC bridges; their RPC shapes follow the core RPC contract.

## Verification

- Doc present at `docs/decision-bridge-scope.md`.
- Bead `airi-wxp.1.8` closed after ratification.