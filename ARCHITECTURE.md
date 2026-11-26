# ARCHITECTURE.md — Project Blueprint (Rust Core + Flutter Client)

> **Status: normative.** This document states the rules agents must follow. When code and this blueprint disagree, the code wins and this file must be corrected in the same change. Detail lives in [`docs/README.md`](./docs/README.md), [`docs/design-daemon-gateway.md`](./docs/design-daemon-gateway.md), [`docs/design-flutter-godot-pivot.md`](./docs/design-flutter-godot-pivot.md), [`docs/decision-bridge-scope.md`](./docs/decision-bridge-scope.md), and the parity ledger [`docs/feature-parity-checklist.md`](./docs/feature-parity-checklist.md). Names below use the repository's real crates; the `airi-protocol` / `airi-core` / `flutter-client` names in older proposals are reference-only aliases, not crates to create.

## 1. Core philosophy & licensing

- **One owner of truth.** `crates/anima-daemon` is the long-lived agent runtime. All state-changing business logic lives in Rust. `apps/flutter` is the primary and only active renderer on desktop and mobile, at full stage-UI parity. The TypeScript stores in `packages/stage-ui` and `apps/stage-web` / `apps/stage-tamagotchi` are *behaviour references*, not a second authority. "Thin client" means no competing state writer — never a reduced feature surface.
- **Do not start** gateway trust-gate changes, the gated `airi-3cp` retirement, or a second state writer without explicit authorization. Godot and the Capacitor stage-pocket are purged; do not reintroduce them.

### Licensing (strict)

| Scope | License | Required action |
| --- | --- | --- |
| Upstream-derived TypeScript, Vue, and other third-party code under `packages/**`, `apps/stage-web/**`, `apps/stage-tamagotchi/**` | Its existing MIT/upstream license | Preserve upstream headers and attribution. Root [`LICENSE`](./LICENSE) is MIT; third-party texts are in [`LICENSES/`](./LICENSES). Never relicense upstream code or strip its notices. |
| All new code written for this pivot — `crates/**` and the Flutter client in `apps/flutter/**` | **GPL-3.0-or-later** | Put `// SPDX-License-Identifier: GPL-3.0-or-later` at the top of every new source file; keep the crate manifests' `license = "GPL-3.0-or-later"` in sync. |
| Generated bindings/fixtures | Same license as their source | Regenerate in the same commit as the source change; never hand-edit generated TS. |

Mixing direction is one-way: GPL-3.0-or-later new code may reference MIT upstream code, but upstream MIT trees must not absorb GPL-only implementation without an explicit licensing decision.

### Zero-lag startup (hard requirement)

- Time from process launch to a usable first character frame **plus gateway subscription must be < 200 ms** on the reference Linux development machine.
- Heavy subsystems (STT, TTS, local inference, vector DB, external gateways) initialize **lazily in background tasks** and attach through hot-plug module-status events. No eager model load, network call, or database migration may sit on the startup or first-frame path.
- Never block the UI isolate on I/O, model loading, or synthesis. A missing worker produces a degraded-but-live avatar, never a blank or frozen one.
- **Current status:** this budget is not yet instrumented. Any change that adds startup work must include a before/after timing measurement or an equivalent bounded-work argument in its bead evidence.

## 2. Repository structure

```text
/
├── Cargo.toml                  # Workspace root (GPL-3.0-or-later SPDX)
├── ARCHITECTURE.md             # This blueprint
├── LICENSE                     # MIT (upstream/client surface)
├── LICENSES/                   # Third-party license texts
├── crates/                     # GPL-3.0-or-later — the Rust runtime core
│   ├── anima-channel/          # WS/wss :6121, auth handshake, wire DTOs + events (no heavy deps)
│   ├── anima-core/             # AppCore: settings, chat, cards, memory, grounding (state owner)
│   ├── anima-store/            # SQLite repositories and transactions
│   ├── anima-llm/              # LLM streaming clients, emotion-tag parsing
│   ├── anima-local-llm/        # WebGPU/WASM local inference seams
│   ├── anima-speech/           # TTS clients, viseme/RMS seams, local audio cache
│   ├── anima-stt/              # Transcription workers
│   ├── anima-render/           # VRM/MMD/Spine native backends (Live2D gated)
│   ├── anima-mcp/ anima-acp/ anima-sync/ anima-discord/ anima-a11y/
│   ├── anima-i18n/ anima-supervisor/ anima-mmd/
│   └── anima-daemon/           # Session daemon: gateway host, D-Bus control, privileged integrations
├── apps/
│   ├── flutter/                # GPL-3.0-or-later — sole active renderer (desktop + mobile)
│   ├── stage-web/              # MIT/upstream — behaviour reference
│   └── stage-tamagotchi/       # MIT/upstream — Electrobun behaviour reference (not Electron)
├── packages/                   # MIT/upstream — TS reference stores and generated bindings
└── docs/                       # Canonical design, parity ledger, ADRs
```

