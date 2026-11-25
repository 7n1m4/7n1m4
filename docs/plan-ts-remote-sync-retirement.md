<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Plan: retirement gate for opt-in TS remote sync in stage-web

- **Status:** proposed gate, not authorization to delete (2026-11-22)
- **Design bead:** `airi-3mp`
- **Final-removal bead:** `airi-3cp` — **DO NOT START**; it depends on this design and stays blocked
  until every exit criterion below is green and approval is recorded.
- **Authority:** [`decision-server-endpoints.md`](./decision-server-endpoints.md) keeps these
  endpoints temporarily; Wave 5 decision C in
  [`design-flutter-godot-pivot.md`](./design-flutter-godot-pivot.md) requires daemon business-logic
  parity **and** Flutter frontend parity **and** explicit approval before the Electrobun/Vue
  **desktop TS shell/business logic** can be retired. This plan applies that gate to the opt-in TS
  remote-sync mirror only.

**Retirement boundary.** Parity comes first: daemon-owned business logic plus the Flutter window
companion exercising those flows over daemon RPC must be proven before the
opt-in TS remote-sync mirror or the Electrobun TS shell is retired. The Vue **web** UI renderer
(`apps/stage-web`) is a maintained full-parity renderer and the behaviour reference; it is **not**
what this gate retires, and neither is the Flutter renderer. `airi-3cp` remains
**DO NOT START** until the exit criteria below are green, and no deletion is authorized here.

## Current state (source verified, not an endorsement)

No Rust REST equivalent exists. `anima-daemon` exposes authenticated WebSocket RPC handlers
(`crates/anima-daemon/src/gateway.rs:680-1890`: `renderer_handlers` registers 36 `renderer.*` verbs), not HTTP routes. The TypeScript layer is
**not gone**: `apps/server` still mounts the routes and `packages/stage-ui` still contains the Hono
client, better-auth client, and remote branches.

| Kept temporarily                                                             | Why it is still here                                                                                                                                                                                                                                                            | Live caller evidence                                                                                                                                                   |
| ---------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `GET`/`POST /api/auth/*`                                                     | Optional account/session path for the Vue web and Electrobun references. Sign-in is user-initiated and may precede a session, so "opt-in" means default-off storage plus explicit navigation, not an authenticated-only gate.                                                   | `packages/stage-ui/src/libs/auth.ts:7-20,22-48,62-93`; `apps/stage-web/src/pages/auth/login.vue:2-5,24,35,87`; `packages/stage-ui/src/components/auth/LoginDrawer.vue` |
| `/api/characters` `GET /`, `GET /:id`, `POST /`, `PATCH /:id`, `DELETE /:id` | Local-first compatibility mirror for the Vue reference; remote runs only after the local write and only when the auth store is authenticated. Daemon `cards.list`/`.get`/`.import`/`.create`/`.update`/`.delete` are implemented (`gateway.rs:1301-1391`). This is not a hosted card registry. | `packages/stage-ui/src/stores/characters.ts:79-215`; callers in `apps/stage-web/src/pages/settings/characters/` and `packages/stage-pages/src/pages/v2/index.vue`      |
| `/api/providers` `GET /`, `POST /`, `PATCH /:id`, `DELETE /:id`              | Same default-off, local-first mirror. The daemon already has `providers.list`/`.save`/`.delete` RPC handlers (`gateway.rs:736-780`), so these routes must not become a second authoritative writer.                                                                             | `packages/stage-ui/src/stores/provider-catalog.ts:16-145`; callers in `packages/stage-pages/src/pages/v2/settings/providers/`                                          |

