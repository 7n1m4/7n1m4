# Hillclimb runbook — shell-and-git edition

One trigger — **Use** when a port/parity wave must run with only a shell, git, the repo's package scripts, and any ordinary subagent mechanism.

Required: shell, git, `pnpm`, `flutter`, `cargo`, and a way to dispatch read-only helpers.
This runbook is the executable contract. [hillclimb-cycle.md](./hillclimb-cycle.md) is background and history only; follow the steps here.

Scope holds port/parity slices only. Gateway trust gates and `airi-3cp` stay closed. Work stays on the current branch; pushes, rebases, and upstream writes belong to the user.

Run the steps in order. Each ends on a checkable completion criterion.

## 1. Audit

Run `git log -n 20 --oneline` and `git status --short`. Classify every candidate slice as landed, duplicate, blocked, or open. Drop landed, duplicate, and blocked slices and record the reason beside them — a commit SHA for landed, a duplicate-of slice for duplicate, a blocker note for blocked. Keep dispatch at 4–5 writers.

Done when — all 20 commits and every dirty path are accounted for, each dropped slice carries a recorded reason, every retained slice is open, and the writer count is 4–5.

## 2. Ownership matrix

Publish one matrix before dispatch: exact file paths per lane, the actual dispatched writer count, and reviewer slots. Assert pairwise path-disjointness across lanes and zero intersection with the `git status` paths. When two lanes need the same file, anchor each lane to distinct symbols inside that file instead of the file path. Record the actual count, not a template range.

Done when — the matrix lists exact paths per lane, the pairwise-disjoint assertion passes, no matrix path is dirty, shared files carry symbol anchors, the actual writer count is recorded, and the matrix is published before the first dispatch.

## 3. Lead handoff

Every lane produces a handoff ending in a trailing JSON object `{status, owned_files, dispatch, gate_check}`; plain text around it is fine. Validate `status`, that `owned_files` is a subset of the lane's matrix row, `dispatch`, and `gate_check` before authorizing writers. An invalid handoff holds its lane.

Done when — every handoff yields parseable trailing JSON, all four fields validate against the matrix, and each lane's writers started only after its handoff passed.

## 4. RED first

Before implementation, capture the failing scoped command and its verbatim output. Pick a check whose failure proves the slice is missing. An assertion that fails for an unrelated reason fails this step.

Done when — the log shows the red command and its verbatim output dated before the first green, a final green run is recorded, and the failure is discriminating for the slice.

## 5. Wave-0 gate

Run the scoped formatter, lint, test, and drift commands in the checklist below. Every command exits 0 before review starts. Self-fix at most twice; on a third failure, block the lane and record the blocker in the ledger.

Done when — every scoped command exited 0 before review began, blockers after two self-fixes are recorded, and no lane entered review on a red gate.

## 6. Review

Match reviewer count to change risk: one for mechanical, two for behavioral, four for cross-boundary. Treat `Must` as blocking until fixed and re-reviewed; apply `Should` silently. Drive `Must` to zero at integration.

Done when — the reviewer count matches the risk tier, every `Must` has a fix plus a focused re-review, zero `Must` remain at integration, and every `Should` is applied.

## 7. Verification

Run the full test set in parallel or in the background, and run `gate_check` concurrently with review. Commit requires the gate to exit 0 and the `Must` count to be zero.

Done when — all parallel test runs finished green, the gate exited 0, the `Must` count is zero, and the commit gate is satisfied.

## 8. Commit

Stage explicitly with `git add -- <paths>` taken from the lane's matrix row. Verify with `git diff --cached --name-only`. Leave the index clean after the commit. Use paths only; wildcards are outside this step.

Done when — the staged name list equals the lane's matrix row, the index is clean after the commit, and no wildcard appeared in any `git add`.

## 9. Retro

Use a detached worker when the subagent mechanism supports one; otherwise write a 10-minute manual note with full round evidence. Produce 2–4 prioritized improvements, a ranked worker note, and carry the deltas into the next round's brief.

Done when — the retro note holds the round evidence and 2–4 ranked improvements, the worker ranking is recorded, and the deltas appear in the next brief.

## 10. Chain or stop

Stop when zero open slices remain, the final parity audit is clean, and the full workspace is green. Also stop on two consecutive generations with no new slices: emit `PARITY_COMPLETE_OR_BLOCKED`. Otherwise re-run this loop manually with the next brief.

Done when — the stop predicates are evaluated and either the wave is closed with `PARITY_COMPLETE_OR_BLOCKED` emitted, or a new brief starts a fresh manual pass.

## Shell checklist

Curated gate commands across four toolchains. Run from the repo root; a Flutter `cd` is shown where needed. Every line must exit 0.

```sh
# Format + lint
pnpm test:nano-staged-scope
pnpm exec eslint --no-warn-ignored scripts/tests/<touched>.mjs
cargo fmt -p anima-core -p anima-daemon -p anima-channel --check
(cd apps/flutter && flutter analyze lib/<touched>.dart)

# Tests
cargo test --workspace --locked -- --test-threads=1
(cd apps/flutter && flutter test test/<file>_test.dart)
node --test scripts/tests/audit-packet.test.mjs

# Drift + guards
pnpm check:wire-types
cargo run -p anima-channel --example export-golden-fixtures -- --check
node scripts/tests/audit-doc-citations.mjs --all-docs
node scripts/tests/flutter_boundary_graph.mjs
node scripts/sm.mjs audit
node scripts/tests/audit-packet.mjs
```

## State ledger without Beads

Append evidence to `state/events.ndjson`, `state/SUMMARY.md`, and `.waves/<wave>/*.receipt.json`. Treat hash-chained events as append-only; regenerate them with `node scripts/bootstrap-state.mjs` (`--dry-run` previews) rather than editing them by hand. When those files are unavailable, a plain text log under `/tmp` carries the same evidence and is acceptable.

Done when — each step's evidence is in one of those ledgers, and hash-chained events were appended or regenerated rather than hand-edited.
