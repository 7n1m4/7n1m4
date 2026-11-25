# Feature-parity checklist

Maps each daemon capability to its implementation status in the **Flutter renderer**
(`apps/flutter`) — the primary and sole active renderer on desktop and mobile — against the
**Vue stage UI** (`apps/stage-web` + `packages/stage-ui`), which is the *behaviour reference*
for the port and not a second active renderer. A blank cell = not implemented. Rows marked
**stub** return a "not implemented" error from the daemon or are explicitly out-of-scope.
Rows marked **TS-core-remaining** have their full business logic in TypeScript with no
daemon port yet — a gap to close, not a reason to reduce the renderer.

Flutter must reach full Vue stage-UI feature parity: the Rust daemon owns all business logic
and state, the client stays thin as no competing state writer, and the renderer feature
surface is never reduced (user clarification 2026-11-25). That includes **native
character/model rendering** (VRM, Live2D, MMD, Spine) inside Flutter — not a control/chat-only
surface and not an external pet process. The Godot renderer was purged from the active
architecture on 2026-11-25 and has no column here.

| Capability | Flutter | Vue reference | Parity gap |
|---|---|---|---|
| `core.status` health probe | implemented | implemented | none |
| `chat.send` / chat sessions | implemented | implemented | none |
| chat streaming deltas | implemented | implemented | none |
| `chat.cancel` / stop-generation | implemented | implemented | none |
| `settings get/set` (general) | implemented (`general` get/set: `settings_screen.dart:70,127`; chat reads `chat` at `chat_composer_controller.dart:94`) | implemented (Vue settings UI) | other daemon settings sections have no Flutter editor |
| providers list | implemented | implemented | none |
| vault status | implemented | implemented | none |
| `stmm.list` / `stmm.rebuild` / `journal.append` / `journal.search` / `retrieval.status` | implemented (Flutter memory screen) | **TS-core-remaining** (TS short/long-term memory stores, not yet daemon RPC) | daemon RPC shipped; Vue store not yet migrated |
| `cards.list` / `cards.get` / `cards.import` / `cards.create` / `cards.update` / `cards.delete` | **implemented** — daemon card CRUD (`gateway.rs:1301-1391`); `cardsMetadataSet` also works | **TS-core-remaining** (card store in TypeScript) | daemon CRUD shipped; Vue store not yet migrated; ownership contract in `docs/decision-card-ownership.md` |
| `sessions.list` / `sessions.export` / `sessions.auto_title` | `sessions.list`/`.export` implemented (Flutter sessions screen); `sessions.auto_title` is a registered daemon RPC stub (`crates/anima-daemon/src/gateway.rs:1543-1548`) and has no client caller | **TS-core-remaining** (chat session store in TS) | daemon RPC shipped for list/export; `sessions.auto_title` is a registered daemon RPC stub (`gateway.rs:1543-1548`) because auto-titling runs inside core after the first assistant reply (`crates/anima-core/src/chat.rs:617-623,649`) — no client implements or needs the verb; Vue store not yet migrated |
| heartbeat keepalive | implemented | **TS-core-remaining** (in-app server heartbeat path) | daemon heartbeat wired; Vue store not yet migrated |
| event subscription lane | implemented (`token.delta` per connection plus `emotion.tag` in chat/stage) | implemented (Vue legacy `possibleEvents`/`onEvent` lane; not identical daemon topic coverage) | none for the event lane; Vue still routes chat/memory/card state through TS stores (**TS-core-remaining**, see below) |
| `emotion.tag` cues | consumed in chat/stage and subscribed (`protocol.dart` `EventTopic.emotionTag`); stage cues route through `StageRenderStateBinding` and `ModelStageRuntime.emotion` to the native backend | **TS-core-remaining** (BeatSync BroadcastChannel; not yet daemon event) | daemon-published; Vue store not yet migrated; Flutter and Vue use different topic lanes |
| dynamic generated widgets | implemented (Flutter GenUI 0.10.4 / A2UI v0.9 surfaces rendered from `token.delta` via `apps/flutter/lib/features/chat/genui_surface_controller.dart`; `genui` dependency pinned; invalid payloads leave plain text visible) | different sandbox widget system (`stage_widgets` + `packages/stage-ui/src/libs/sandbox/*`) | **by design, not a gap**: distinct inline-presentation vs desktop-tool capabilities; see `docs/decision-cross-client-dynamic-widgets.md` (`airi-osn`) |
| `lip_sync.rms` animation | **wired to the native model stage** (Flutter `speech/` Piper/sherpa engines → `AmplitudeTap` → `LipSyncGenerator` frames → `NativeModelSurface` → `ModelStageRuntime.lipSync` → `ModelBackend.setLipSync`); real mouth/morph implementation lives in each native backend, not the daemon | — | **client-local only** — daemon does not publish it (`decision-bridge-scope.md`); generic scale/tint renderer remains as the opt-in fallback in `main.dart` |
| Native model rendering (VRM / Live2D / MMD / Spine) | **foundation landed** (`apps/flutter/lib/features/stage/`: resolver → backend registry → `ModelStageRuntime` → `NativeModelSurface`, with loud typed failures for missing runtimes and no fabricated assets) | implemented (Vue stage renderers) | Real platform renderer binaries/adapters for VRM/Live2D/MMD/Spine and full capability parity remain; `airi-kxku` owns the architecture gates and `airi-8dgb` the renderer phases |
| MCP | daemon RPCs registered (`mcp.list_servers`, `mcp.tools_list`, `mcp.tools_call`/`mcp.call_tool`); no Flutter client caller; no Vue client caller | no client callers | daemon-only verbs; no renderer implements them (`gateway.rs:1552,1583,1620`) |
| ACP | daemon RPCs registered (`acp.run`, `acp.prompt`, `acp.list_agents` stub, `acp.list_sessions`); no Flutter client caller; no Vue client caller | no client callers | `acp.list_agents` is a daemon stub; no renderer implements ACP (`gateway.rs:1675,1765,1843,1851`) |