Gate mechanics: `remoteSyncEnabled` is stored at `settings/privacy/remote-sync-enabled` with default
`false` (`packages/stage-ui/src/stores/settings/general.ts:33`); the settings checkbox is in
`packages/stage-pages/src/components/settings-general-fields.vue:65` and
`packages/stage-pages/src/pages/settings/system/general.vue:60`. `fetchSession()` returns early
unless that key is true (`libs/auth.ts:10-26`), and `isAuthenticated` additionally requires both
user and session (`stores/auth.ts:13,24-38`). `useLocalFirstRequest` runs `local()` first, then
`remote()` only when allowed or authenticated (`packages/stage-ui/src/composables/use-local-first.ts:6-40`).
`SERVER_URL` comes from `VITE_SERVER_URL` or `http://localhost:3000` (`libs/auth.ts:7`) and is the
base for the Hono client (`packages/stage-ui/src/composables/api.ts:1-16`).

Out of scope for this gate: `/api/chats/sync` (hosted route still mounted at `apps/server/src/app.ts:108` / `routes/chats.ts:15` although the TS caller `syncSessionToRemote()` is gone — deletion tracked in `airi-94l` / `plan-byos-chat-sync.md:91-95`; no production caller was found), like/bookmark (`airi-1gu`, routes removed but orphaned service methods remain in `apps/server/src/services/characters.ts`), uncalled
`/api/gdrive/*` and `GET /api/providers/:id` (`airi-x41`). Their separate decisions are unaffected.

## Exit criteria — deletion is authorized only when every row is green

Evidence is a dated entry in `docs/feature-parity-checklist.md` plus a comment on `airi-3cp`; an
unverifiable claim is not evidence. All rows are mandatory; none may be waived by silence.

