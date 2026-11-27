# Round 17 coordinator boot

Beads is **PAUSED**. `state/` is the source of truth; the four pinned guards are read-only inputs that are never owned by a lane.

Boot and verify (every command must exit `0`):

```text
node scripts/bootstrap-state.mjs --dry-run && node scripts/sm.mjs recover && node scripts/sm.mjs audit && node scripts/tests/audit-packet.mjs && node --test scripts/tests/audit-packet.test.mjs
```

After a lane commit advances HEAD, record it explicitly, then rerun the verification command above:

```text
node scripts/sm.mjs head:advance --sha <new-head-sha>
```

The genesis base `38613b6e` is immutable. Details, evidence, invariants, receipts, guard pins and reconciliation status live in [`state/SUMMARY.md`](../state/SUMMARY.md). The authoritative command set, exit codes and validation logic live in [`scripts/sm.mjs`](../scripts/sm.mjs) (`node scripts/sm.mjs --help`); packet validation lives in [`scripts/tests/audit-packet.mjs`](../scripts/tests/audit-packet.mjs).
