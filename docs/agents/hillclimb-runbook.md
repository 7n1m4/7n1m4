# Hillclimb runbook — shell-and-git edition

One trigger — **Use** when a port/parity wave must run with only a shell, git, the repo's package scripts, and any ordinary subagent mechanism.

Required: shell, git, `pnpm`, `flutter`, `cargo`, and a way to dispatch read-only helpers.
This runbook is the shell execution checklist. [hillclimb-cycle.md](./hillclimb-cycle.md) remains the wave contract: its Step 3 (Wave-0 schema freeze) and Step 9 (Architecture checkup) are mandatory coordinator steps, and §5 below is the shell subset of Step 3 — not a separate gate. Follow the steps here.

Scope holds port/parity slices only. Gateway trust gates and `airi-3cp` stay closed. Work stays on the current branch; pushes, rebases, and upstream writes belong to the user.

Mid-wave edits to `AGENTS.md` or `docs/agents/**` are coordinator-owned only and require the pre-edit Senior Architect consult gate defined in `hillclimb-cycle.md` (`Hard boundaries`).

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

Run two tiers of checks from the checklist below before review starts.

- **Tier 1 — Strict Scoped Gates (blocking):** every applicable command must exit 0 on the touched path set. Skip a command when its input type was not touched; run scoped variants (`cargo test -p <touched_crate>`, `node --test <touched>.test.mjs`) rather than workspace-wide ones. Self-fix at most twice; on a third failure, block the lane and record the blocker in the ledger.
- **Tier 2 — Repo-Wide Health Audits (informational):** run once per wave at wave end for visibility (`flutter analyze lib`, `audit-doc-citations.mjs --all-docs`). Compare against the previous wave's recorded count in the active Beads ledger, record this wave's count with `bd --sandbox update <id> --append-notes ...`, and block only if the count increases above that baseline. On the first wave, record the baseline without blocking.

Done when — all applicable Tier 1 commands exited 0 before review began, every skipped Tier 1 command carries a matrix-backed reason in the active Beads ledger note (or the fallback receipt when `bd` is unavailable), any lane failing a Tier 1 command after two self-fixes is blocked in the ledger, each Tier 2 audit has a prior-wave baseline plus this wave's recorded count, and zero Tier 2 audits regressed above baseline.

## 6. Review

Match reviewer count to change risk: one for mechanical, two for behavioral, four for cross-boundary. Treat `Must` as blocking until fixed and re-reviewed; apply `Should` silently. Drive `Must` to zero at integration.

Done when — the reviewer count matches the risk tier, every `Must` has a fix plus a focused re-review, zero `Must` remain at integration, and every `Should` is applied.

## 7. Verification

Run the full test set in parallel or in the background — including `cargo test --workspace --locked -- --test-threads=1` — and run `gate_check` concurrently with review. Keep workspace-wide tests here so §5 stays fast and scoped. Commit requires the gate to exit 0 and the `Must` count to be zero.

Done when — all parallel test runs finished green, the gate exited 0, the `Must` count is zero, and the commit gate is satisfied.

## 8. Commit

Stage explicitly with `git add -- <paths>` taken from the lane's matrix row. Verify with `git diff --cached --name-only`. Leave the index clean after the commit. Use paths only; wildcards are outside this step.

Done when — the staged name list equals the lane's matrix row, the index is clean after the commit, and no wildcard appeared in any `git add`.

## 9. Retro

Use a detached worker when the subagent mechanism supports one; otherwise write a 10-minute manual note with full round evidence. Produce 2–4 prioritized improvements, a ranked worker note, and carry the deltas into the next round's brief.

Done when — the retro note holds the round evidence and 2–4 ranked improvements, the worker ranking is recorded, and the deltas appear in the next brief.

## 10. Chain or Dormant Backoff

Chain unconditionally at the end of every wave; empty generations do not stop the loop. Two states:

- **Active wave:** open slices remain — chain the next pass with trigger `{ type: 'at', at: 'in 10 seconds' }`.
- **Dormant fast-path:** zero open slices remain — chain with a `PARITY_DORMANT_POLL` backoff of 4 hours. Any new open bead resets the cadence to 10 seconds.

Keep the chain single-flight: call `automation.list`, then create at most one successor with `automation.create` and no `to` field. Never duplicate an active automation. Blocked surfaces are quarantined in the ledger rather than ending the loop.

Done when — exactly one successor automation exists with no `to`, its trigger is 10 seconds while any open slice exists and `PARITY_DORMANT_POLL` (4h) when none exist, any newly opened bead restored 10 seconds, and no active lane is duplicated.

## Shell checklist

Curated gate commands across four toolchains. Run from the repo root; a Flutter `cd` is shown where needed. Skip any Tier 1 command whose input type was not touched.

```sh
# Tier 1: Strict Scoped Gates — every applicable line must exit 0 before review
pnpm test:nano-staged-scope
pnpm exec eslint --no-warn-ignored scripts/tests/<touched>.mjs          # skip if no .mjs touched
cargo fmt -p anima-core -p anima-daemon -p anima-channel --check
(cd apps/flutter && flutter analyze lib/<touched>.dart)                 # skip if no lib/**.dart touched
(cd apps/flutter && flutter test test/<touched>_test.dart)              # skip if no .dart touched
cargo test -p <touched_crate> --locked                                  # workspace-wide tests belong in §7
node --test scripts/tests/<touched>.test.mjs                            # skip if no .mjs test touched
pnpm check:wire-types
cargo run -p anima-channel --example export-golden-fixtures -- --check
node scripts/tests/audit-doc-citations.mjs <touched>.md                 # NO --all-docs here
node scripts/tests/flutter_boundary_graph.mjs
node scripts/sm.mjs audit
node scripts/tests/audit-packet.mjs

# Tier 2: Repo-Wide Health Audits — compare to prior-wave count; record this wave's count; block only on increase
(cd apps/flutter && flutter analyze lib)
node scripts/tests/audit-doc-citations.mjs --all-docs
```

## State ledger

Beads (`bd --sandbox`, no `bd sync`) is the canonical mission ledger per `AGENTS.md` §10. Use `state/events.ndjson`, `state/SUMMARY.md`, and `.waves/<wave>/*.receipt.json` **only when `bd` is unavailable** in the environment, and never split the same wave's evidence across both ledgers.

In the fallback ledger, append evidence to those files. Treat hash-chained events as append-only; regenerate them with `node scripts/bootstrap-state.mjs` (`--dry-run` previews) rather than editing them by hand. When those files are unavailable, a plain text log under `/tmp` carries the same evidence and is acceptable.

Done when — each step's evidence is in exactly one ledger, and hash-chained events were appended or regenerated rather than hand-edited.