## Client-local TTS/PCM capability status

Per `docs/decision-client-local-tts-pcm.md` (ratified Option B: on-device Piper-class TTS exposing PCM; Option C: real WAVE decode as fallback/test harness):

- Flutter has `PiperTtsEngine` (local `piper` CLI → WAVE → `WavPcmSource`), an optional `SherpaTtsEngine` adapter requiring a user-supplied `package:sherpa_onnx` + `SherpaLoader` registration (no dependency in `pubspec.yaml`), and `LipSyncGenerator` producing client-stamped `LipSyncRmsData` frames. `main.dart` wires an opt-in `LipSyncController` → `LipSyncRenderer` (scale/tint, no mouth mesh) when `PIPER_MODEL` is set; without a model no engine is constructed and no frames are fabricated. An opt-in test exercises real Piper output when `PIPER_MODEL` is supplied (`PIPER_PATH` is optional); it is otherwise skipped.
- Neither client-side path commits binaries/models; reproducible downloads, env/config names (`PIPER_PATH`, `PIPER_MODEL`, `SherpaTtsConfig` paths), and license verification steps are in [`docs/guide-client-local-tts-runtime.md`](./guide-client-local-tts-runtime.md). Missing assets must fail loudly, not yield fake PCM.
- Parity is client-local: Flutter has an observable text → PCM → RMS → **generic** renderer path with local assets. Do not claim daemon-published `lip_sync.rms`, committed model assets, or a functional mouth mesh.

## Remaining TS business logic (not yet in daemon or the thin client)

- Every Vue stage-UI capability not yet in Flutter is a parity gap, not out-of-scope by default; exceptions are explicitly ratified dev-only surfaces.