| #   | Criterion and observable test                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Verifier (owner / evidence)                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 1   | **Daemon logic — providers.** Every Vue provider operation has a daemon RPC equivalent with contract tests and a documented migration from the local store: list/create/update/delete semantics match `providers.list`/`.save`/`.delete` (`gateway.rs:736-780`; contract tests `providers_save_partial_update_preserves_unrelated_config_and_enabled`, `providers_save_secret_rotation_contract`, `providers_delete_reports_whether_a_row_was_removed` in `gateway.rs`), including validation state and secrets handling. `cargo test -p anima-daemon` passes.                                                                                                                                                          | Daemon owner; Rust tests and parity-checklist row                                    |
| 2   | **Daemon logic — characters.** Character CRUD is daemon-owned, not a TS stub: either `cards.list`/`get`/`import` and create/update/delete are implemented with conformance tests, or an explicit ADR supersedes that scope and defines the local-only ownership. Daemon card CRUD is implemented (`gateway.rs:1301-1391`). Business logic no longer lives exclusively in `stores/characters.ts`.                                                                                          | Daemon owner; ADR/contract tests and parity-checklist row                            |
| 3   | **Daemon logic — auth/session.** The reference no longer depends on better-auth for a functional path: the daemon supplies the identity/trust contract needed by remote clients, **or** the account/session UX is deliberately removed from the reference with a written BYOS identity decision. No user flow is silently broken when `/api/auth/*` disappears. **This criterion is currently blocked**: `airi-79o` (open) owns the BYOS identity/auth decision and must not be resolved by this gate.                                                                                                                                                           | Daemon owner + Vue reference owner; design decision plus request-level test evidence |
| 4   | **Flutter parity.** The Flutter app exercises the end-to-end flows for providers and characters (and the decision from #3) over daemon RPC. `flutter test` passes, and the parity checklist marks these rows implemented, not stub/TS-core-remaining. The Vue web renderer stays a maintained full-parity behaviour reference throughout; this row does not authorize retiring it.                                                                                                              | Flutter owner; `flutter test`, checklist                |
| 5   | **Vue reference migration.** No production caller remains for `client.api.auth`, `client.api.characters`, or `client.api.providers`, nor for remote branches in `useLocalFirstRequest`. Login route/drawer, remote-sync checkbox and locale strings are removed or re-pointed to the replacement. Run a repo-wide inventory command for the remote-auth, Hono-client, and remote-sync symbols; it must return no production callers outside tests and the references documented in this plan. Focused Vitest suites pass. | Vue reference owner; `rg` output, Vitest output, checklist                           |
| 6   | **Config/cutover readiness.** `SERVER_URL`/`VITE_SERVER_URL`, the Hono client, and `@proj-anima/server` type imports have zero remaining production readers; the final-removal change can delete the route mounts and server code without breaking another caller. Deployment docs that advertise `VITE_SERVER_URL` are listed for update; corrected on 2026-11-25 (`airi-gv0b`) to describe the variable as opt-in mirror config only.                                                                                                                                                                                | Vue reference owner + server maintainer; repo-wide `rg` inventory                    |
| 7   | **User-visible docs.** `docs/README.md`, `docs/feature-parity-checklist.md`, `docs/decision-server-endpoints.md` and any deployment guide that documents the remote endpoint or its toggle say what replaces it and that the TS routes are gone. Doc links resolve; no "remote sync" promise remains without a replacement.                                                                                                                                                                                               | Docs owner; doc diff and link check                                                  |
| 8   | **Explicit approval.** Daemon, Flutter and Vue reference owners plus the maintainer sign off on the dated evidence for criteria 1–7 in `airi-3cp`. This implements Wave 5 decision C's "explicit approval" requirement; passing tests alone do not grant it.                                                                                                                                                                                                                                                              | Maintainer; bead comment with approver names and evidence links                      |

## Explicitly NOT preconditions

- A Rust **REST** replacement. RPC parity and reference migration are enough; do not build `axum`
  routes just to retire Hono routes.
- Retiring `apps/server` wholesale, the Electron/Electrobun shell, or the Vue web app. The Vue web
  renderer is kept out of respect for the original project and as a maintained full-parity
  behaviour reference; only the opt-in TS mirror is removed here. Retirement of the Electrobun
  desktop TS shell/business logic is the separate parity-gated decision C (`airi-wxp.6.4`), not a
  Vue renderer retirement; `apps/stage-tamagotchi` stays alive until decision C is met.
- Likes/bookmarks (`airi-1gu`), BYOS chat sync (`airi-94l`), gdrive/provider-detail cleanup
  (`airi-x41`), client-local lip-sync (`airi-b2q`), or mobile packaging.
  Those are separate scopes; their beads need not close for this gate.
- Turning the daemon into a hosted identity provider or cloud-community backend, or preserving a
  hosted database solely because these routes exist.
- Deleting local-first behaviour. Local writes stay; only remote mirroring and its config disappear.

## Follow-up sequence when the gate passes

Owner of `airi-3cp`: Vue reference maintainer; verifiers: daemon and Flutter owners. Start only
after criterion 8 is recorded.

1. Link the dated evidence and approvals in `airi-3cp`; update
   `docs/feature-parity-checklist.md` and this plan's status to "gate passed".
2. Repoint Vue character/provider/auth callers to the daemon RPC/local path, keeping the Vue web
   renderer intact; update focused tests.
   Remove `useLocalFirstRequest` remote branches, `composables/api.ts` (`hc<AppType>`),
   `SERVER_URL`/`VITE_SERVER_URL` reads, `libs/auth.ts` better-auth client, login drawer/page and
   the remote-sync setting plus its i18n strings. Delete the helper if no caller remains.
3. Unmount and delete the `/api/auth/*`, `/api/characters` CRUD and `/api/providers`
   list/create/patch/delete routes in `apps/server`, with their now-unused middleware/DI/tests.
   Do not touch the separately-owned like/bookmark, chats/sync, gdrive, or provider-detail work.
4. Apply criterion 7 doc updates; mark `docs/decision-server-endpoints.md` superseded for these
   groups and remove stale `VITE_SERVER_URL` deployment instructions.
5. Run the verification from criteria 1, 4 and 5 once on the integrated result; confirm the `rg`
   inventory is empty of production callers. Close `airi-3cp` with the commands and results.

Until those steps land, the endpoints, Hono client, and `SERVER_URL` remain in place.
