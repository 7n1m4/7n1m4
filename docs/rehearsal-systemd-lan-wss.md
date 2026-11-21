# Rehearsal: systemd user service + LAN wss gateway pairing

**Beads:** `airi-wxp.5.3` (absorbs `airi-pxg.3`, `airi-pxg.5`). **Status:** procedure defined; not yet executed end-to-end.

This runbook is the single source of truth for the systemd install/upgrade rehearsal
and the LAN `wss://` pairing rehearsal with CA trust. It is a *procedure*, not an
implementation; execution happens on a real host.

## A. systemd user service install + upgrade rehearsal

### A.1 Install (PC host, user session)

1. Build daemon: `cargo build --release -p anima-daemon` → `target/release/anima-daemon`.
2. Install binary: `install -Dm755 target/release/anima-daemon ~/.local/bin/anima-daemon`.
3. Install D-Bus activation: `install -Dm644 packaging/dbus/org.moeru.airi.Daemon1.service ~/.local/share/dbus-1/services/org.moeru.airi.Daemon1.service`.
4. Install unit: `install -Dm644 packaging/systemd/airi-daemon.service ~/.config/systemd/user/anima-daemon.service`.
5. Reload: `systemctl --user daemon-reload`.
6. Enable on boot: `systemctl --user enable anima-daemon.service`.
7. Start: `systemctl --user start anima-daemon.service`.
8. Verify:
   - `systemctl --user status anima-daemon.service` → active (running), Type=dbus, BusName acquired.
   - `busctl --user status org.moeru.airi.Daemon1` → name owned.
   - `ss -ltnp | grep 6121` → listener owned by anima-daemon only.
   - D-Bus smoke: `busctl --user --json=short call org.moeru.airi.Daemon1 /org/moeru/airi/Daemon1 org.moeru.airi.Daemon1 GetGatewayConfig` returns `bound`, `lastError`, `caCertPath`, `caCertFingerprint`.

### A.2 Restart / crash recovery

1. `systemctl --user restart anima-daemon.service` → service returns; clients reconnect with bounded backoff.
2. Kill daemon process (`kill -9`) → systemd restarts within `RestartSec=2`, within `StartLimitBurst=5/60s`.
3. Exceed burst → systemd stops retrying; operator inspects `journalctl --user -u anima-daemon`.

### A.3 Upgrade rehearsal

1. Record pre-upgrade: config path, `authToken` (hash only), `tlsConfig`, CA fingerprint, audit dir contents (`ls ~/.local/share/anima-daemon/audit/`).
2. Install new binary (overwrite `~/.local/bin/anima-daemon`).
3. `systemctl --user daemon-reload` (if unit changed).
4. `systemctl --user restart anima-daemon.service`.
5. Verify post-upgrade:
   - `bound: true`, `lastError: null`.
   - Config adopted (token preserved; SAN re-mint only on drift).
   - CA fingerprint unchanged unless SANs changed.
   - `.cleared-*` archives untouched (count + checksums identical).
   - Audit active file pruned to 7-day window on startup.
6. Rollback: reinstall previous binary + `systemctl --user restart`; verify same invariants.

### A.4 Root/system boundary

- Daemon runs as **user** service only (`--user`). No root, no system unit. Root/system service boundary: explicitly decided — user session scope, D-Bus activatable, no privileged verbs beyond existing `GetGatewayConfig`/`ApplyGatewayConfig`/`RegenerateGatewayToken`.

### A.5 Termux host case

- Same procedure but binary built for `aarch64-linux-android` (Termux). No systemd; daemon runs as a foreground/termux-service process. Port 6121 bind + D-Bus over termux's session bus. CA mint + `wss://` path identical. Documented as a note; not automated.

## B. LAN wss pairing rehearsal (CA trust)

### B.1 Host setup (non-loopback bind)

1. Host machine on LAN; daemon running.
2. Apply config: `busctl --user call org.moeru.airi.Daemon1 /org/moeru/airi/Daemon1 org.moeru.airi.Daemon1 ApplyGatewayConfig` with payload `{ "hostname": "0.0.0.0" }` (or LAN IP). Non-loopback forces `wss://`.
3. Verify `GetGatewayConfig`: `hostname` non-loopback, TLS enabled, `caCertPath` present, `caCertFingerprint` (sha256 hex) present.
4. Inspect CA cert: `openssl x509 -in <caCertPath> -noout -fingerprint -sha256`.
5. Record host IP, port 6121, CA fingerprint.

### B.2 Trusted client success

1. Client (Flutter/Godot/native) obtains CA fingerprint out-of-band (QR or text from host settings UI).
2. Client installs/trusts CA into its trust store (app-private rustls `RootCertStore` or OS store per `docs/design-daemon-ca-distribution.md` §3.B).
3. Client connects `wss://<host-ip>:6121`, sends `authToken` first message.
4. Expect: TLS handshake succeeds, auth accepted, `core.status` RPC returns.
5. Record: connection log, negotiated TLS version, cipher.

### B.3 Untrusted client failure

1. Client with no CA trust (or wrong CA) connects to same endpoint.
2. Expect: TLS handshake fails (`UnknownIssuer`); client surfaces "CA mismatch", refuses to send token; no auth attempt logged as success.
3. Verify daemon audit log shows no successful auth for that attempt.

### B.4 Token handling

1. Regenerate token: `RegenerateGatewayToken` D-Bus call.
2. Old clients fail auth (close 1008); new token required.
3. Verify live connections keep prior authenticated state (documented behavior).

### B.5 CA rotation

1. `RotateCa` (audited) → new CA + leaf, `caGeneration` increments.
2. Trusted client sees TLS failure → re-run trust wizard; old vs new fingerprint shown.
3. Verify audit entry for rotation.

### B.6 CA distribution procedure (exact)

1. Host opens Settings → System → Connection → "Show CA" → displays fingerprint (hex + QR, payload `airi-ca:<host>:<port>:<sha256>`).
2. "Export CA" → native save dialog → `websocket-ca-cert.pem` (0644). Allowlist: only `CA_CERT_FILE`; key never exported.
3. Transfer PEM to client out-of-band (USB/QR/secure channel). Never over untrusted network without fingerprint verification.
4. Client verifies fingerprint matches host-displayed value before trusting.
5. Store CA in client app data dir (dir 0700, cert 0644) or OS trust store.

### B.7 libp2p peer pairing + tunnel trust (mobile remote)

1. Peer discovery yields peer ID + multiaddr; trust requires out-of-band fingerprint exchange (QR/pairing code).
2. Tunnel (Cloudflare): validates public CA for tunnel + pins host CA fingerprint for inner `wss://`.
3. Documented as scope note; not automated.

## C. Verification checklist

- [ ] systemd unit starts/enables/survives reboot (A.1).
- [ ] restart + crash recovery within burst (A.2).
- [ ] upgrade preserves token/CA/archives (A.3).
- [ ] rollback works (A.3).
- [ ] non-loopback bind forces wss (B.1).
- [ ] trusted client succeeds (B.2).
- [ ] untrusted client fails before token (B.3).
- [ ] token regeneration evicts (B.4).
- [ ] CA rotation increments generation (B.5).
- [ ] `.cleared-*` archives untouched throughout.
