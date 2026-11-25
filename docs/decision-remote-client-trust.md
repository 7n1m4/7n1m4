<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Remote-client trust for an internet-exposed daemon gateway

- **Status:** proposed (design only; implementation tracked separately; not ratified)
- **Bead:** `airi-py6`
- **Depends on:** `airi-79o` (BYOS identity: device-and-token, no accounts/OAuth)
- **Scope:** per-client identity, pairing, revocation, and rate limiting that must land before the daemon gateway is exposed to the open internet. LAN/VPN/tailnet deployments bound to a private address are **unaffected** and keep working under the existing single shared `authToken`; wildcard binds (`0.0.0.0` / `::`) are public and require the `internetExposed` opt-in plus paired clients.

## Context (source-verified)

- `docs/design-daemon-gateway.md:50-51,72-73`: internet exposure is explicitly out of scope today because the gateway's `authToken` is a single shared 122-bit secret with no per-client identity, revocation, or rate limiting. Non-loopback binds already force `wss://`.
- `docs/decision-byos-identity.md`: identity is device-and-token based, never account/OAuth based. The daemon never sees an account. "Who is authenticated" = "holds the 0600 config's token", with same-uid session-bus trust recorded as deliberate.
- Current mechanics (`crates/anima-channel/src/session.rs:19-27,294-296`, `crates/anima-channel/src/config.rs:46-48`, `crates/anima-daemon/src/gateway.rs:153-155,476-506`):
  - One shared `authToken` (UUIDv4, 122 bits) in `server-channel/config.json` (0600).
  - Mandatory first-message handshake (`{"type":"auth","authToken"}` or `module:authenticate` with `data.token`); close 1008 on mismatch.
  - `RegenerateGatewayToken` rotates the shared token, persists it, and rebinds. Live sessions stay authenticated (no force-close); the rotation affects new connections only. It does not evict paired-client rows (none exist today).
  - Transport: `ws://` loopback only; `wss://` forced for any non-loopback hostname.
  - The WS RPC `gateway.config` returns only `{ hostname, port }` (`crates/anima-channel/src/dispatch.rs:424-434`, `crates/anima-channel/src/wire.rs:520-530`); it never returns `authToken`. The D-Bus `GetGatewayConfig` verb does return the shared token, but only over the same-uid session bus (`crates/anima-channel/src/control.rs:18-45`, `crates/anima-daemon/src/gateway.rs:377-393`).
  - Mutating/executing `renderer.*` verbs require literal `allowActions: true` in `config.json`; a non-loopback bind additionally requires literal `allowRemoteActions: true` (`crates/anima-daemon/src/gateway.rs:113-166`, tracked by `airi-i4i`). Absent, false, or wrong-typed flags fail closed; this is an action gate, not authorization for internet exposure.
- Deployment vision (ratified 2026-11-24): daemon on an always-on desktop/VPS, thin Flutter/Vue clients connecting remotely over the internet. This design is the prerequisite for that. (Godot was listed historically; no longer an active client kind.)

## Decision

1. **Keep the shared `authToken` as the bootstrap/legacy credential** for loopback and private LAN/VPN binds. Do not break existing clients on those addresses; wildcard/public binds are the hardened path.
2. **Add per-client (device) credentials** issued through a pairing flow initiated from a locally trusted session. Each client gets its own revocable token; the daemon stores only a hash.
3. **Wire protocol stays at version 1** (`design-daemon-gateway.md:91`, `design-daemon-client.md:17`). All changes are additive fields on the existing auth handshake and D-Bus control verbs.
4. **Revocation is per-client** (`RevokeGatewayClient`) plus an evict-all (`RevokeAllGatewayClients`); the existing `RegenerateGatewayToken` keeps its current "rotate shared secret" semantics and is not overloaded.
5. **Rate limiting lives at the gateway**, per credential and per source IP, with distinct buckets per verb class.
6. **No accounts, no OAuth, no hosted identity** — consistent with `airi-79o`. "Paired device" is the only identity.

## Pairing flow (how a client obtains its own token)

Pairing is initiated by a **locally trusted** caller (same-uid D-Bus session, 0600 config reader, or the settings UI), never by an unauthenticated network peer.

