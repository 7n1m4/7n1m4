# Feature-parity checklist

Maps each daemon capability to client implementation status across
 Flutter, Godot, and the Vue reference. A blank cell = not implemented.
 Rows marked **stub** return a "not implemented" error from the daemon or are
 explicitly out-of-scope. Rows marked **TS-core-remaining** have their full
 business logic in TypeScript with no daemon port yet.

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
| `cards.list` / `cards.get` / `cards.import` | **stub** — daemon returns "not implemented"; Flutter shows unavailable banner (`gateway.rs:1054-1075`; `cards_screen.dart` line 65) | **stub** — same daemon error; Godot shows error | **TS-core-remaining** (card store in TypeScript) | **out-of-scope** — card management excluded from daemon port; tracked as remaining TS business logic |
| `sessions.list` / `sessions.export` / `sessions.auto_title` | implemented (Flutter sessions screen) | implemented (Godot C# DaemonRpc) | **TS-core-remaining** (chat session store in TS) | daemon RPC shipped; Vue store not yet migrated |
| heartbeat keepalive | implemented | implemented | **TS-core-remaining** (in-app server heartbeat path) | daemon heartbeat wired; Vue store not yet migrated |
| event subscription lane | implemented (Flutter subscribes `token.delta` per connection) | implemented (Godot subscribes via `DaemonEvents`) | **TS-core-remaining** (`useModsServerChannelStore` in `channel-server/index.ts`; no daemon event subscription yet) | **TS-core-remaining** — event lane shipped; Vue store needs migration |
| `emotion.tag` cues | consumed (Flutter `protocol.dart` `EventTopic.emotionTag`) | consumed (Godot `DaemonEvents.cs`) | **TS-core-remaining** (BeatSync BroadcastChannel; not yet daemon event) | daemon-published; Vue store not yet migrated |
| `lip_sync.rms` animation | planned (client-local envelope generation, airi-b2q) | planned (client-local envelope generation, airi-b2q) | — | **client-local only** — not daemon-published per `decision-bridge-scope.md` (airi-b2q) |

## Remaining TS business logic (not yet in daemon or thin clients)

- **Auth / OAuth** — `packages/stage-ui/src/stores/auth.ts` (better-auth, Google/GitHub sign-in via `libs/auth.ts`). No daemon equivalent.
- **Character likes / bookmarks** — `packages/stage-ui/src/stores/characters.ts` lines 276–333: like/bookmark state reconciled from daemon `cards.metadata` (no remote API call); remote CRUD remains at lines 138, 171, 198, 236, 261.
- **Chat session sync / multi-device mirror** — `packages/stage-ui/src/stores/chat/session-store.ts` line 139: `syncSessionToRemote()`. No daemon equivalent.
- **Sync-engine manifest fetch** — `packages/stage-ui/src/stores/sync-engine.ts` lines 495–595: remote display-models / VMD / VRMA manifest fetch. No daemon equivalent.
- **Godot renderers (stub/planned)** — `godot/scripts/Renderers/Live2dRenderer.cs` and `VrmRenderer.cs` extend `GenericPetRenderer` with scale/tint only (no VRM addon / Cubism GDExtension vendored). Marked **stub/planned**; not functional backends.
- **Vue/Electrobun server channel store (TS-core-remaining)** — `packages/stage-ui/src/stores/mods/api/channel-server.ts` (`useModsServerChannelStore`); initialised in `apps/stage-tamagotchi/src/renderer/App.vue:483` with ~20 store calls still in TypeScript. **TS-core-remaining**.

## Opt-in TS remote-sync retirement gate

Evidence rows below are dated re-verifications against
[`plan-ts-remote-sync-retirement.md`](./plan-ts-remote-sync-retirement.md) exit criteria 1–8.
Final removal remains `airi-3cp`'s scope; this section is evidence, not authorization to delete.

| # | Criterion | Status | Dated evidence |
|---|---|---|---|
| 1 | Daemon logic — providers | **FAIL** | 2026-11-24 (`coordinator-wave5`): RPC registrations `crates/anima-daemon/src/gateway.rs:582,592,604`; save/delete/list core logic `crates/anima-daemon/src/core.rs:281-379`; secret stripping `crates/anima-core/src/providers.rs:24-52`; durable `StoredProvider` fields only id/kind/config/enabled/updated_at at `crates/anima-store/src/lib.rs:398-409` — no validation state, owner, soft-delete, or documented local-store migration. |
| 2 | Daemon logic — characters | **FAIL** | 2026-11-24 (`coordinator-wave5`): `cards.list`/`.get`/`.import` still return "not implemented" at `crates/anima-daemon/src/gateway.rs:1054-1075`; no card CRUD verbs in `renderer_handlers`; `docs/design-flutter-godot-pivot.md:281` declares cards out of daemon scope without defining local-only ownership; business logic remains in `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`. |
| 3 | Daemon logic — auth/session | **PASS** | 2026-11-24 (`coordinator-wave5`): decision accepted and ratified (`docs/decision-byos-identity.md:4-6,30-34,38`, bead `airi-79o`); default-off caller state confirmed at `packages/stage-ui/src/libs/auth.ts:8,17-30`, `packages/stage-ui/src/stores/auth.ts:13,24-37`, `packages/stage-ui/src/composables/use-local-first.ts:16,35`, `packages/stage-ui/src/stores/settings/general.ts:33`. Account-UX removal itself executes later via `airi-3cp`. |
| 4 | Flutter/Godot parity | **FAIL** | 2026-11-24 (`coordinator-wave5`): Flutter provider UI has only `providers.list` (`apps/flutter/lib/features/providers/providers_screen.dart:32`); Godot declares only `ProvidersList` (`godot/scripts/Net/DaemonRpc.cs:21`); both card paths reach daemon stubs (`apps/flutter/lib/daemon_client/daemon_client.dart:617-635`; `godot/scripts/Net/DaemonRpc.cs:30-32`). `docs/decision-client-local-tts-pcm.md:4` is accepted, but client-local TTS is not a gate precondition. |
| 5 | Vue reference migration | **FAIL** | 2026-11-24 (`coordinator-wave5`): production `client.api.characters` callers at `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`; `client.api.providers` at `packages/stage-ui/src/stores/provider-catalog.ts:25,71,112,137`; remote branch at `packages/stage-ui/src/composables/use-local-first.ts:16,35`; better-auth client at `packages/stage-ui/src/libs/auth.ts:17`. |
| 6 | Config/cutover readiness | **FAIL** | 2026-11-24 (`coordinator-wave5`): `SERVER_URL`/`VITE_SERVER_URL` and Hono client readers at `packages/stage-ui/src/composables/api.ts:5,7` and `packages/stage-ui/src/libs/auth.ts:7,18,66`; deployment guide still advertises `VITE_SERVER_URL` at `docs/delivery/AIRI-customer-deployment-guide.zh-CN.md:330,336`. |
| 7 | User-visible docs | **FAIL** | 2026-11-24 (`coordinator-wave5`): stale handler counts remain at `docs/design-daemon-gateway.md:175` and `docs/README.md:69` ("21" vs 33 current `m.insert` registrations in `crates/anima-daemon/src/gateway.rs:635-1482`); the stale handler count is at `docs/README.md:69` ("21" vs the current **33** `m.insert` registrations in `crates/anima-daemon/src/gateway.rs:635-1482`); `docs/rosetta-stone.md:63` already records 33. `docs/README.md:70` and `docs/decision-server-endpoints.md:47-50` still promise the temporary remote-sync mirror rather than its removal. |
| 8 | Explicit approval | **OPEN** | 2026-11-24 (`coordinator-wave5`): criterion requires owner/maintainer sign-off in `airi-3cp` (`docs/plan-ts-remote-sync-retirement.md:54`); no approval comment or approver names were available in the repository source checked, so approval is not evidenced. |

**Gate status: FAIL / NOT PASSED** — only criterion 3 has a passing dated evidence row; criteria 1, 2, 4, 5, 6 and 7 fail, and criterion 8 remains open. The gate is not green and deletion is not authorized by this checklist.

## How to use

When a new daemon capability lands, add a row here and mark which clients
implement it. A PR that adds a daemon capability without updating this
checklist is incomplete.

The Vue column is a **behaviour reference**, not a parity target: `—` there
is documented reference scope, not an open implementation gap. A gap entry
names the concrete follow-up bead (for example `airi-b2q` above) so the
checklist never reports green while work is outstanding.

`lip_sync.rms` is deliberately **not** daemon-published: speech capture and
playback are client-local per `docs/decision-bridge-scope.md` (authoritative).
`emotion.tag` remains daemon-published from the LLM token stream, which the
same decision leaves daemon-owned. Do not mark `lip_sync.rms` implemented
until Flutter and Godot generate envelopes locally (tracked by `airi-b2q`).

## Source of truth

Daemon capabilities live in `crates/anima-daemon/src/core.rs`
(`CoreService`) and `crates/anima-daemon/src/gateway.rs`
(`renderer_handlers`). Client implementations live in
`apps/flutter/lib/daemon_client/`, `godot/scripts/Net/`, and the Vue
reference app.
