<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Remote-client trust for an internet-exposed daemon gateway

- **Status:** proposed (design only; implementation tracked separately)
- **Bead:** `airi-py6`
- **Depends on:** `airi-79o` (BYOS identity: device-and-token, no accounts/OAuth)
- **Scope:** per-client identity, pairing, revocation, and rate limiting that must land before the daemon gateway is exposed to the open internet. LAN/VPN/tailnet deployments are **unaffected** and keep working under the existing single shared `authToken`.

## Context (source-verified)

- `docs/design-daemon-gateway.md:50-51,72-73`: internet exposure is explicitly out of scope today because the gateway's `authToken` is a single shared 122-bit secret with no per-client identity, revocation, or rate limiting. Non-loopback binds already force `wss://`.
- `docs/decision-byos-identity.md`: identity is device-and-token based, never account/OAuth based. The daemon never sees an account. "Who is authenticated" = "holds the 0600 config's token", with same-uid session-bus trust recorded as deliberate.
- Current mechanics (`crates/anima-channel/src/session.rs:19-27,294-296`, `crates/anima-channel/src/config.rs:46-48`, `crates/anima-daemon/src/gateway.rs:153-155,476-506`):
  - One shared `authToken` (UUIDv4, 122 bits) in `server-channel/config.json` (0600).
  - Mandatory first-message handshake (`{"type":"auth","authToken"}` or `module:authenticate` with `data.token`); close 1008 on mismatch.
  - `RegenerateGatewayToken` rotates the shared token and rebinds; live sessions keep their already-authenticated state (no force-close today).
  - Transport: `ws://` loopback only; `wss://` forced for any non-loopback hostname.
- Deployment vision (ratified 2026-11-24): daemon on an always-on desktop/VPS, thin Flutter/Vue/Godot clients connecting remotely over the internet. This design is the prerequisite for that.

## Decision

1. **Keep the shared `authToken` as the bootstrap/legacy credential** for loopback and LAN. Do not break existing clients.
2. **Add per-client (device) credentials** issued through a pairing flow initiated from a locally trusted session. Each client gets its own revocable token; the daemon stores only a hash.
3. **Wire protocol stays at version 1** (`design-daemon-gateway.md:91`, `design-daemon-client.md:17`). All changes are additive fields on the existing auth handshake and D-Bus control verbs.
4. **Revocation is per-client** (`RevokeGatewayClient`) plus an evict-all (`RevokeAllGatewayClients`); the existing `RegenerateGatewayToken` keeps its current "rotate shared secret" semantics and is not overloaded.
5. **Rate limiting lives at the gateway**, per credential and per source IP, with distinct buckets per verb class.
6. **No accounts, no OAuth, no hosted identity** — consistent with `airi-79o`. "Paired device" is the only identity.

## Pairing flow (how a client obtains its own token)

Pairing is initiated by a **locally trusted** caller (same-uid D-Bus session, 0600 config reader, or the settings UI), never by an unauthenticated network peer.