1. **Local issuance of a pairing code.** A trusted caller invokes a new D-Bus verb `CreatePairingCode(label, clientKind?)`. The daemon mints a short-lived, single-use code (128-bit entropy, base32, ~5 minute TTL) and returns `{ code, expiresAt, pairingId, caFingerprint }`. `caFingerprint` is the lowercase hex SHA-256 of the DER bytes of `websocket-ca-cert.pem` (the CA in `GetGatewayConfig.caCertPath`), or `null` when no CA exists yet (loopback-only plaintext binds). The code is never persisted in plaintext beyond its TTL; only a hash is held in memory.
2. **Out-of-band delivery.** The code is shown as text/QR in the local UI (or printed by `busctl`). The remote client operator enters it (or scans the QR). The local UI also displays `caFingerprint` when present and the operator confirms that the client's pinned CA fingerprint matches before the code is consumed. The optional client `fingerprint` (hash of a client-generated public key / device id) is displayed alongside for a second "compare these two strings" confirmation; it is not a substitute for CA pinning.
3. **Exchange over the network.** The client opens a `wss://` connection and sends an auth frame carrying the pairing code instead of a token:
   ```json
   { "type": "auth", "pairingCode": "<code>", "client": { "label": "...", "kind": "flutter|vue|script", "fingerprint": "..." } }
   ```
   (The `module:authenticate` shape carries the same under `data.pairingCode` / `data.client`.)
4. **Minting.** The daemon validates the code (exists, unexpired, unused), consumes it, creates a `gateway_clients` row, generates a fresh per-client token (UUIDv4 or 256-bit random), stores only its hash, and replies:
   ```json
   { "type": "auth", "ok": true, "clientId": "<id>", "authToken": "<per-client token>" }
   ```
   The plaintext token is returned **once** and never stored or logged.
5. **Subsequent connections** use the issued token as the ordinary `authToken`:
   ```json
   { "type": "auth", "authToken": "<per-client token>" }
   ```
   The daemon resolves it to a `gateway_clients` row; if found and not revoked/expired, the connection is authenticated and tagged with that `clientId` for rate limiting and audit.

Backward compatibility: a connection presenting the shared `authToken` from `config.json` still authenticates as the implicit "bootstrap/legacy" client, subject to the internet-exposure policy below.

## Token storage on the client

