# Hillclimb cycle

One wave = one port/parity push. Steps run in order; the coordinator owns the wave.

Hard boundaries: obey AGENTS.md. `AGENTS.md` and harness docs (`docs/agents/**`) are coordinator-owned only (never assigned to lane writers) and may be edited mid-wave only after a pre-edit Google AI Mode Senior Architect consult in a fresh thread (never reuse a thread), logged with `[ARCH-CONSULT-NEW-THREAD]` and the verbatim resolution on the active wave bead and carried into the successor brief.

## 1. Cartographer audit
A single cartographer reviews closed beads and the last 20 commits inside ~30 seconds. Classify each candidate slice as landed, duplicate, or open. Drop landed and duplicate slices, recording the reason (bead ID plus commit or duplicate-of ID) where the matrix will read it.

Done when — every closed bead in scope and all 20 commits are accounted for, each dropped slice carries a recorded reason, and every retained slice is open and ready to be assigned in step 2.

## 2. Ownership matrix
The coordinator publishes one ownership matrix: exact file paths per lane, the actual dispatched lane count, and 100 slots allocated across scouts, lane leads, and reviewers. Writers cap at 4–5. Assert pairwise path-disjointness across lanes and zero intersection with current `git status` paths. Publish before any dispatch.

Done when — the matrix lists exact paths for every lane, the actual writer count is 4–5, all 100 slots are allocated, the pairwise-disjoint assertion passes, no matrix path appears in `git status`, and the matrix is published before the first agent dispatch.

## 3. Wave-0 schema freeze
Before any consumer writes, freeze the wave's shared schema behind a four-check mechanical gate: regenerate the TS bindings and golden fixtures with a clean diff; run the golden JSON round-trip test; assert every consumer typechecks and its fixtures match; scan ownership so no path falls outside the matrix. Each check passes on command output, not on written acknowledgment.

Done when — all four checks pass (clean regeneration diff, round-trip green, every consumer typecheck/fixture assertion green, ownership scan clean) and no consumer wrote against an unfrozen or drifted schema.

## 4. Lead handoff
Dispatch read-only lane-lead agents. Each lead handoff ends with a trailing JSON object `{status, owned_files, dispatch, gate_check}`. The coordinator validates `status`, that `owned_files` is a subset of that lane's matrix row, `dispatch`, and `gate_check` before authorizing that lane's writers. Missing or invalid JSON blocks that lane's dispatch.

Done when — every lead returned parseable trailing JSON, every field validated against the matrix, and each lane's writers were dispatched only after its handoff passed; no writer started on an unvalidated handoff.

## 5. Red first
Every implementer writes red first: capture the failing scoped check command and its output, then drive to green. A TS port additionally adds a 500+ case oracle and a mutation proof — mutate the implementation, confirm the oracle fails, restore.

Done when — each implementer's log shows the captured red command and output before the first green and a final green run, and every TS port shows a 500+ case oracle result plus a mutation-proof result.

## 6. Review batch
Fire 4–5 specialized read-only reviewers PER LANE, fired simultaneously in one batch, never staggered. Every lane covers four lenses: Safety/data-loss (mandatory), contract/wire parity, concurrency/state-machine, and test-quality/RED proof. Triage into Must and Should: every Must gets a fix and a focused re-review, and Must count reaches zero at integration. A Must claiming TS parity must cite one discriminating input verified against the reference. Apply Shoulds silently; they never block.

Done when — each lane dispatched 4–5 specialized read-only reviewers in one simultaneous batch, all four lenses were covered per lane, every Must has a fix plus a focused re-review with zero Must outstanding at integration, every TS-parity Must carries a reference-verified discriminating input, and every Should is applied.

## 7. Gate and commit
Run `gate_check` in the background, in parallel with the review batch. Commit only when `gate_check` exits 0 and Must count is zero. Stage explicitly with `git add -- <paths>` derived from the lane's matrix row, then verify staged names.

Done when — `gate_check` ran concurrently with review and exited 0, zero Must remained, the commit used explicit `git add -- <paths>`, and `git diff --cached --name-only` matches the lane's matrix row exactly.

## 8. Retro
Run a mandatory retro with Google AI Mode as senior team lead. Present full round evidence and require a candid assessment, 2–4 prioritized changes, and at least two probing follow-ups with answers. Post a verbatim dated comment on the wave bead. File accepted changes as beads and write the deltas into the successor brief.

Done when — the retro contains full round evidence; the assessment names at least one concrete round weakness or failure with evidence; 2–4 prioritized changes and at least two answered probing follow-ups are recorded; a verbatim dated bead comment exists; each accepted change is a bead; and the successor brief carries the deltas.

## 9. Architecture checkup
Run a mandatory architecture checkup in a NEW Google AI Mode tab/thread, distinct from the retro thread; never continue or reuse the retro thread. Feed it repo basics: the Rust daemon owns authoritative state; Flutter is the sole thin renderer with no competing state writer; Vue and Electrobun are reference-only; `anima-channel` is the specta-exported wire contract; the DO NOT START zones declared in AGENTS.md (gateway trust gates, `airi-3cp`); Beads is the ledger. Add this wave's landed symbols, changed paths, and open follow-ups. Ask it to act as SENIOR ARCHITECT and hunt structural drift and classic vibe-coded failure modes: competing state writers, schema drift, duplication/sediment, unowned state, persistence-boundary mistakes, test-parity gaps. Require at least two probing follow-ups; extract each answer only after the processing marker clears. Record a verbatim dated comment on the round bead, file accepted items as beads with the right `--skills`, and carry architectural deltas into the successor brief. If no browser connects, record the blocker on the round bead and continue.

Done when — the checkup comment is on the round bead and any accepted items are filed as beads with their `--skills`, with architectural deltas in the successor brief; or, when no browser connects, the blocker is recorded on the round bead.

## 10. Chain
Chain only after the architecture checkup closes. Keep the chain single-flight: call `automation.list`, then create at most one successor with `automation.create` — no `to` field, trigger `{ type: 'at', at: 'in 10 seconds' }`. Never duplicate an active automation.

Done when — the architecture checkup is closed, exactly one successor automation exists, it has no `to`, it uses `at: in 10 seconds`, and no active lane is duplicated.

## 11. Termination
Close the wave when zero open port beads remain in the lane, the final parity audit is clean, and the full workspace is green. If two consecutive generations produce no new slices, emit `PARITY_COMPLETE_OR_BLOCKED` and stop. Chaining happens only after the architecture checkup.

Done when — all three predicates hold and the wave is closed, or two consecutive empty generations produced `PARITY_COMPLETE_OR_BLOCKED` and the chain stopped after the architecture checkup.
