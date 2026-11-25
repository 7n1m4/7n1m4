<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: BYOS identity/auth contract for the daemon world

- **Status:** accepted (2026-11-24, user-ratified; bead `airi-79o`)
- **Bead:** `airi-79o` (blocks `airi-a02` criterion 3 and `airi-3cp`)
- **Scope:** how identity, OAuth and remote-client trust map to the daemon/BYOS world, including CSRF/session-middleware removal and the Vue login route. No code deletion before ratification; this doc is the written decision the retirement gate requires. (Ratified 2026-11-24; removals are executing under maintainer-approved `airi-3cp`/`airi-h8du` as of 2026-11-25.)

## Context (source-verified)

The architecture is "one core, many surfaces": a Rust daemon owns state; Flutter is the thin WS client/renderer on desktop and mobile (the Vue app is the behaviour reference, and Godot is retired) (`docs/decision-server-endpoints.md:11-13`). The fork is **local-first, zero-account, BYOS** (`docs/decision-server-endpoints.md:11`): the realistic deployment is one owner/local user and their own devices; hosted multi-user community features are not an architecture requirement.

Today's split:

- **TS reference (`apps/server`)** still implements full better-auth/OAuth/session machinery: `apps/server/src/libs/auth.ts:23-80` (drizzle adapter, email+password, Google/GitHub social, bearer plugin), session middleware + auth guard (`apps/server/src/middlewares/auth.ts:14-39`), CSRF belt (`apps/server/src/middlewares/require-origin.ts:15-27` with trusted-origin allowlist `apps/server/src/utils/origin.ts:16-26`), mounted at `apps/server/src/app.ts:63,93`. Vue callers: `packages/stage-ui/src/libs/auth.ts:17-20` (better-auth client), `stores/auth.ts:13` (`isAuthenticated = !!user && !!session`), `LoginDrawer.vue`, `apps/stage-web/src/pages/auth/login.vue`. All default-off behind `settings/privacy/remote-sync-enabled` (`libs/auth.ts:10-15`).
- **Rust daemon** has no user/account tables and no auth-session table (`anima-store/src/lib.rs:86-186` — its `sessions` table at :98 is chat sessions) and no identity RPC. Its entire trust model is a single random `authToken` (122-bit UUID) in `server-channel/config.json`, checked by the mandatory first-message WS handshake (`anima-channel/src/session.rs:19,79`), wss-only beyond loopback, D-Bus control plane session-bus-trusted (`docs/design-daemon-gateway.md:53-91`). Every thin client — Flutter (`daemon_client.dart`) and the Electrobun/Vue reference app — authenticates with that one shared token. There is no per-user, per-device, or OAuth identity anywhere in Rust.

This doc is the written BYOS identity decision that `docs/plan-ts-remote-sync-retirement.md:49` criterion 3 requires (or deliberate account-UX removal with a written decision); ratified 2026-11-24.

## Options considered

| Option | Shape | Verdict |
|---|---|---|
| A. Port identity to the daemon | Users/accounts/OAuth/session tables + RPC in Rust | Rejected: contradicts zero-account BYOS; the daemon has no identity hardware or use-case need, hosted custody is out of scope (`decision-server-endpoints.md:11,47`), and it duplicates better-auth for a single-owner deployment. |
| B. Keep better-auth forever | TS server stays the identity provider; daemon clients stay token-only | Rejected: two trust models, one of them (hosted Postgres+custody) the architecture explicitly excludes; the retirement gate would never pass. |
| C. Deliberate removal of account UX (chosen) | Daemon keeps its single-device `authToken` trust; `/api/auth/*`, OAuth, session/CSRF middleware and the Vue login surfaces are retired with the TS remote-sync mirror; multi-device BYOS sync authenticates per-user at the *storage* target (S3/R2/GDrive credentials), never at the daemon. | Matches the ratified architecture: one owner, zero accounts, user-owned storage. Identity is "the user owns the daemon host + holds the token file", exactly as `design-daemon-gateway.md:55-84` already documents. |

## Decision


1. **Identity is device-and-token based, not account based.** The daemon's `authToken` handshake is the whole identity contract. No user/account/session concept is added to Rust. "Who is authenticated" = "holds the 0600 config's token"; same-uid session-bus trust is already recorded as deliberate (`design-daemon-gateway.md:76-84`).
2. **OAuth/account UX is removed, not migrated.** As the maintainer-approved `airi-3cp`/`airi-h8du` cutover runs (2026-11-25, in progress): `/api/auth/*` routes, better-auth server client, `sessionMiddleware`/`authGuard`, `requireSameOrigin` CSRF belt + `getTrustedOrigin` allowlist, the Vue `login.vue` route, `LoginDrawer.vue`, `stores/auth.ts`, `libs/auth.ts` (stage-ui), the `remoteSyncEnabled` setting + its i18n strings, and `SERVER_URL`/`VITE_SERVER_URL` reads are all deleted. Nothing user-visible breaks: remote sync is default-off (`decision-server-endpoints.md:33-39` confirms local-first is the production path, and no client but stage-web ever calls these routes).
3. **Remote-client trust for BYOS sync stays out of the daemon.** Multi-device sync authenticates against the user's own storage target (Google/Dropbox/S3 OAuth happens client-side at the storage API, as `project-byos-cloud-sync.md:226-240` already designs for GDrive AppData) or over an explicitly paired daemon gateway (`decision-server-endpoints.md:58`). The daemon never sees an account.
   - **Deployment shape (2026-11-24, amended 2026-11-25):** the canonical deployment is the daemon on the user's always-on desktop/VPS, with thin clients connecting remotely — the Flutter app on desktop and mobile, plus the Vue web UI as the behaviour reference. The daemon's existing trust model covers this only partially: `authToken` is a single shared secret (no per-client identity, no revocation, no rate limiting) and non-loopback binding already forces wss (`design-daemon-gateway.md:50-51,72-73`). Remote internet exposure is therefore **out of scope for this decision**; the remote-client trust story (per-client tokens / pairing / revocation) is a separate design that must land before internet exposure. LAN/VPN/tailnet deployments work today under the existing model.
4. **CSRF/session-middleware removal is safe as part of `airi-3cp`, not before.** `requireSameOrigin`/`origin.ts` exist to protect cookie-authenticated mutating routes; once `/api/auth/*` and the session cookie are gone there is no credential to cross-site abuse, and the remaining HTTP surface (`/health`) is read-only. Deletion rides the same change that removes the routes; this doc authorized the removal in principle, and `airi-3cp`/`airi-h8du` execute it under the 2026-11-25 approval.

## What this does NOT authorize

- This doc (ratified 2026-11-24) plus its dated evidence satisfies `airi-a02` criterion 3. Code removals are the maintainer-approved, in-progress `airi-3cp`/`airi-h8du` scope; check source before calling any group retired.
- No hosted identity, no community accounts, no daemon OAuth — explicitly out per `plan-ts-remote-sync-retirement.md:66-67`.
- No change to the gateway's transport security (wss beyond loopback, 0600 token/CA files, D-Bus session-bus trust) — that model is already ratified and is what remains.

## Verification

- This doc at `docs/decision-byos-identity.md` with status accepted (ratified 2026-11-24).
- Dated evidence comment recorded on `airi-a02` (criterion 3) and `airi-3cp` referencing this doc. (Done 2026-11-24: this doc's ratification + the checklist row update are the criterion-3 evidence; removal execution remains in `airi-3cp`.)
- `rg` inventory of `client.api.auth` / better-auth / `LoginDrawer` / `VITE_SERVER_URL` returns only tests + the references the plan documents, at `airi-3cp` time.