- **Never in URLs, query strings, logs, or browser `localStorage`.**
- Flutter: `flutter_secure_storage` (Keychain on iOS/macOS, Keystore on Android, encrypted prefs elsewhere) — add as a dependency in `apps/flutter`.
- Vue/Electrobun: OS keychain via Electron `safeStorage` where available; otherwise a 0600 file under `<userData>` (same posture as the daemon's config). Never `localStorage`.
- Godot (historical): OS credential store when available; otherwise an encrypted/0600 file under the user data dir. (No longer an active client kind.)
- Clients must support "forget this device" (delete stored token) and "re-pair" flows.

## Wire format (additive; protocol stays 1)

- Auth handshake gains optional `pairingCode` and `client` fields; existing `authToken`/`data.token` unchanged.
- Auth reply gains optional `clientId` (and `authToken` only on successful pairing).
- RPC error frames gain an optional `retryAfter` (seconds) on `rate_limited` errors.
- No new frame types, no version bump, no change to `ping`/`pong`/`heartbeat`/`rpc`/`event`.
- `gateway.config` RPC keeps its current secret-free `{ hostname, port }` shape on both loopback and non-loopback binds; no token is ever added. The local D-Bus `GetGatewayConfig` keeps returning `authToken` to same-uid callers only.

## Server-side credential store

**Where it lives:** the daemon's existing SQLite database (`anima-store`, `<data>/airi-slint/airi.sqlite`), not a new file and not `config.json`. This keeps backups, migrations, and the 0600 file posture consistent with the rest of daemon state. A new migration bumps `SCHEMA_VERSION` to 7.

**Table shape:**

```sql
CREATE TABLE gateway_clients (
    id            TEXT PRIMARY KEY,        -- credential id (UUIDv4)
    label         TEXT NOT NULL,
    token_hash    TEXT NOT NULL,           -- SHA-256(token), hex; lookup key
    client_kind   TEXT,                    -- flutter | vue | script | other (godot historical)
    device_id     TEXT,                    -- optional stable device id
    fingerprint   TEXT,                    -- optional out-of-band client fingerprint
    ca_fingerprint TEXT,                   -- SHA-256(CA DER) pinned at pairing time
    scopes        TEXT NOT NULL DEFAULT '["rpc"]',  -- JSON array of verb scopes
    created_at    INTEGER NOT NULL,
    last_used_at  INTEGER,
    last_used_ip  TEXT,
    revoked_at    INTEGER,                -- NULL = active
    expires_at    INTEGER                 -- NULL = no expiry
);
CREATE UNIQUE INDEX idx_gateway_clients_token_hash ON gateway_clients(token_hash);
CREATE INDEX idx_gateway_clients_revoked ON gateway_clients(revoked_at);
```

- Only the **hash** is persisted; the plaintext token is returned once at issuance.
- An in-memory `HashMap<token_hash, ClientCredential>` cache is loaded at daemon start and invalidated on issue/revoke, so the handshake stays O(1) and does not hit SQLite per connection.
- `scopes` defaults to `["rpc"]` (full RPC access matching today's single token). Future scoping can restrict verb subsets without a schema change.
- `ca_fingerprint` records what the operator confirmed at pairing time; it changes only via a new explicit re-pair, never silently when the CA is re-minted.

## Revocation

- **Per-client:** new D-Bus verb `RevokeGatewayClient(id)` sets `revoked_at`, evicts the cache entry, and closes all live WebSocket sessions authenticated with that credential (close 1008). Requires a connection registry in `anima-channel` keyed by `clientId` (today the server does not track handles; this is a prerequisite).
- **Per-client metadata updates:** `RenameGatewayClient(id, label)` and `TouchGatewayClient(id)` (last_used) are optional convenience verbs.
- **List/inspect:** `ListGatewayClients() -> [{ id, label, clientKind, createdAt, lastUsedAt, revokedAt }]` (never returns tokens or hashes).
- **Evict-all (per-client):** `RevokeAllGatewayClients()` revokes every row and closes all per-client sessions. The shared bootstrap token is untouched.
- **Existing `RegenerateGatewayToken`:** unchanged semantics — generates a new UUIDv4 shared token, persists `config.json`, and rebinds the listener to the new effective config; a failed rebind is reported `ok:false`. It does **not** close live sessions (they keep their already-authenticated state) and does **not** touch per-client credentials, so a panic rotation of the shared secret does not wipe paired devices. Operators who want a full wipe call both `RegenerateGatewayToken` and `RevokeAllGatewayClients`.
- Live-session kill-on-revoke is a new capability; today's "live sessions keep their authenticated state" note (`design-daemon-gateway.md:166-168`) is relaxed only for explicit per-client revocation.

## Rate limiting at the gateway

Implemented in `anima-channel` (or a small middleware in the daemon) as token buckets. State is in-memory and resets on daemon restart (acceptable; revocation is the persistent control).

Buckets:

- **Unauthenticated / pairing attempts:** per source IP, 10 attempts / 60 s. Excess → close 1008 with `rate_limited` (or refuse the upgrade).
- **Authenticated connections:** per credential id, max N concurrent connections (e.g. 4) and a per-IP cap to prevent one credential being used from many hosts.
- **RPC verb classes (per credential id):**
  - `read` (`core.status`, `settings.get`, `providers.list`, `chat.history`, `sessions.list`, …): 120 / 60 s.
  - `write` (`chat.send`, `chat.cancel`, `settings.set`, `journal.append`, `cards.*`, …): 30 / 60 s.
  - `heavy` (`stmm.rebuild`, `sessions.export`, `sessions.import`, `retrieval.*`): 6 / 60 s.
  - `admin` (any D-Bus-equivalent RPC exposed over WS, if ever): denied over WS entirely.
- **Global:** total connections cap (e.g. 64) and total RPC throughput cap to protect the host.

On exceed: reply with an RPC error frame `{ "ok": false, "error": { "code": "rate_limited", "message": "...", "retryAfter": <seconds> } }` and, for repeated violations, close the connection (1008). Classify verbs by an explicit allowlist in `dispatch.rs` (default class `write` for unknown methods — fail closed).

## Internet-exposure policy

A new opt-in flag `internetExposed` (stored in `ChannelConfig` / reported by `GetGatewayConfig`) gates the stricter posture. A **public bind** is either a wildcard bind (`0.0.0.0` / `::`) or a non-loopback hostname that is not a private LAN/VPN address (RFC1918, unique-local, or a tailnet DNS name).

- When `false` (default): current behavior — shared token accepted on LAN/VPN/tailnet binds, rate limiting advisory/best-effort. Public binds are refused.
- When `true`:
  - Public binds are permitted; the bind is treated as internet-exposed.
  - Shared `authToken` is **not** accepted from non-loopback peers; only paired per-client tokens authenticate.
  - Rate limiting is enforced (not advisory).
  - `RegenerateGatewayToken` additionally warns that it does not revoke paired clients.
  - Audit logging records pairing/revocation/rate-limit events.

The flag is set via `ApplyGatewayConfig` (new optional `internetExposed` field, additive) or a dedicated D-Bus verb. **Fail-closed public binds:** a public bind MUST be rejected unless `internetExposed: true` is already set in the effective config at bind time. Today code only forces `wss://`, logs a warning, and still binds; the warning is not a gate. This design changes that: `load_or_heal`, `Gateway::apply`, and the rebinding `RegenerateGatewayToken` path refuse to persist/bind a public config with the flag absent or false (only literal `true` counts; invalid values fail closed). On startup refusal the gateway stays unbound with `lastError` explaining the missing opt-in; no listener is opened, and no config is silently rewritten to loopback. LAN/VPN/tailnet binds keep working under the existing shared-token policy without the flag.

Mutating verbs on a non-loopback bind remain a separate, fail-closed gate: literal `allowActions: true` plus the explicit `allowRemoteActions: true` opt-in (tracked in `airi-i4i`) are required; absence, `false`, or a wrong type denies every mutating/executing verb even for an authenticated paired client. `internetExposed` alone never enables actions, and `gateway.config` over WS never returns any secret.

## D-Bus control surface (growth)

Existing verbs unchanged. New verbs (all same-uid trusted, no polkit, consistent with `design-daemon-gateway.md:76-84`):

- `CreatePairingCode(label: s, clientKind: s) -> s` (JSON `{ pairingId, code, expiresAt, caFingerprint }`; fingerprint is null when no CA exists)
- `ListGatewayClients() -> s` (JSON array, no secrets)
- `RevokeGatewayClient(id: s) -> s` (`{ ok, revoked }`)
- `RevokeAllGatewayClients() -> s`
- `RenameGatewayClient(id: s, label: s) -> s`
- `ApplyGatewayConfig` gains optional `internetExposed` (boolean) and keeps existing fields.
- `ApplyGatewayConfig` gains `allowRemoteActions` (boolean strict opt-in) per `airi-i4i`; absent/false/wrong type is treated as false.

No sender authorization is added; same-uid trust posture is unchanged. If stronger control-plane auth is wanted later, that is a separate policy decision, not this design.

## Migration / compatibility

- No forced migration: existing shared-token clients keep working on loopback and private LAN/VPN addresses; wildcard binds are public and need the opt-in.
- `gateway.config` RPC continues to return only `{ hostname, port }` for every caller, including remote paired clients. `GetGatewayConfig` (same-uid D-Bus only) continues to return the shared `authToken` so the settings UI and local pairing UX are unchanged; WS clients must use the local config file or the pairing UX to obtain a bootstrap token.
- Old clients that never pair continue to use the shared token; they are treated as the implicit bootstrap client and remain subject to the internet-exposure policy.
- Schema migration is additive (new table only); no existing table changes. `SCHEMA_VERSION` 6 → 7.

## What this does NOT do

- No accounts, OAuth, sessions, or CSRF — consistent with `airi-79o`.
- No change to transport security (wss beyond loopback, 0600 files, local CA) — that model is already ratified.
- No hosted relay or community backend.
- No automatic key rotation / expiry policy beyond per-client `expires_at` (operator-driven).
- No implementation of the connection registry or rate limiter in this bead; this document is the design gate.

## Verification (for the eventual implementation)

Evidence that proves this design landed, grouped by layer. All existing tests
must remain green; new tests are additive.

**Unit (crates/anima-channel, crates/anima-daemon, crates/anima-store):**
- Pairing code: single-use (second consume fails), TTL expiry, 128-bit entropy,
  base32 round-trip, hash-only persistence (plaintext never stored).
- Pairing response: `caFingerprint` equals SHA-256(CA DER) when the CA exists,
  and is `null` for a loopback plaintext bind; the fingerprint is displayed in
  the local UI before the code is consumed.
- Token hash: SHA-256 round-trip, constant-time comparison, no plaintext in DB.
- Per-token auth handshake: issued token authenticates; revoked token rejected
  with close 1008; unknown token rejected; bootstrap shared token accepted only
  under the policy defined in "Internet-exposure policy".
- `RegenerateGatewayToken`: new token persisted and listener rebound; live
  sessions remain connected; paired-client rows unchanged; failed rebind
  returns `ok:false`.
- Revocation evicts exactly one client: `RevokeGatewayClient(id)` closes only
  sessions authenticated with that credential; other paired clients and the
  bootstrap token (where permitted) remain connected.
- `RevokeAllGatewayClients` closes every per-client session and empties the
  table; bootstrap token unaffected.
- Rate-limit bucket: token-bucket refill math, per-IP pairing cap (10/60s),
  per-credential concurrent-connection cap, per-verb-class limits
  (read/write/heavy), `retryAfter` value correctness, fail-closed default class
  for unknown methods.
- Schema: SCHEMA_VERSION 6→7 migration is additive (new table only); existing
  tables/columns unchanged; rollback leaves shared-token path functional.
- Public bind: a wildcard bind (`0.0.0.0`/`::`) or a public-routable non-loopback
  hostname with `internetExposed` absent/false is refused at startup, by
  `ApplyGatewayConfig`, and by the token-rotation rebind; no listener opens,
  `lastError` names the missing opt-in, and loopback/private LAN binds remain
  unaffected.

**Integration:**
- End-to-end pairing over `wss://` against a real `ChannelServer`: mint code →
  exchange → issued token → reconnect with issued token → RPC succeeds.
- Revoke mid-session over the same connection: close 1008 delivered, no further
  frames accepted.
- Rate-limit trip: exceed a bucket, confirm `rate_limited` RPC error with
  `retryAfter`, confirm connection close after repeated violations.
- Internet-exposure toggle: with `internetExposed=true`, bootstrap shared token
  rejected from a non-loopback peer; with `false`, bootstrap shared token remains
  accepted for private LAN/VPN peers, but a wildcard/public bind is refused.
- `gateway.config` over WS returns only `{ hostname, port }` on both loopback
  and non-loopback binds; D-Bus `GetGatewayConfig` still returns `authToken` to
  same-uid callers only.

**D-Bus smoke (dbus-run-session bus):**
- `CreatePairingCode` / `ListGatewayClients` (no secrets in output) /
  `RevokeGatewayClient` / `RevokeAllGatewayClients` / `RenameGatewayClient`.
- `ApplyGatewayConfig` accepts the new optional `internetExposed` field and
  strict `allowRemoteActions`; absent means keep for `internetExposed`, false
  for `allowRemoteActions`.
- `RegenerateGatewayToken` still rotates only the shared token; paired rows
  survive.
- `GetGatewayConfig` returns `authToken` over the session bus; WS `gateway.config`
  does not.

**Conformance fixtures:**
- Add golden fixtures for the new auth shapes (`pairingCode`/`client` request,
  `clientId`/`authToken` pairing reply, `rate_limited` error with `retryAfter`)
  under `crates/anima-channel/fixtures/golden/`, registered in
  `crates/anima-channel/tests/golden_fixtures.rs` and checked by
  `crates/anima-channel/examples/export-golden-fixtures.rs`.
- `packages/stage-ui`/`apps/flutter` wire-type regeneration (godot historical)
  (`export-wire-types`) stays drift-free; no protocol version bump.

**Regression:**
- Existing shared-token auth tests and `RegenerateGatewayToken` tests still pass.
- Protocol wire tests unchanged (additive fields only).
- `cargo test --workspace --locked` green.

## Scope and authority

This document is a **design gate only**. It does **not** authorize code changes,
schema migrations, new D-Bus verbs, rate limiters, pairing flows, or internet
exposure. Implementation lands in separate beads/tickets that must cite this doc
and pass the verification above. Internet exposure of a daemon gateway remains
**out of scope and unsupported** until an implementation bead closes with the
evidence listed here; LAN/VPN/tailnet deployments are the only supported
remote-access shape today. The fail-closed public-bind rule above is a proposed
design requirement, not current code behavior.

## Threat model update (remote internet adversary)

Today's posture (`design-daemon-gateway.md:53-91`) assumes same-uid / LAN / VPN
peers. Internet exposure adds a new adversary class that the current model does
not cover; this design closes the gaps below without weakening the existing
posture.

- **New adversary: arbitrary remote host.** Can reach the public bind, attempt
  credential guessing, replay, DoS, and traffic analysis. Assumed to have no
  same-uid access and no LAN position.
- **Shared-token exposure blast radius.** Today one leaked token compromises
  every client and cannot be surgically revoked. Per-client tokens localize
  blast radius to one device; `RevokeGatewayClient` removes it without
  disturbing others. The bootstrap shared token is therefore **disabled for
  non-loopback peers** once `internetExposed` is true, and a public bind without
  that flag is refused outright.
- **Token-in-flight.** `wss://` is already forced for any non-loopback hostname
  (`design-daemon-gateway.md:37-43`); internet exposure keeps this and adds
  HSTS-equivalent "always wss" enforcement plus rejection of plaintext upgrades.
  No new transport work.
- **Brute force / credential stuffing.** Pairing codes are single-use, 128-bit,
  5-minute TTL, issued only by a trusted local caller. Authenticated endpoints
  are rate-limited per credential and per source IP. Pairing attempts are
  bucketed at 10/60s per IP.
- **Replay.** Tokens are bearer secrets over TLS; no replay protection beyond
  TLS. Pairing codes are single-use and TTL-bounded. Acceptable for the threat
  model; no challenge-response added (would complicate the zero-account story).
- **Device loss / theft.** Per-client revocation covers it; `last_used_at` /
  `last_used_ip` aid detection. No remote wipe of client-stored token (client
  owns its own storage).
- **Same-uid unchanged.** Local session-bus trust and 0600 file posture are
  unchanged (`design-daemon-gateway.md:76-84`); a same-uid attacker still wins
  by reading files. This is accepted and documented, not a regression.
- **Audit.** All issuance, revocation, rate-limit trips, and `internetExposed`
  toggles are appended to the daemon's existing audit JSONL
  (`crates/anima-daemon/src/audit.rs`) with credential id + label + source IP,
  never tokens or hashes.

## TLS and CA distribution to remote clients

Transport is already solved: non-loopback binds force `wss://` with a locally
minted CA + SAN-covered leaf (`design-daemon-gateway.md:37-49`). The open gap is
distribution of trust in that CA (`design-daemon-gateway.md:172-174`: "CA
distribution is a UX step not yet designed").

- **Loopback/LAN clients** install the CA via the existing settings UI path
  (`caCertPath` from `GetGatewayConfig`), mkcert-style.
- **Remote internet clients** cannot be assumed to share a filesystem with the
  host. Distribution options, in preference order:
  1. **Fingerprint pinning at pairing time (required first cut).** `CreatePairingCode` returns a `caFingerprint` (SHA-256 hex of the CA certificate DER) alongside the code, sourced from the same CA file that `caCertPath` names. The operator confirms the fingerprint in the local UI/out-of-band channel and the client pins it before consuming the code; the pinned value is stored with the client row and checked on every reconnect. No file transfer needed; works for any client. `caFingerprint` is `null` only for loopback plaintext binds with no minted CA, which are not internet-exposed.
  2. **Out-of-band CA download.** The daemon serves the CA cert over a
     short-lived, pairing-code-gated HTTPS-ish endpoint OR the operator copies
     `caCertPath` out. Lower preference (extra surface).
  3. **Public CA (Let's Encrypt) for the VPS case.** When the daemon runs on a
     VPS with a real domain, the operator may supply their own cert/key via
     `ApplyGatewayConfig` (future field) instead of the minted CA. This removes
     the CA-install step entirely for that deployment. **Not in scope for this
     design's first cut**; recorded as the eventual VPS path.
- **Decision:** pairing-time fingerprint pinning is the required mechanism for
  the first internet-capable release; CA-file distribution remains the LAN
  mechanism. No client trusts the minted CA by default. A changed CA fingerprint
  is a hard failure requiring explicit re-pairing; no silent TOFU upgrade.

## CSRF / origin for any future HTTP surface

- The daemon has **no HTTP surface today** (`decision-server-endpoints.md:13`:
  no axum/warp/actix, no routes). The gateway is WebSocket-only.
- If an HTTP surface is ever added (e.g. CA download, health probe beyond
  loopback), it must be **read-only or pairing-gated**, never cookie/session
  authenticated, and must not reuse any ambient browser credential. CSRF does
  not apply to bearer-token WebSocket handshakes.
- Consistent with `decision-byos-identity.md` §4: CSRF middleware is retired
  with the TS auth layer; nothing in this design re-introduces it.

## Audit logging of token issuance / revocation

- Extend the daemon's existing audit JSONL writer (redacted) with events:
  `pairing_code_created`, `pairing_code_consumed`, `client_issued`,
  `client_revoked`, `client_renamed`, `revoke_all`, `rate_limited`,
  `internet_exposed_toggled`, `public_bind_refused`.
- Fields: timestamp, event, credential id, label, source IP, outcome. **Never**
  the token, token hash, or pairing code.
- Retention follows existing audit policy; no new storage.

## Migration path from single shared token to per-client tokens

The adoption pattern already exists (`design-daemon-gateway.md:31-36`,
`crates/anima-daemon/src/gateway.rs` `adopt()`): copy config on first run,
preserve `authToken`. This design reuses it:

1. **No forced migration.** Existing `config.json` with a shared token keeps
   working. The shared token is registered implicitly as the "bootstrap"
   credential at daemon start (in-memory only, not a DB row) so no schema
   backfill is required.
2. **Opt-in pairing.** Operators pair new devices via `CreatePairingCode` when
   they want per-client identity/revocation. Old clients keep using the shared
   token and are treated as the bootstrap client.
3. **Gradual hardening.** Setting `internetExposed=true` disables the bootstrap
   token for non-loopback peers, forcing pairing. Loopback peers may still use
   it (local trusted context); a wildcard/public bind without the flag is refused.
4. **Revocation safety.** `RegenerateGatewayToken` continues to rotate the
   shared token and rebind; it does not touch per-client rows, so a panic
   rotation no longer wipes paired devices (today it affects new connections
   only and keeps live sessions authenticated — `design-daemon-gateway.md:166-168`). Operators wanting a full wipe call both
   `RegenerateGatewayToken` and `RevokeAllGatewayClients`.
5. **Rollback.** Per-client tables are additive (new table only, SCHEMA 6→7);
   removing the feature leaves the shared-token path fully functional. No
   existing table or column changes.

## Tradeoffs

Recorded against the zero-account BYOS constraint (`decision-byos-identity.md`):
identity is device-and-token based, no accounts/OAuth, daemon never sees an
account, user owns the host.

| Alternative | Verdict | Why |
|---|---|---|
| **Keep shared token + VPN-only** (status quo) | Rejected for internet | No per-client identity, no revocation, no rate limiting. A single leak compromises all clients and requires full rotation. Acceptable for private LAN/VPN/tailnet binds (kept as default); insufficient for hostile networks or wildcard binds. This is the baseline this design extends, not replaces. |
| **Full OAuth/OIDC proxy** (better-auth-style) | Rejected | Contradicts `airi-79o`: introduces accounts, sessions, a hosted identity provider, and custody the architecture explicitly excludes. Duplicates better-auth for a single-owner deployment; retirement gate (`airi-3cp`) would never pass. The daemon would have to become an identity server, which it must not be. |
| **mTLS device certificates** | Rejected (for now) | Strong device identity and no bearer-token leakage, but: (a) CA issuance/rotation/renewal is heavy for a personal daemon; (b) mobile/Flutter and browser/Electrobun clients have uneven client-cert UX; (c) revocation requires CRL/OCSP infrastructure we do not want to operate. Recorded as a future hardening option if bearer-token incidents occur; pairing-time fingerprint pinning achieves most of the benefit at far lower cost. |
| **Hosted relay / community backend** | Rejected | Out of scope per `decision-server-endpoints.md`; no hosted custody. |
| **Per-IP allowlisting only** | Rejected | IPs are not identity; mobile clients change networks; provides no revocation or audit granularity. |

**Chosen:** per-client bearer tokens issued via OOB pairing, hash-stored, individually revocable, rate-limited at the gateway, with the shared token retained as a loopback-only bootstrap. Matches zero-account BYOS and reuses existing adoption/transport machinery.