- **Auth / OAuth** — `packages/stage-ui/src/stores/auth.ts` (better-auth, Google/GitHub sign-in via `libs/auth.ts`). No daemon equivalent.
- **Character likes / bookmarks** — `packages/stage-ui/src/stores/characters.ts` lines 276–333: like/bookmark state reconciled from daemon `cards.metadata` (no remote API call); remote CRUD remains at lines 138, 171, 198, 236, 261.
- **Chat session sync / multi-device mirror** — `packages/stage-ui/src/stores/chat/session-store.ts` line 139: `syncSessionToRemote()`. No daemon equivalent.
- **Sync-engine manifest fetch** — `packages/stage-ui/src/stores/sync-engine.ts` lines 495–595: remote display-models / VMD / VRMA manifest fetch. No daemon equivalent.
- **Native model rendering** — Flutter now has the client-local resolver/backend/runtime/overlay foundation in `apps/flutter/lib/features/stage/`, but real per-format renderer adapters and capability parity remain outstanding. The Vue stage renderers are the behaviour reference; this remains a parity gap, not a retired capability.
- **Vue/Electrobun server channel store (TS-core-remaining)** — `packages/stage-ui/src/stores/mods/api/channel-server.ts` (`useModsServerChannelStore`); initialised in `apps/stage-tamagotchi/src/renderer/App.vue:483` with ~20 store calls still in TypeScript. The store already opens a daemon WebSocket (`resolveWebSocketUrl` at lines 49–91 derives the gateway URL/token from daemon-mirrored keys; `Client` construction and `onEvent` subscriptions at lines 149–243 and 334–348), so the **event lane itself is implemented** — the remaining TS-core gap is chat/memory/card business logic routed through the store, not event transport. **TS-core-remaining**.

## Opt-in TS remote-sync retirement gate

Evidence rows below are dated re-verifications against
[`plan-ts-remote-sync-retirement.md`](./plan-ts-remote-sync-retirement.md) exit criteria 1–8.
Final removal was executed under explicit dated maintainer approval (2026-11-25) via `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`); these rows are dated gate evidence, not a claim that every criterion was green at approval.
| # | Criterion | Status | Dated evidence |
|---|---|---|---|
| 1 | Daemon logic — providers | **FAIL (at approval)** | 2026-11-24 (`coordinator-wave5`): RPC registrations `crates/anima-daemon/src/gateway.rs:757,767,783`; save/delete/list core logic `crates/anima-daemon/src/core.rs:279-394`; secret stripping `crates/anima-core/src/providers.rs:24-62`; durable `StoredProvider` fields only id/kind/config/enabled/updated_at at `crates/anima-store/src/lib.rs:421-434` — no validation state, owner, soft-delete, or documented local-store migration. |
| 2 | Daemon logic — characters | **FAIL (at approval)** | 2026-11-25: daemon card CRUD shipped (`cards.list`/`.get`/`.import`/`.create`/`.update`/`.delete` at `crates/anima-daemon/src/gateway.rs:1301-1391`); card ownership recorded in `docs/decision-card-ownership.md`; business logic was still in `packages/stage-ui/src/stores/characters.ts` at approval (now repointed to daemon RPC in `73495d98`). |
| 3 | Daemon logic — auth/session | **PASS** | 2026-11-24 (`coordinator-wave5`): decision accepted and ratified (`docs/decision-byos-identity.md:4-6,30-34,38`, bead `airi-79o`); default-off caller state confirmed at `packages/stage-ui/src/libs/auth.ts:8,17-30`, `packages/stage-ui/src/stores/auth.ts:13,24-37`, `packages/stage-ui/src/composables/use-local-first.ts:16,35`, `packages/stage-ui/src/stores/settings/general.ts:33`. Account-UX removal executed under `airi-3cp` (commit `73495d98`: `libs/auth.ts`, `stores/auth.ts`, `LoginDrawer.vue`, login route and remote-sync i18n keys deleted). |
| 4 | Flutter client parity | **FAIL (at approval)** | 2026-11-25: Flutter provider UI calls `providers.list`/`providers.save`/`providers.delete` (`apps/flutter/lib/features/providers/providers_screen.dart:96,170,186,196`), but the Flutter renderer still has no native model stage and no card CRUD client UI yet, so client parity is incomplete. |
| 5 | Vue reference migration | **PASS (2026-11-25)** | 2026-11-25 (`CutoverDocsRefresh`): `rg 'client\.api\.(auth|characters|providers)'` and `rg 'useLocalFirstRequest'` over `packages`/`apps` return no production callers; `packages/stage-ui/src/composables/use-local-first.ts`, `composables/api.ts`, `libs/auth.ts`, `stores/auth.ts`, `components/auth/LoginDrawer.vue` and `apps/stage-web/src/pages/auth/login.vue` are deleted (commit `73495d98`); characters/providers stores repointed to daemon RPC. |
| 6 | Config/cutover readiness | **PASS (2026-11-25)** | 2026-11-25 (`CutoverDocsRefresh`): `rg 'SERVER_URL|VITE_SERVER_URL'` over `packages`/`apps` finds no production readers (only the unrelated `DEV_SERVER_URL` in `apps/stage-tamagotchi/src/main/windows/shared/view.ts`); Hono client `composables/api.ts` deleted; `/api/auth`, `/api/characters`, `/api/providers` route mounts removed from `apps/server/src/app.ts` (commit `2f9718d3`); no deployment doc advertises `VITE_SERVER_URL`. |
| 7 | User-visible docs | **PARTIAL** | 2026-11-25: revised handler counts are current in `docs/design-daemon-gateway.md:175` and `docs/rosetta-stone.md:77` (**36** handler registrations from 36 `m.insert` sites in `crates/anima-daemon/src/gateway.rs:735-1841`). 2026-11-25: the docs now state the Flutter-first target (Flutter is the sole active renderer, Godot purged) in `docs/README.md`, `docs/rosetta-stone.md`, `docs/feature-parity-checklist.md` and the root `README.md`; `docs/decision-server-endpoints.md:47-50` still labels endpoint groups "Cutover in progress — approved 2026-11-25" (that external doc is outside this update's scope); client/server code was removed under `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`); this checklist/plan are updated 2026-11-25 (`CutoverDocsRefresh`). Chinese deployment guide `docs/delivery/AIRI-customer-deployment-guide.zh-CN.md` was deleted in commit 5addaaee; no current deployment doc advertises `VITE_SERVER_URL`. |
| 8 | Explicit approval | **APPROVED 2026-11-25** | 2026-11-25: maintainer replied "approved!" after the NO-GO gate evidence was explained and `airi-gfas` closed (`bd show airi-3cp --include-comments`); `airi-3cp`/`airi-h8du` executed the cutover (commits `d1b56c81`, `73495d98`, `2f9718d3`). |
**Gate outcome (2026-11-25):** the recorded audit was FAIL/NO-GO (criterion 3 PASS, 1/2/4/5/6 FAIL, 7 PARTIAL); the maintainer then explicitly approved the cutover despite that evidence (criteria 1/2/4/7 were factually unmet at approval). The cutover was executed under `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`); criteria 5/6 are now source-verified PASS, while 1/2/4/7 retain their original FAIL/PARTIAL gate evidence and are not retroactively green.
## How to use