Reference-template mapping: `airi-protocol` → `anima-channel` + `wire.rs`; `airi-core` → `anima-core` / `AppCore`; `airi-modules` → daemon module lifecycle + `anima-supervisor`; `airi-llm` → `anima-llm`; `airi-audio` → `anima-speech` + `anima-stt` (client-local seams); `airi-server` → `anima-daemon` + `anima-channel`; `flutter-client` → `apps/flutter`.

## 3. Concurrency model: one state owner, message passing, strict priority

All mutable character/session state has exactly one owner: the daemon's `AppCore`/`CoreService`. Clients hold view state and client-local audio/render state only.

### Rules for agents writing Rust

1. **No new `Arc<Mutex<CharacterState>>`.** Do not share mutable character state across threads. Use `tokio::sync::mpsc` for work queues and `tokio::sync::broadcast` for events. The existing `CoreService { inner: Arc<Mutex<CoreInner>> }` is transitional debt — never widen it with hot-path mutable fields, and route new state through the daemon's repositories and event bus instead.
2. **Strict priority in the main loop.** Process in this order and never let a lower priority starve a higher one:

   | Priority | Event | Wire / source | Non-negotiable behaviour |
   | --- | --- | --- | --- |
   | 1 — highest | `CharacterEvent::UserInterrupt` | `chat.cancel` / VAD semantic | Immediately bump the turn/utterance id, drop the pending TTS queue, publish a terminal cue, and notify every client. |
   | 2 | `CharacterEvent::AudioFrameReady` | `lip_sync.rms` (~15–40 Hz, 20 ms target) | Keep audio and lip-sync smooth; never fabricate a frame from elapsed time; stale utterance/turn ids are dropped by clients. |
   | 3 | `CharacterEvent::UserMessage` / `CharacterEvent::LlmToken` | `chat.send` / `token.delta` (with `session_id`, `message_id`, `seq`) | Filter foreign sessions per `chat_screen.dart:183-192` / `stage_overlay_state.dart`; cancelled/error finals are terminal even without `final: true`. |
   | 4 — lowest | `CharacterEvent::ModuleStatus` / `CharacterEvent::IdleTick` | module status, heartbeat, idle/proactivity | Best-effort only; may be skipped under load and must never block priorities 1–3. |

3. **CPU-bound work is off the async runtime.** Audio resampling, Opus encoding, and FFT/viseme math run in `tokio::task::spawn_blocking` or dedicated OS threads and report results through `mpsc`. Existing precedent: `crates/anima-speech/src/client_kokoro.rs:557`.
4. **State transitions are a test contract.** `Idle → Listening → Thinking → Speaking → Interrupted → Listening` must have unit tests for every edge, including barge-in and failed/cancelled generations. *Current status:* the explicit state machine is not yet landed; turn state is expressed by streaming flags in `anima-core::chat` and the Flutter speech bridge. New turn-state code must add the transition tests as part of the change.

## 4. Client–server protocol (`anima-channel`)

One authenticated WebSocket/wss connection on port **6121**, loopback by default; **wss is mandatory beyond loopback** regardless of the config flag. The gateway config, token regeneration and bind state are controlled over the session D-Bus interface `org.moeru.airi.Daemon1` — never over an untrusted RPC.

### A. Control frames — UTF-8 JSON text