1. **Local issuance of a pairing code.** A trusted caller invokes a new D-Bus verb `CreatePairingCode(label, clientKind?)`. The daemon mints a short-lived, single-use code (128-bit entropy, base32, ~5 minute TTL) and returns `{ code, expiresAt, pairingId }`. The code is never persisted in plaintext beyond its TTL; only a hash is held in memory.
2. **Out-of-band delivery.** The code is shown as text/QR in the local UI (or printed by `busctl`). The remote client operator enters it (or scans the QR). Optionally the client also presents a `fingerprint` (hash of a client-generated public key / device id) in the same step; the local UI displays both for confirmation before the code is consumed ("compare these two strings").
3. **Exchange over the network.** The client opens a `wss://` connection and sends an auth frame carrying the pairing code instead of a token:
   ```json
   { "type": "auth", "pairingCode": "<code>", "client": { "label": "...", "kind": "flutter|godot|vue|script", "fingerprint": "..." } }
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
- Godot: OS credential store when available; otherwise an encrypted/0600 file under the user data dir.
- Clients must support "forget this device" (delete stored token) and "re-pair" flows.

## Wire format (additive; protocol stays 1)

- Auth handshake gains optional `pairingCode` and `client` fields; existing `authToken`/`data.token` unchanged.
- Auth reply gains optional `clientId` (and `authToken` only on successful pairing).
- RPC error frames gain an optional `retryAfter` (seconds) on `rate_limited` errors.
- No new frame types, no version bump, no change to `ping`/`pong`/`heartbeat`/`rpc`/`event`.

## Server-side credential store

**Where it lives:** the daemon's existing SQLite database (`anima-store`, `<data>/airi-slint/airi.sqlite`), not a new file and not `config.json`. This keeps backups, migrations, and the 0600 file posture consistent with the rest of daemon state. A new migration bumps `SCHEMA_VERSION` to 7.

**Table shape:**

```sql
CREATE TABLE gateway_clients (
    id            TEXT PRIMARY KEY,        -- credential id (UUIDv4)
    label         TEXT NOT NULL,
    token_hash    TEXT NOT NULL,           -- SHA-256(token), hex; lookup key
    client_kind   TEXT,                    -- flutter | godot | vue | script | other
    device_id     TEXT,                    -- optional stable device id
    fingerprint   TEXT,                    -- optional out-of-band fingerprint
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

## Revocation

- **Per-client:** new D-Bus verb `RevokeGatewayClient(id)` sets `revoked_at`, evicts the cache entry, and closes all live WebSocket sessions authenticated with that credential (close 1008). Requires a connection registry in `anima-channel` keyed by `clientId` (today the server does not track handles; this is a prerequisite).
- **Per-client metadata updates:** `RenameGatewayClient(id, label)` and `TouchGatewayClient(id)` (last_used) are optional convenience verbs.
- **List/inspect:** `ListGatewayClients() -> [{ id, label, clientKind, createdAt, lastUsedAt, revokedAt }]` (never returns tokens or hashes).
- **Evict-all (per-client):** `RevokeAllGatewayClients()` revokes every row and closes all per-client sessions. The shared bootstrap token is untouched.
- **Existing `RegenerateGatewayToken`:** unchanged semantics — rotates the shared `config.json` token and rebinds. It does **not** touch per-client credentials, so a panic rotation of the shared secret does not wipe paired devices. Operators who want a full wipe call both `RegenerateGatewayToken` and `RevokeAllGatewayClients`.
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

A new opt-in flag `internetExposed` (stored in `ChannelConfig` / reported by `GetGatewayConfig`) gates the stricter posture:

- When `false` (default): current behavior — shared token accepted from any bind, rate limiting advisory/best-effort, LAN/VPN/tailnet as today.
- When `true`:
  - Shared `authToken` is **not** accepted from non-loopback peers; only paired per-client tokens authenticate.
  - Rate limiting is enforced (not advisory).
  - `RegenerateGatewayToken` additionally warns that it does not revoke paired clients.
  - Audit logging records pairing/revocation/rate-limit events.

The flag is set via `ApplyGatewayConfig` (new optional `internetExposed` field, additive) or a dedicated D-Bus verb. Binding to a public interface without the flag is allowed but logs a warning ("internet exposure without per-client enforcement").

## D-Bus control surface (growth)

Existing verbs unchanged. New verbs (all same-uid trusted, no polkit, consistent with `design-daemon-gateway.md:76-84`):

- `CreatePairingCode(label: s, clientKind: s) -> s` (JSON `{ pairingId, code, expiresAt }`)
- `ListGatewayClients() -> s` (JSON array, no secrets)
- `RevokeGatewayClient(id: s) -> s` (`{ ok, revoked }`)
- `RevokeAllGatewayClients() -> s`
- `RenameGatewayClient(id: s, label: s) -> s`
- `ApplyGatewayConfig` gains optional `internetExposed` (boolean) and keeps existing fields.

No sender authorization is added; same-uid trust posture is unchanged. If stronger control-plane auth is wanted later, that is a separate policy decision, not this design.

## Migration / compatibility

- No forced migration: existing shared-token clients keep working on loopback/LAN.
- `gateway.config` RPC and `GetGatewayConfig` continue to return the shared `authToken` for local trusted callers, so the settings UI and local pairing UX are unchanged.
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
- Token hash: SHA-256 round-trip, constant-time comparison, no plaintext in DB.
- Per-token auth handshake: issued token authenticates; revoked token rejected
  with close 1008; unknown token rejected; bootstrap shared token accepted only
  under the policy defined in "Internet-exposure policy".
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

**Integration:**
- End-to-end pairing over `wss://` against a real `ChannelServer`: mint code →
  exchange → issued token → reconnect with issued token → RPC succeeds.
- Revoke mid-session over the same connection: close 1008 delivered, no further
  frames accepted.
- Rate-limit trip: exceed a bucket, confirm `rate_limited` RPC error with
  `retryAfter`, confirm connection close after repeated violations.
- Internet-exposure toggle: with `internetExposed=true`, bootstrap shared token
  rejected from a non-loopback peer; with `false`, accepted (regression of
  current behavior).

**D-Bus smoke (dbus-run-session bus):**
- `CreatePairingCode` / `ListGatewayClients` (no secrets in output) /
  `RevokeGatewayClient` / `RevokeAllGatewayClients` / `RenameGatewayClient`.
- `ApplyGatewayConfig` accepts the new optional `internetExposed` field;
  absent means keep.
- `RegenerateGatewayToken` still rotates only the shared token; paired rows
  survive.

**Conformance fixtures:**
- Add golden fixtures for the new auth shapes (`pairingCode`/`client` request,
  `clientId`/`authToken` pairing reply, `rate_limited` error with `retryAfter`)
  under `crates/anima-channel/fixtures/golden/`, registered in
  `crates/anima-channel/tests/golden_fixtures.rs` and checked by
  `crates/anima-channel/examples/export-golden-fixtures.rs`.
- `packages/stage-ui`/`apps/flutter`/`godot` wire-type regeneration
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
remote-access shape today.

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
  non-loopback peers** once `internetExposed` is true.
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
  1. **Fingerprint pinning at pairing time.** `CreatePairingCode` returns a
     SHA-256 fingerprint of the CA cert alongside the code; the client operator
     compares it during pairing (same OOB channel as the code) and pins it.
     No file transfer needed; works for any client.
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
  mechanism. No client trusts the minted CA by default.

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
  `internet_exposed_toggled`.
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
   it (local trusted context).
4. **Revocation safety.** `RegenerateGatewayToken` continues to rotate the
   shared token and rebind; it does not touch per-client rows, so a panic
   rotation no longer wipes paired devices (today it evicts everything —
   `design-daemon-gateway.md:166-168`). Operators wanting a full wipe call both
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
| **Keep shared token + VPN-only** (status quo) | Rejected for internet | No per-client identity, no revocation, no rate limiting. A single leak compromises all clients and requires full rotation. Acceptable for LAN/VPN/tailnet (kept as default); insufficient for hostile networks. This is the baseline this design extends, not replaces. |
| **Full OAuth/OIDC proxy** (better-auth-style) | Rejected | Contradicts `airi-79o`: introduces accounts, sessions, a hosted identity provider, and custody the architecture explicitly excludes. Duplicates better-auth for a single-owner deployment; retirement gate (`airi-3cp`) would never pass. The daemon would have to become an identity server, which it must not be. |
| **mTLS device certificates** | Rejected (for now) | Strong device identity and no bearer-token leakage, but: (a) CA issuance/rotation/renewal is heavy for a personal daemon; (b) mobile/Flutter and browser/Electrobun clients have uneven client-cert UX; (c) revocation requires CRL/OCSP infrastructure we do not want to operate. Recorded as a future hardening option if bearer-token incidents occur; pairing-time fingerprint pinning achieves most of the benefit at far lower cost. |
| **Hosted relay / community backend** | Rejected | Out of scope per `decision-server-endpoints.md`; no hosted custody. |
| **Per-IP allowlisting only** | Rejected | IPs are not identity; mobile clients change networks; provides no revocation or audit granularity. |

**Chosen:** per-client bearer tokens issued via OOB pairing, hash-stored, individually revocable, rate-limited at the gateway, with the shared token retained as a loopback-only bootstrap. Matches zero-account BYOS and reuses existing adoption/transport machinery.