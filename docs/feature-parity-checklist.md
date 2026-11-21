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
| STMM / journal / retrieval | implemented | implemented | — | Vue reference only |
| cards + sessions | implemented | implemented | — | Vue reference only |
| heartbeat keepalive | implemented | implemented | implemented | none |
| event subscription lane | implemented | implemented | implemented | none |
| `emotion.tag` cues | consumed | consumed | consumed | none |
| `lip_sync.rms` animation | planned | planned | — | client-local envelope generation (airi-b2q) |

## How to use

When a new daemon capability lands, add a row here and mark which clients
implement it. A PR that adds a daemon capability without updating this
checklist is incomplete.

The Vue column is a **behaviour reference**, not a parity target: `—` there
is documented reference scope, not an open implementation gap. A gap entry
names the concrete follow-up bead (for example `airi-b2q` above) so the
checklist never reports green while work is outstanding.

`lip_sync.rms` is deliberately **not** daemon-published: speech capture and
playback are client-local per `docs/decision-bridge-scope.md` (authoritative).
`emotion.tag` remains daemon-published from the LLM token stream, which the
same decision leaves daemon-owned. Do not mark `lip_sync.rms` implemented
until Flutter and Godot generate envelopes locally (tracked by `airi-b2q`).

## Source of truth

Daemon capabilities live in `crates/anima-daemon/src/core.rs`
(`CoreService`) and `crates/anima-daemon/src/gateway.rs`
(`renderer_handlers`). Client implementations live in
`apps/flutter/lib/daemon_client/`, `godot/scripts/Net/`, and the Vue
reference app.
