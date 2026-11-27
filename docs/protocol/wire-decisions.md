# Wire Decisions (RATIFIED)

Status: **RATIFIED** — 2026-11-27
Bead refs: `airi-6anh` (decision), `airi-f7of` (daemon-authoritative StreamCursor)
Lane: L1 Wire & Transport

These decisions freeze the top-level WS frame discriminators and mandatory
correlation IDs. No new verbs, no handshake/trust-gate frames are introduced.

## D1 — Gap-recovery authority: DAEMON-AUTHORITATIVE

**Decision:** The daemon owns `seq`/`epoch`. The client never repairs gaps
locally. On a detected gap the client wipes its local buffer and requests a
full snapshot/resubscribe (`requestResync` local full-resubscribe only for now,
stub).

**Rationale:** A single authority prevents divergent buffer state across
clients and avoids partial rendering. The daemon is the source of truth for
ordering; clients are stateless consumers that resync on any discontinuity.

## D2 — Cursor reset / epoch semantics

**Decision:** `epoch: u64`, increments on server restart / session reset
(daemon process restart or new chat session). `seq: u64`, strictly monotonic
`+1` within an epoch. Any epoch mismatch (client epoch != server epoch) =>
wipe local buffer + full snapshot. seq regression within same epoch => gap.
seq jumps > 1 => gap.

**Rationale:** Epoch bumps make process/session resets unambiguous; strictly
monotonic seqs make gap detection a simple comparison. Wiping on epoch
mismatch guarantees no stale data survives a reset.

## D3 — Terminal unrecoverable-gap policy

**Decision:** If a gap cannot be recovered within the bounded buffer (missing
seqs exceed client ring buffer capacity), the client MUST drop the local buffer
and request a full snapshot; never render partial. Terminal signal
(`AssistantDone` / turn complete) drops any unresolved gap indicator. No silent
partial rendering.

**Rationale:** Partial rendering of incomplete streams is worse than a brief
gap; forcing a full resync preserves correctness. Terminal signals clear
transient gap state so completed turns don't carry stale indicators.

## Schema

`StreamCursor { epoch: u64, seq: u64 }` is added as an `Option` field named
`cursor` with `serde(default, skip_serializing_if = "Option::is_none")` on the
existing outbound snapshot/delta envelopes (`ChatDelta`, `ChatMessage`) only.
Additive change; no breaking wire change.
" path="/home/vi/Code/AnimA/docs/protocol/wire-decisions.md