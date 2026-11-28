# Parity loop charter

## 2026-11-26

The maintainer asked for an autonomous loop: repeatedly check Rust daemon + Flutter port progress against TypeScript/Vue references, improve the largest useful gap, verify, then scan again. Work runs through Beads-owned slices and subagents; the main context coordinates, integrates, and verifies.

Scope:

- In: daemon RPC/event contracts, Flutter thin-client coverage, Vue/TS behaviour references, docs that track parity (especially `docs/feature-parity-checklist.md`), and tests that protect those seams.
- Out: TS business-logic retirement (`airi-3cp`), upstream writes, force-pushes, history rewrites, and UI reductions that would shrink the Flutter surface.

Guardrails:

1. Beads is the ledger; every improvement and follow-up gets a bead with evidence comments and is closed only after the coordinator sees passing verification output.
2. Flutter stays a full-feature renderer. Vue is a behaviour reference, not a second active renderer.
3. Check the committed baseline plus the live worktree before choosing a gap; stale review advisories are treated as untrusted.
4. Each round ends with a checkpoint comment and an updated wiki log; the loop stays open until the maintainer calls it done.

## Blocked-Surface Quarantine

A blocked slice is quarantined, not retried. Beads in `ready-for-human` state or with an expired lease are invisible to the cartographer's candidate pool in every later round. Log a blocked bead once in the quarantine ledger with its blocker ID; later rounds neither re-audit nor re-file it unless its status changes. The "largest useful gap" is the highest-impact delta among unquarantined slices — quarantine never counts as remaining progress and never terminates the loop.

## Quarantine Ledger Rule

The ledger records each blocked bead exactly once: bead ID, blocker ID, timestamp, and the state that quarantined it (`ready-for-human` or expired lease). A status change is the only event that lifts quarantine; on lift, the bead re-enters the candidate pool with a fresh evidence comment. Absence of unquarantined work sends the loop into dormant fast-path backoff (`docs/agents/hillclimb-cycle.md` §11), not into termination.

Sources: maintainer message 2026-11-26; `AGENTS.md` §0; `docs/feature-parity-checklist.md:1-16`.
