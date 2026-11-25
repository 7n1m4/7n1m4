# Design: LAN CA distribution and client trust UX

**Status:** design (E3-T4). **Bead:** `airi-u71.6` (parent `airi-wxp.3` E3).
**Scope:** daemon-minted local CA (`websocket-ca-cert.pem`) — how it is exported, shown, fingerprint-verified, installed/trusted, rotated, and rejected; secrets stay 0600; platform differences named. Trust covers LAN `wss://`, peer pairing (libp2p), and tunnel (Cloudflare) trust.

## 1. Trust model

- Host = single trust root. Daemon mints CA once (`crates/anima-channel/src/certs.rs`, `CA_CERT_FILE`/`CA_KEY_FILE`); CA key `0600`, CA cert `0644` (public). Leaf re-mints on SAN drift; CA reused.
- Client trusts host by (a) pinned CA fingerprint shown in host UI, verified out-of-band, then (b) installing that CA into the client's trust store. No TOFU. Wrong CA → TLS handshake fails (rustls `UnknownIssuer`); client surfaces "CA mismatch" and refuses to send token.
- Auth token remains independent gate (close 1008). TLS trust ≠ authentication.

## 2. Surfaces

| Surface | Host | Client |
|---|---|---|
| Settings → System → Connection | shows `caCertPath`, SHA-256 fingerprint (hex + QR), "Export CA" button, rotation button | "Trust host" wizard |
| D-Bus `GetGatewayConfig` | adds `caCertPath`, `caCertFingerprint` (sha256 hex) | — |
| D-Bus `RegenerateGatewayToken` | existing | re-pair |
| New D-Bus `RotateCa` (audited) | mints new CA + leaf, invalidates paired clients | re-trust |
| Filesystem | `certs/websocket-ca-cert.pem` (0644) | client trust store |

Fingerprint = SHA-256 of DER of CA cert, lowercase hex, grouped. Shown as text + QR (payload `airi-ca:<host>:<port>:<sha256>`). QR only encodes fingerprint + endpoint, never key.

## 3. Flows

### A. Show/export (host)
1. Host computes fingerprint from `ca_cert_pem` dir; cached in memory, recomputed on read (cheap).
2. "Show" displays fingerprint + QR + path. "Export" copies PEM to user-chosen path via native save dialog; file mode 0644. No key ever exported; `CA_KEY_FILE` excluded by allowlist (only `CA_CERT_FILE`).

### B. Install/trust (client)
- Linux desktop: `trust anchor --store=...`? Use OS trust store via `update-ca-certificates`/`trust` (p11-kit) when root; else user NSS DB (`certutil -A -t "C,,"`) for Firefox/Chromium NSS. Flutter client only; Godot retired: bundle CA into app trust store at runtime (rustls `RootCertStore::add`), persisted in app data dir `0600`? cert is public; store `0644` but dir `0700`.
- Android: Network Security Config `trust-anchors` with user CA; install via system prompt (Settings → Security → Install cert) OR app-private trust store for app-only TLS. Prefer app-private to avoid global trust; fingerprint check before accepting.
- iOS: profile-based CA install (user must enable in Settings → General → VPN & Device Management → trust). App shows fingerprint + "Open Settings" deep link; cannot auto-trust.
- macOS/Windows in-app fallback: OS keychain (`security add-trusted-cert` / `certmgr`) optional; default app-private rustls store + fingerprint pinning.

### C. Pairing (mobile remote via libp2p / tunnel)
- Peer discovery yields peer ID + multiaddr. Trust requires out-of-band fingerprint of peer's CA cert (same fingerprint scheme) exchanged via QR/pairing code. Tunnel (Cloudflare) additionally validates tunnel cert chain (public CA) but still pins host CA fingerprint for the inner `wss://`.

### D. Rotation
- `RotateCa` (audited, same-uid): deletes CA + key + leaf + sidecar, re-mints, bumps `caGeneration` counter in config. Live connections keep their TLS (cert already negotiated); new connections need new CA. Clients see TLS failure → re-run trust wizard; UI shows "host CA changed" with old vs new fingerprint.
- Token rotation (`RegenerateGatewayToken`) independent; can be combined in "Re-pair all clients" action.

### E. Wrong-CA rejection
- Client compares server cert chain's root fingerprint to pinned value; mismatch → abort before sending token, UI: "Host identity changed. Re-pair?" with old/new fingerprints side-by-side. No silent fallback.

## 4. Security constraints

- `CA_KEY_FILE` and token config `0600`, dirs `0700`. CA cert `0644`.
- Export allowlist: only `CA_CERT_FILE`. Key files never leave host; `RotateCa` is the only mutation.
- Fingerprint computed over DER; PEM reformatting doesn't change it.
- No CA key in logs, QR, or network.

## 5. Platform differences (named)

| Platform | Trust mechanism | Auto-install? | Notes |
|---|---|---|---|
| Linux desktop | p11-kit/NSS + app-private | semi (pkexec) | root may be needed for system store |
| macOS | Keychain (app-private default) | no (prompt) | `security` CLI optional |
| Windows | certmgr / app-private | no | UAC prompt |
| Android | app-private trust store (default) or system install | no (user confirms) | Network Security Config |
| iOS | profile install + manual trust toggle | no | deep link to Settings |
| Tunnel (CF) | public CA for tunnel + pinned host CA for inner wss | n/a | double layer |

## 6. Implementation checklist (follow-up, not this bead)

- Add `caCertFingerprint` to `GetGatewayConfig` reply (Rust + specta TS).
- Add `RotateCa` D-Bus method + audit.
- Host UI: fingerprint + QR + export + rotate.
- Client trust wizard + wrong-CA screen.
- Tests: fingerprint stability, export allowlist, rotation increments generation, wrong-CA rejection.

## 7. Open questions

- Should CA rotation auto-revoke paired peer IDs (libp2p)? Proposed yes for tunnel peers, optional for LAN.
- iOS profile hosting (self-hosted vs MDM) deferred.