When a new daemon capability lands, add a row here and mark whether Flutter implements it.
A PR that adds a daemon capability without updating this checklist is incomplete.

Vue is the behaviour reference, not a parity target: a `—` marks a scope where the reference
is not expected to implement a daemon verb (for example client-local `lip_sync.rms`), not an
open implementation gap. The Flutter column is the only one in scope for parity. A gap entry
names the concrete follow-up bead (for example `airi-b2q` above) so the checklist never
reports green while work is outstanding. The TS remote-sync retirement gate below is about
TypeScript **business logic**, not about reducing the Flutter surface; it is blocked and must
not start without explicit user authorization.

`lip_sync.rms` is deliberately **not** daemon-published: speech capture and playback are
client-local per `docs/decision-bridge-scope.md` (authoritative). `emotion.tag` remains
daemon-published from the LLM token stream, which the same decision leaves daemon-owned.
Flutter generates envelopes locally, feeds a generic renderer (scale/tint) in the opt-in fallback path,
and drives `ModelBackend.setLipSync` on the native model stage; the per-format mouth/morph
implementation inside each native backend remains outstanding.

## Source of truth

The Rust daemon/backend in `crates/anima-daemon/src/core.rs`
(`CoreService`) and `crates/anima-daemon/src/gateway.rs`
(`renderer_handlers`) is the single source of truth. The Flutter client implementation
lives in `apps/flutter/lib/daemon_client/`; the local TTS/PCM seam lives in
`apps/flutter/lib/speech/` and is described by
`docs/decision-client-local-tts-pcm.md` and
`docs/guide-client-local-tts-runtime.md`. The Vue stage UI is the behaviour reference
only.