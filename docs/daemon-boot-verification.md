# Daemon Boot Verification (2026-11-21)

## Boot sequence (anima-daemon --foreground)

1. Parse args; default mode `Run` → `run(gateway_enabled=true)`.
2. Open audit log at `$XDG_DATA_HOME/airi-slint/audit/awareness-audit.jsonl`; prune entries older than 7 days.
3. Connect to session bus; request name `org.moeru.airi.Daemon1` (exit 1 on failure).
4. Connect to system bus (optional; degrades honestly when absent).
5. Init awareness, wake facts, ring, a11y client, exclusions.
6. Install match rules for 6 T0 sources + optional screen source.
7. Print sources armed/unavailable.
8. `CoreService::open(None)`; print available.
9. `Gateway::start_with_core(None, None, core)` binds `127.0.0.1:6121` (TLS false by default).
10. Enter awareness loop; gateway bind recovered if port was busy at startup.

## Verified

- Command: `cargo run -q -p anima-daemon -- --foreground`
- Output: `gateway listening on 127.0.0.1:6121 (TLS: false)`
- Port check: `ss -lntp` → `LISTEN 127.0.0.1:6121 users:(("anima-daemon",pid=...,fd=9))`
- D-Bus check: `busctl --user --json=short call org.moeru.airi.Daemon1 /org/moeru/airi/Daemon1 org.moeru.airi.Daemon1 GetStatus` → reply with sources all true, session_bus/system_bus true, protocol 1.
- Shutdown: `kill <pid>` releases port 6121 and D-Bus name.

## Notes

- Gateway port override via `SERVER_CHANNEL_PORT`.
- D-Bus name ownership is exclusive; a second instance exits 1.
