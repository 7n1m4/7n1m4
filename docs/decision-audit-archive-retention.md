# Operational logging retention + audit archive

## Retention policy

| Log class | Active retention | Archive | Disposal |
|---|---|---|---|
| Daemon stdout/journal | 7 days | `.cleared-<date>.jsonl` kept forever | pruned after 7 days |
| Supervisor structured JSON | 7 days | `.cleared-<date>.jsonl` kept forever | pruned after 7 days |
| Gateway access/auth | 7 days | `.cleared-<date>.jsonl` kept forever | pruned after 7 days |
| Client-side (Flutter only) | 7 days | `.cleared-<date>.jsonl` kept forever | pruned after 7 days |

- Active logs are pruned after **7 days** (rolling).
- Archived logs (`.cleared-*` suffix) are retained **forever**; they are
  append-only and never modified or deleted by the GUI.
- Archive disposal requires privileged manual intervention only — no client
  or daemon UI path exists to delete archives.

## Audit archive location

Archives live under the daemon data dir:

```
<data-dir>/airi-slint/audit/archive/
  cleared-2026-11-21.jsonl
  cleared-2026-11-22.jsonl
```

Each archived line is a structured JSON log record with `ts_ms`, `level`,
`target`, `fields`, and `seq` (monotonic sequence from the event bus).

## Access control

- Reading archives requires the same D-Bus token as `GetGatewayConfig`.
- Deleting or modifying an archive is **not exposed** through any client,
  D-Bus method, or gateway RPC. It is a privileged filesystem operation
  performed manually by an operator with file-system access to the data dir.

## Supervisor logging

`crates/anima-supervisor/src/logging.rs` emits structured JSON to the
systemd journal via `tracing` + `tracing-subscriber` with `RUST_LOG` filter
control. The supervisor is the only process that owns the tray item; it
does not bind port 6121 and does not manage the daemon (systemd and D-Bus
activation do).

## Rehearsal checklist (§C of docs/rehearsal-systemd-lan-wss.md)

- [ ] Daemon journal rotates after 7 days without losing `.cleared-*`
- [ ] Supervisor structured JSON parses as valid JSON Lines
- [ ] Archive read requires valid D-Bus token
- [ ] No GUI/client path exists to delete archives
- [ ] `RUST_LOG` filter changes take effect on supervisor restart