`GatewayClientFrame` / `GatewayServerFrame` in `crates/anima-channel/src/wire.rs` are internally tagged on `type`: `auth`, `module:authenticate`, `ping`/`pong`, `transport:connection:heartbeat`, and `rpc` with `{ action, payload?, id? }`. Replies echo `id` verbatim and carry either `data` or `error`. Server-initiated events use `GatewayEventFrame { topic, rawTopic, data, id? }`; the topic is validated against `EventTopic` (`token.delta`, `emotion.tag`, `lip_sync.rms`, …) and payload shapes are chosen by topic. Control frames carry state transitions, subtitles, module status and interrupt commands (`chat.cancel`); never bulk binary media.

### B. Realtime media frames — binary, when introduced

Audio and viseme data are **client-local today** (`decision-bridge-scope.md`; `lip_sync.rms` is a JSON event carrying `{ actor_id, level, seq }`). Any future binary media transport must use this compact layout, 20 ms cadence, and no JSON serialization on the hot path:

| Offset | Width | Field | Rule |
| --- | --- | --- | --- |
| 0 | `u8` | packet type | `0x01` = audio + lip-sync frame; unknown types are ignored |
| 1..5 | `u32` BE | `utterance_id` | Clients drop frames where `frame.utterance_id != current_utterance_id` |
| 5 | `u8` | `viseme_id` | `0` closed, `1` A, `2` O, `3` U, `4` E, `5` I |
| 6 | `u8` | `mouth_open` | Normalized amplitude `0..=255` |
| 7..N | bytes | audio payload | Opus or raw PCM 16-bit 24 kHz mono; size bounded by the WS frame cap |

Utterance ids are monotonically increasing per character; an interrupt publishes a new id before any further media frame. Introducing a daemon-side PCM relay requires a new ADR — do not duplicate the client-local audio ownership.

### Protocol invariants

- Every **mutating** verb must be registered through the `gated()` wrapper (`gateway.rs:768`): `allowActions: true`, plus `allowRemoteActions: true` beyond loopback. Mutating verbs are denied by default and the denial is tested.
- Read-only verbs may be ungated only when their reply is a scrubbed projection. `settings.get("mcp")` masks `env`/`headers`/`token` (`gateway.rs:966,975-981`, `core.rs:55-84,831-842`); `settings.get("discord")` exposes `has_token` instead of `token` (`gateway.rs:966,986-992`, `core.rs:331-335,733-758`, `settings.rs:1943-1983`, commit `1bbe6942`). Both are the mandatory precedents: a new credential-bearing section needs the same treatment, and a mask-echo PATCH must preserve the stored secret (`core.rs:150-243`).
- `wire.rs` is Rust-canonical. Typed additions must regenerate `packages/server-shared/src/types/generated/anima-channel.ts` with `pnpm check:wire-types` in the same commit. Raw `serde_json::Value` verbs (like `sessions.fork`) are allowed only when no client codegen is needed; document the choice at the handler.
- Auth tokens, API keys and secret configuration never appear in logs, event payloads, backups or unmasked reads.

## 5. Agent implementation guidelines

- Use `thiserror` for library crates (`anima-core`, `anima-channel`, etc.); reserve `anyhow` for binary entry points. `anima-core::lib.rs` currently uses `anyhow::Result` — legacy debt, not a pattern to copy into new modules.
- Target `#![deny(clippy::unwrap_used)]` in `anima-core`. Until the attribute can be enabled, production code must have no `unwrap`/`expect` on untrusted input; tests may use them. Panics in a worker must never take down the character brain.
- File new source with the correct SPDX header (§1), follow the nearest existing module pattern, and keep the diff scoped to the owning lane: `apps/flutter/**` only for Flutter work; `crates/**`, `packages/**`, `apps/stage-{web,tamagotchi}/**` for Rust/TS work. Never stage another lane's paths.
- Validate proportionally: `cargo test --workspace --locked -- --test-threads=1` (parallel runs are flaky on pre-existing `chat_send` tests), `cargo fmt -p <touched crates> --check` (all crates are **edition 2021** — never `rustfmt --edition 2024`), `pnpm check:wire-types` for typed wire changes, `flutter test` plus `flutter analyze` on changed Dart files, and `pnpm -F @proj-anima/stage-ui typecheck` for TS changes. `flutter analyze` has a pre-existing baseline of infos/warnings; only new errors/warnings matter.
- Record non-obvious decisions in Beads evidence and in the parity ledger when a capability lands; do not claim parity without a passing assertion.
