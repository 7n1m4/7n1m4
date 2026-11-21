# Feature-parity checklist

Maps each daemon capability to client implementation status across
Flutter, Godot, and the Vue reference. A blank cell = not implemented.

| Capability | Flutter | Godot | Vue reference | Parity gap |
|---|---|---|---|---|
| `core.status` health probe | implemented | implemented | implemented | none |
| `chat.send` / chat sessions | implemented | implemented | implemented | none |
| chat streaming deltas | implemented | implemented | implemented | none |
| `chat.cancel` / stop-generation | implemented | implemented | implemented | none |
| settings get/set | implemented | implemented | implemented | none |
| providers list | implemented | implemented | implemented | none |
| vault status | implemented | implemented | implemented | none |
| STMM / journal / retrieval | planned | — | — | Godot/Vue |
| cards + sessions | planned | — | — | Godot/Vue |
| heartbeat keepalive | implemented | implemented | implemented | none |
| event subscription lane | implemented | implemented | implemented | none |

## How to use

When a new daemon capability lands, add a row here and mark which clients
implement it. A PR that adds a daemon capability without updating this
checklist is incomplete.

## Source of truth

Daemon capabilities live in `crates/anima-daemon/src/core.rs`
(`CoreService`) and `crates/anima-daemon/src/gateway.rs`
(`renderer_handlers`). Client implementations live in
`apps/flutter/lib/daemon_client/`, `godot/scripts/Net/`, and the Vue
reference app.
