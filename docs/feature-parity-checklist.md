# Feature-parity checklist

Maps each daemon capability to implementation status across all three
maintained full-parity renderers/clients driven by the same Rust backend:
Flutter (`apps/flutter`), Godot (`godot/`), and the Vue web UI (`apps/stage-web`).
A blank cell = not implemented. Rows marked **stub** return a "not implemented"
error from the daemon or are explicitly out-of-scope. Rows marked
**TS-core-remaining** have their full business logic in TypeScript with no
daemon port yet — a gap to close, not a reason to retire the Vue renderer.
The Vue **column** is also the behaviour reference for the port. Retiring
TypeScript business logic (the gated `airi-3cp` remote-sync slice) does not
change renderer parity; gateway trust gates and `airi-3cp` DO NOT START remain
in force unless the user explicitly says otherwise.

| Capability | Flutter | Godot | Vue reference | Parity gap |
|---|---|---|---|---|
| `core.status` health probe | implemented | implemented | implemented | none |
| `chat.send` / chat sessions | implemented | implemented | implemented | none |
| chat streaming deltas | implemented | implemented | implemented | none |
| `chat.cancel` / stop-generation | implemented | implemented | implemented | none |
| settings get/set | implemented | implemented | implemented | none |
| providers list | implemented | implemented | implemented | none |
| vault status | implemented | implemented | implemented | none |
| `stmm.list` / `stmm.rebuild` / `journal.append` / `journal.search` / `retrieval.status` | implemented (Flutter memory screen) | implemented (Godot C# DaemonRpc) | **TS-core-remaining** (TS short/long-term memory stores, not yet daemon RPC) | daemon RPC shipped; Vue store not yet migrated |
| `cards.list` / `cards.get` / `cards.import` | **stub** — daemon returns "not implemented"; `cardsMetadataSet` works but is not card CRUD (`gateway.rs:1184-1202`; `cards_screen.dart:65-87`) | **stub** — same daemon error; `cards.metadata`/`.set` work but are not card CRUD (`godot/scripts/Net/DaemonRpc.cs:31-35`) | **TS-core-remaining** (card store in TypeScript) | **out-of-scope** — card management excluded from daemon port; tracked as remaining TS business logic |
| `sessions.list` / `sessions.export` / `sessions.auto_title` | implemented (Flutter sessions screen) | implemented (Godot C# DaemonRpc) | **TS-core-remaining** (chat session store in TS) | daemon RPC shipped; Vue store not yet migrated |
| heartbeat keepalive | implemented | implemented | **TS-core-remaining** (in-app server heartbeat path) | daemon heartbeat wired; Vue store not yet migrated |
| event subscription lane | implemented (Flutter subscribes `token.delta` per connection) | implemented (Godot subscribes via `DaemonEvents`) | implemented (Vue `useModsServerChannelStore` resolves the daemon gateway URL/token via mirrored localStorage keys and opens a `Client` with `onEvent` subscriptions; `channel-server.ts:49-91,149-243,334-348`) | none for the event lane; Vue still routes chat/memory/card state through TS stores (**TS-core-remaining**, see below) |
| `emotion.tag` cues | consumed (Flutter `protocol.dart` `EventTopic.emotionTag`) | consumed (Godot `DaemonEvents.cs`) | **TS-core-remaining** (BeatSync BroadcastChannel; not yet daemon event) | daemon-published; Vue store not yet migrated |
| dynamic generated widgets | implemented (Flutter GenUI 0.10.4 / A2UI v0.9 surfaces rendered from `token.delta` via `apps/flutter/lib/features/chat/genui_surface_controller.dart`; `genui` dependency pinned; invalid payloads leave plain text visible) | — | different sandbox widget system (`stage_widgets` + `packages/stage-ui/src/libs/sandbox/*`), not A2UI | **by design, not a gap**: distinct inline-presentation vs desktop-tool capabilities; see `docs/decision-cross-client-dynamic-widgets.md` (`airi-osn`) |
| `lip_sync.rms` animation | **wired, generic renderer only** (Flutter `speech/` Piper/sherpa engines → `AmplitudeTap` → `LipSyncGenerator` frames → `main.dart` opt-in `LipSyncRenderer` scale/tint sink; no mouth mesh) | **wired, generic renderer only** (Godot `Main.cs` → `LocalSpeechPipeline` → tap → `GenericPetRenderer.SetLipSync` → node scale/tint/animation key + PCM playback; VRM/Live2D backends are **stub/planned** placeholders, not functional mouth backends) | — | **client-local only** — daemon does not publish it (`decision-bridge-scope.md`); see decision/guide below for setup and limits. Generic scale/tint renderers exist on both clients; real mouth backends remain outstanding. |

## Client-local TTS/PCM capability status

Per `docs/decision-client-local-tts-pcm.md` (ratified Option B: on-device Piper-class TTS exposing PCM; Option C: real WAVE decode as fallback/test harness):

- Flutter has `PiperTtsEngine` (local `piper` CLI → WAVE → `WavPcmSource`), an optional `SherpaTtsEngine` adapter requiring a user-supplied `package:sherpa_onnx` + `SherpaLoader` registration (no dependency in `pubspec.yaml`), and `LipSyncGenerator` producing client-stamped `LipSyncRmsData` frames. `main.dart` wires an opt-in `LipSyncController` → `LipSyncRenderer` (scale/tint, no mouth mesh) when `PIPER_MODEL` is set; without a model no engine is constructed and no frames are fabricated. An opt-in test exercises real Piper output when `PIPER_MODEL` is supplied (`PIPER_PATH` is optional); it is otherwise skipped.
- Godot has `PiperTtsEngine` (local `piper` CLI → WAVE → `WavPcmReader`), `AmplitudeTap`, `PcmLipSyncDriver`, and the pure-managed `LocalSpeechPipeline` (`SpeakAsync` forwards tap levels into `IPetRenderer.SetLipSync` → `LipSyncSmoother` → generic node scale/tint/animation key). `Main.cs` enables this when `PIPER_MODEL` is set, speaks completed assistant turns from local token text, and plays the same PCM through `AudioStreamPlayer`. The shipped VRM/Live2D backends extend `GenericPetRenderer` with no vendored addons (stub/planned, below).
- Neither client commits binaries/models; reproducible downloads, env/config names (`PIPER_PATH`, `PIPER_MODEL`, `SherpaTtsConfig` paths), and license verification steps are in [`docs/guide-client-local-tts-runtime.md`](./guide-client-local-tts-runtime.md). Missing assets must fail loudly, not yield fake PCM.
- Parity is client-local: both clients now have an observable text → PCM → RMS → **generic** renderer path with local assets (Flutter generic scale/tint sink, Godot `GenericPetRenderer`). Do not claim daemon-published `lip_sync.rms`, committed model assets, or functional mouth meshes on either client.

## Remaining TS business logic (not yet in daemon or thin clients)

- **Auth / OAuth** — `packages/stage-ui/src/stores/auth.ts` (better-auth, Google/GitHub sign-in via `libs/auth.ts`). No daemon equivalent.
- **Character likes / bookmarks** — `packages/stage-ui/src/stores/characters.ts` lines 276–333: like/bookmark state reconciled from daemon `cards.metadata` (no remote API call); remote CRUD remains at lines 138, 171, 198, 236, 261.
- **Chat session sync / multi-device mirror** — `packages/stage-ui/src/stores/chat/session-store.ts` line 139: `syncSessionToRemote()`. No daemon equivalent.
- **Sync-engine manifest fetch** — `packages/stage-ui/src/stores/sync-engine.ts` lines 495–595: remote display-models / VMD / VRMA manifest fetch. No daemon equivalent.
- **Godot renderers (stub/planned)** — `godot/scripts/Renderers/Live2dRenderer.cs` and `VrmRenderer.cs` extend `GenericPetRenderer` with scale/tint only (no VRM addon / Cubism GDExtension vendored). Marked **stub/planned**; not functional backends. The generic renderer's `SetLipSync` is observable via node scale/tint/animation key, but it is not a real mouth mesh.
- **Vue/Electrobun server channel store (TS-core-remaining)** — `packages/stage-ui/src/stores/mods/api/channel-server.ts` (`useModsServerChannelStore`); initialised in `apps/stage-tamagotchi/src/renderer/App.vue:483` with ~20 store calls still in TypeScript. The store already opens a daemon WebSocket (`resolveWebSocketUrl` at lines 49–91 derives the gateway URL/token from daemon-mirrored keys; `Client` construction and `onEvent` subscriptions at lines 149–243 and 334–348), so the **event lane itself is implemented** — the remaining TS-core gap is chat/memory/card business logic routed through the store, not event transport. **TS-core-remaining**.

## Opt-in TS remote-sync retirement gate

Evidence rows below are dated re-verifications against
[`plan-ts-remote-sync-retirement.md`](./plan-ts-remote-sync-retirement.md) exit criteria 1–8.
Final removal remains `airi-3cp`'s scope; this section is evidence, not authorization to delete.

| # | Criterion | Status | Dated evidence |
|---|---|---|---|
| 1 | Daemon logic — providers | **FAIL** | 2026-11-24 (`coordinator-wave5`): RPC registrations `crates/anima-daemon/src/gateway.rs:739,749,766`; save/delete/list core logic `crates/anima-daemon/src/core.rs:281-379`; secret stripping `crates/anima-core/src/providers.rs:24-52`; durable `StoredProvider` fields only id/kind/config/enabled/updated_at at `crates/anima-store/src/lib.rs:398-409` — no validation state, owner, soft-delete, or documented local-store migration. |
| 2 | Daemon logic — characters | **FAIL** | 2026-11-24 (`coordinator-wave5`): `cards.list`/`.get`/`.import` still return "not implemented" at `crates/anima-daemon/src/gateway.rs:1184-1202`; no card CRUD verbs in `renderer_handlers`; `docs/design-flutter-godot-pivot.md:281` declares cards out of daemon scope without defining local-only ownership; business logic remains in `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`. |
| 3 | Daemon logic — auth/session | **PASS** | 2026-11-24 (`coordinator-wave5`): decision accepted and ratified (`docs/decision-byos-identity.md:4-6,30-34,38`, bead `airi-79o`); default-off caller state confirmed at `packages/stage-ui/src/libs/auth.ts:8,17-30`, `packages/stage-ui/src/stores/auth.ts:13,24-37`, `packages/stage-ui/src/composables/use-local-first.ts:16,35`, `packages/stage-ui/src/stores/settings/general.ts:33`. Account-UX removal itself executes later via `airi-3cp`. |
| 4 | Flutter/Godot parity | **FAIL** | 2026-11-25 (`airi-4r5`): Flutter provider UI now calls `providers.list`/`providers.save`/`providers.delete` (`apps/flutter/lib/features/providers/providers_screen.dart:88,148,172,181`); Godot still declares only `ProvidersList` for providers (`godot/scripts/Net/DaemonRpc.cs:22`), and both card paths still reach the daemon stubs (`apps/flutter/lib/daemon_client/daemon_client.dart:616-635`; `godot/scripts/Net/DaemonRpc.cs:31-33`); `cards.metadata`/`.set` are implemented but do not supply card CRUD. `docs/decision-client-local-tts-pcm.md:4` is accepted, but client-local TTS is not a gate precondition. |
| 5 | Vue reference migration | **FAIL** | 2026-11-24 (`coordinator-wave5`): production `client.api.characters` callers at `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`; `client.api.providers` at `packages/stage-ui/src/stores/provider-catalog.ts:25,71,112,137`; remote branch at `packages/stage-ui/src/composables/use-local-first.ts:16,35`; better-auth client at `packages/stage-ui/src/libs/auth.ts:17`. |
| 6 | Config/cutover readiness | **FAIL** | 2026-11-24 (`coordinator-wave5`): `SERVER_URL`/`VITE_SERVER_URL` and Hono client readers at `packages/stage-ui/src/composables/api.ts:5,7` and `packages/stage-ui/src/libs/auth.ts:7,18,66`; deployment guide advertised `VITE_SERVER_URL` as a required build variable at `docs/delivery/AIRI-customer-deployment-guide.zh-CN.md:330,336`; corrected 2026-11-25 (`airi-gv0b`) — §7.2 now states the frontend build needs no `VITE_*` variable, that `VITE_SERVER_URL` only feeds the default-off TS mirror slated for deletion under `airi-3cp`, and that the daemon connection resolves the gateway URL from daemon-mirrored localStorage keys. This row stays **FAIL**: production `SERVER_URL` readers remain. |
| 7 | User-visible docs | **PARTIAL** | 2026-11-25 (`airi-4r5`): revised handler counts are already current in `docs/design-daemon-gateway.md:175` and `docs/rosetta-stone.md:63` (**33** `m.insert` registrations in `crates/anima-daemon/src/gateway.rs:717-1657`); the duplicated/self-contradictory "21" claim in this checklist's prior row 7 is removed. `docs/README.md:69-70` describes renderer parity and the daemon OS seam without promising a remote-sync mirror; `docs/decision-server-endpoints.md:47-50` still labels endpoint groups "Stay as opt-in remote sync — temporary" pending `airi-3cp`. 2026-11-25 (`airi-gv0b`): the card-stub citations in this checklist and in `docs/plan-ts-remote-sync-retirement.md` were corrected to `crates/anima-daemon/src/gateway.rs:1184-1202`, the `renderer_handlers` range to `gateway.rs:662-1711`, the provider handler range to `gateway.rs:736-780` (registrations at `739,749,766`), and the `m.insert` range to `gateway.rs:717-1657`; the handler total stays **33**. This row stays **PARTIAL**: `docs/decision-server-endpoints.md` still carries the temporary-mirror wording and is owned by another change. Remaining doc work is tracking the temporary mirror, not a stale handler count. |
| 8 | Explicit approval | **OPEN** | 2026-11-24 (`coordinator-wave5`): criterion requires owner/maintainer sign-off in `airi-3cp` (`docs/plan-ts-remote-sync-retirement.md`, exit-criteria row 8); no approval comment or approver names were available in the repository source checked, so approval is not evidenced. |

**Gate status: FAIL / NOT PASSED** — only criterion 3 has a passing dated evidence row; criteria 1, 2, 4, 5 and 6 fail, criterion 7 is partial, and criterion 8 remains open. The gate is not green and deletion is not authorized by this checklist. **`airi-3cp` remains NO-GO / DO NOT START.**

## How to use

When a new daemon capability lands, add a row here and mark which clients
implement it. A PR that adds a daemon capability without updating this
checklist is incomplete.

Vue is a maintained full-parity renderer and the behaviour reference: a `—`
marks a scope where the Vue renderer is not expected to implement a daemon
verb (for example client-local `lip_sync.rms`), not an open implementation gap.
The Flutter/Godot columns are equally in scope for parity. A gap entry names
the concrete follow-up bead (for example `airi-b2q` above) so the checklist
never reports green while work is outstanding. The TS remote-sync retirement
gate below is about TypeScript **business logic**, not Vue renderer removal;
it is blocked and must not start without explicit user authorization.

`lip_sync.rms` is deliberately **not** daemon-published: speech capture and
playback are client-local per `docs/decision-bridge-scope.md` (authoritative).
`emotion.tag` remains daemon-published from the LLM token stream, which the
same decision leaves daemon-owned. Both clients generate envelopes locally and
feed generic renderers (scale/tint); functional VRM/Live2D or mouth-mesh
backends remain outstanding on both sides.

## Source of truth

The Rust daemon/backend in `crates/anima-daemon/src/core.rs`
(`CoreService`) and `crates/anima-daemon/src/gateway.rs`
(`renderer_handlers`) is the single source of truth. Client implementations
live in all three maintained renderers — `apps/flutter/lib/daemon_client/`,
`godot/scripts/Net/`, and the Vue web UI (`apps/stage-web` with shared
`packages/stage-ui`) — the local TTS/PCM seams live in `apps/flutter/lib/speech/`
and `godot/scripts/Audio/` and are described by
`docs/decision-client-local-tts-pcm.md` and
`docs/guide-client-local-tts-runtime.md`.
