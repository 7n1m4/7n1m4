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
| `cards.list` / `cards.get` / `cards.import` | **stub** — daemon returns "not implemented"; Flutter shows unavailable banner (`gateway.rs:951-953`; `cards_screen.dart` line 65) | **stub** — same daemon error; Godot shows error | **TS-core-remaining** (card store in TypeScript) | **out-of-scope** — card management excluded from daemon port; tracked as remaining TS business logic |
| `sessions.list` / `sessions.export` / `sessions.auto_title` | implemented (Flutter sessions screen) | implemented (Godot C# DaemonRpc) | **TS-core-remaining** (chat session store in TS) | daemon RPC shipped; Vue store not yet migrated |
| heartbeat keepalive | implemented | implemented | **TS-core-remaining** (in-app server heartbeat path) | daemon heartbeat wired; Vue store not yet migrated |
| event subscription lane | implemented (Flutter subscribes `token.delta` per connection) | implemented (Godot subscribes via `DaemonEvents`) | **TS-core-remaining** (`useModsServerChannelStore` in `channel-server/index.ts`; no daemon event subscription yet) | **TS-core-remaining** — event lane shipped; Vue store needs migration |
| `emotion.tag` cues | consumed (Flutter `protocol.dart` `EventTopic.emotionTag`) | consumed (Godot `DaemonEvents.cs`) | **TS-core-remaining** (BeatSync BroadcastChannel; not yet daemon event) | daemon-published; Vue store not yet migrated |
| `lip_sync.rms` animation | planned (client-local envelope generation, airi-b2q) | planned (client-local envelope generation, airi-b2q) | — | **client-local only** — not daemon-published per `decision-bridge-scope.md` (airi-b2q) |

## Remaining TS business logic (not yet in daemon or thin clients)

- **Auth / OAuth** — `packages/stage-ui/src/stores/auth.ts` (better-auth, Google/GitHub sign-in via `libs/auth.ts`). No daemon equivalent.
- **Character likes / bookmarks** — `packages/stage-ui/src/stores/characters.ts` lines 220–275: like/bookmark via remote API. No daemon equivalent.
- **Chat session sync / multi-device mirror** — `packages/stage-ui/src/stores/chat/session-store.ts` line 139: `syncSessionToRemote()`. No daemon equivalent.
- **Sync-engine manifest fetch** — `packages/stage-ui/src/stores/sync-engine.ts` lines 495–595: remote display-models / VMD / VRMA manifest fetch. No daemon equivalent.
- **Godot renderers (stub/planned)** — `godot/scripts/Renderers/Live2dRenderer.cs` and `VrmRenderer.cs` extend `GenericPetRenderer` with scale/tint only (no VRM addon / Cubism GDExtension vendored). Marked **stub/planned**; not functional backends.
- **Vue/Electrobun server channel store (TS-core-remaining)** — `packages/stage-ui/src/stores/mods/api/channel-server.ts` (`useModsServerChannelStore`); initialised in `apps/stage-tamagotchi/src/renderer/App.vue:483` with ~20 store calls still in TypeScript. **TS-core-remaining**.

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
