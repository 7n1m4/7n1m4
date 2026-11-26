<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# Plan: retirement gate for opt-in TS remote sync in stage-web

- **Status:** cutover executed 2026-11-25 under explicit dated maintainer approval via `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`); gate evidence was mixed — criteria 1/2/4/7 were factually unmet at approval (originally proposed 2026-11-22). The endpoint set below is the cutover scope.
- **Design bead:** `airi-3mp`
- **Final-removal beads:** `airi-3cp` (apps/server, packages/server-shared) and `airi-h8du` (Vue/stage-ui/i18n callers) — **APPROVED 2026-11-25, EXECUTED**. Two disjoint workers execute the cutover; this design defines their boundary, not a fresh gate.
- **Authority:** [`decision-server-endpoints.md`](./decision-server-endpoints.md) records these endpoints as the cutover scope; Wave 5 decision C in
  [`design-flutter-godot-pivot.md`](./design-flutter-godot-pivot.md) requires daemon business-logic
  parity **and** Flutter frontend parity **and** explicit approval before the Electrobun/Vue
  **desktop TS shell/business logic** can be retired. The maintainer recorded that approval on
  2026-11-25; this plan applies the gate to the opt-in TS remote-sync mirror only.

**Retirement boundary.** Parity comes first: daemon-owned business logic plus the Flutter window
companion exercising those flows over daemon RPC must be proven before the
opt-in TS remote-sync mirror or the Electrobun TS shell is retired. The Vue **web** UI renderer
(`apps/stage-web`) is a maintained full-parity renderer and the behaviour reference; it is **not**
what this cutover retires, and neither is the Flutter renderer. The maintainer approved the cutover on 2026-11-25 after a NO-GO gate audit (criteria 1/2/4/7 factually unmet at approval); removal was executed under `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`). This plan still defines the boundary: Flutter/Vue renderer scope and gateway trust gates are unchanged.

## Current state (source verified, not an endorsement)

No Rust REST equivalent exists. `anima-daemon` exposes authenticated WebSocket RPC handlers
(`crates/anima-daemon/src/gateway.rs:680-1841`: `renderer_handlers` registers 36 `renderer.*` verbs), not HTTP routes. The TypeScript layer is
**removed** under `airi-3cp`/`airi-h8du` (commits `d1b56c81`, `73495d98`, `2f9718d3`): the `/api/auth`, `/api/characters`, `/api/providers` route mounts are gone from `apps/server/src/app.ts` (only `/health` remains) and the Hono/better-auth clients are deleted from `packages/stage-ui`.

| Removed in cutover | What was removed | Caller evidence |
| --- | --- | --- |
| `GET`/`POST /api/auth/*` | Removed 2026-11-25 (`73495d98`, `2f9718d3`): better-auth client, login route/drawer and remote-sync i18n keys deleted; account UX retired per `decision-byos-identity.md` (Option C). | No production caller remains (`rg 'client\.api\.auth'` empty). |
| `/api/characters` `GET /`, `GET /:id`, `POST /`, `PATCH /:id`, `DELETE /:id` | Removed 2026-11-25 (`73495d98`, `2f9718d3`): characters store repointed to daemon `cards.*` RPC (`gateway.rs:1301-1391`); ownership in `docs/decision-card-ownership.md`. | No production caller remains (`rg 'client\.api\.characters'` empty). |
| `/api/providers` `GET /`, `POST /`, `PATCH /:id`, `DELETE /:id` | Removed 2026-11-25 (`73495d98`, `2f9718d3`): provider-catalog store repointed to daemon `providers.*` RPC. | No production caller remains (`rg 'client\.api\.providers'` empty). |

Gate mechanics (pre-cutover, now removed): `remoteSyncEnabled` defaulted `false` (`stores/settings/general.ts:33`); `fetchSession()`/`isAuthenticated` gated on it (`libs/auth.ts`, `stores/auth.ts`); `useLocalFirstRequest` ran `local()` then `remote()` (`composables/use-local-first.ts`); `SERVER_URL` came from `VITE_SERVER_URL` (`libs/auth.ts` fallback, removed in `airi-3cp`) feeding the Hono client (`composables/api.ts`). All deleted in `73495d98`.

Out of scope for this gate: `/api/chats/sync` (hosted route at `apps/server/src/app.ts` (`/api/chats/sync` mount, now removed) / `routes/chats.ts` (sync handler, removed in `airi-3cp`) although the TS caller `syncSessionToRemote()` is gone — deletion tracked in `airi-94l` / `plan-byos-chat-sync.md:91-95`; no production caller was found), like/bookmark (`airi-1gu`, routes removed but orphaned service methods remain in `apps/server/src/services/characters.ts`), uncalled
`/api/gdrive/*` and `GET /api/providers/:id` (`airi-x41`). Their separate decisions are unaffected.

## Exit criteria — deletion is authorized only when every row is green

Evidence is a dated entry in `docs/feature-parity-checklist.md` plus a comment on `airi-3cp`; an
unverifiable claim is not evidence. All rows are mandatory; none may be waived by silence.

| #   | Criterion and observable test                                                                                                                                                                                                                                                                                                                                                                                                                                                                                             | Verifier (owner / evidence)                                                          |
| --- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------ |
| 1   | **Daemon logic — providers.** Every Vue provider operation has a daemon RPC equivalent with contract tests and a documented migration from the local store: list/create/update/delete semantics match `providers.list`/`.save`/`.delete` (`gateway.rs:736-800`; contract tests `providers_save_partial_update_preserves_unrelated_config_and_enabled`, `providers_save_secret_rotation_contract`, `providers_delete_reports_whether_a_row_was_removed` in `gateway.rs`), including validation state and secrets handling. `cargo test -p anima-daemon` passes.                                                                                                                                                          | Daemon owner; Rust tests and parity-checklist row                                    |
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

## Follow-up sequence (approved cutover)

Owner of `airi-3cp`: Vue reference maintainer; verifiers: daemon and Flutter owners. Criterion 8 (maintainer approval) is recorded 2026-11-25; `airi-h8du` owned the disjoint Vue/stage-ui/i18n slice. Both executed (commits `d1b56c81`, `73495d98`, `2f9718d3`); gate evidence mixed (1/2/4/7 unmet at approval).

1. Link the dated evidence and approvals in `airi-3cp`; `docs/feature-parity-checklist.md` and this plan updated to cutover executed 2026-11-25 (`CutoverDocsRefresh`) after source verification of criteria 5/6.
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

As of 2026-11-25 the opt-in TS remote-sync endpoints, Hono client, and `SERVER_URL` readers are removed from source (commits `d1b56c81`, `73495d98`, `2f9718d3`); `apps/server/src/app.ts` now mounts only `/health`. Groups are retired only where source verification passed (criteria 5/6); criteria 1/2/4/7 retain their unmet approval-time evidence.