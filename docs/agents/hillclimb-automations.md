# Hillclimb automation briefs (sequential lanes)

The two port lanes run **one at a time**. Exactly one automation is active; when its
round finishes it creates the *other* lane's automation with a 5-minute gap, then
stops. Never create a duplicate of a lane that is already active. Do not edit the
briefs here casually: they are read verbatim by the chaining automation.

Both lanes must follow repo `AGENTS.md`: `bd where`, load `bd-drive`, use
`bd --sandbox` for tracker writes (no `bd sync`), and keep file ownership disjoint
from the other lane. Canonical parity doc: `docs/feature-parity-checklist.md`.
Gateway trust gates and `airi-3cp` are DO NOT START.

Chaining (both lanes): if the checklist shows no remaining gaps for your lane,
report completion and stop. Otherwise call `tools.automation.list`; if no ACTIVE
automation of the other lane exists, call `tools.automation.create` with the
other lane's brief from this file, name as below, and trigger
`{ type: 'at', at: 'in 5 minutes' }`. Never create a second automation for your
own lane.

## `ts-rust-frontend-port-hillclimb` brief

Run one round of the TS → Rust frontend-logic port hillclimb for AnimA. The
Vue → Flutter parity lane is the other lane; it runs sequentially, not in
parallel, so do not assume its changes or touch its files.

Context: `apps/stage-tamagotchi` (Electrobun/TS) and `apps/stage-web` +
`packages/stage-ui` (Vue) are behavior references for the full-feature web
edition; `crates/anima-daemon` is the single source of truth for state and
business logic; `apps/flutter` is the sole active renderer. Canonical docs:
`docs/feature-parity-checklist.md`, `docs/rosetta-stone.md`,
`docs/design-daemon-gateway.md`, `docs/data-catalog.md`.

OUR lane scope: port frontend logic out of TypeScript (stage-tamagotchi, plus
the Vue web reference where needed) and from server apps into Rust. Business
logic/state goes into the Rust daemon (thin-client rule: no competing state
writer); renderer logic goes into Flutter. Skip anything claimed by the
Vue → Flutter lane in Beads.

1. Evaluate: drive from the ready Beads frontier filed by earlier rounds
   (`discovered-from:airi-ba9w`); fan out read-only researchers only for
   unfiled areas. Each reports file:line evidence and a port checklist.
2. Analyze: main thread dedupes, drops anything owned by the other lane, ranks
   by user impact, files gaps as Beads with `discovered-from` links and the
   relevant `--skills`; append unresolved constraints with `bd --sandbox update
   <id> --append-notes`.
3. Implement: dispatch parallel implementers with disjoint file ownership.
   Each runs its scoped checks (`cargo test --workspace --locked` for Rust,
   `pnpm -F <workspace> typecheck` for TS/web, flutter analyze/test for
   Flutter), updates the parity checklist, and closes its bead with evidence
   via `bd --sandbox close <id> --reason`. The main thread owns tracker state.
4. Parallel code review: spawn 2–3 read-only reviewers with disjoint scopes
   (`ponytail-review` + `code-review`) over correctness, trust gates, data
   loss/exposure, load, tests, and parity-doc accuracy. Fix every Must/Should
   with a disjoint-owner implementer and re-run `cargo test --workspace
   --locked` plus any relevant typecheck/flutter test before proceeding.
5. Scoped commit: commit ONLY this lane's changes. Use `git add -- <explicit
   paths>` derived from `git status --short`; never `git add -A`, `git add .`,
   wildcards, or files owned by the other lane. Show `git status --short` and
   `git diff --cached --name-only` before committing. No push.

Finish: use the shared chaining rule above (create the Vue → Flutter automation
with its brief from this file).

## `vue-flutter-port-hillclimb` brief

Run one round of the Vue → Flutter frontend-logic port hillclimb for AnimA. The
TS → Rust lane is the other lane; it runs sequentially, not in parallel, so do
not assume its changes or touch its files.

Context: `apps/stage-tamagotchi` (Electrobun) and `apps/stage-web` (Vue) are
behavior references; `apps/flutter` is the sole active renderer and is behind
on frontend logic. Canonical parity tracker: `docs/feature-parity-checklist.md`
(Flutter rows). Concept-to-code map: `docs/rosetta-stone.md`.

1. Evaluate: spawn 4–6 scoped read-only researchers with disjoint slices
   (chat/composer + transcript actions, stage UI/control strip, speech/captions
   + audio, provider settings UI, memory UI pages, onboarding). Each reports
   concrete missing Flutter logic versus the Vue references with file:line refs
   and a port checklist. Do not edit files in this step.
2. Analyze: main thread dedupes and ranks by user impact; files gaps as Beads
   with `discovered-from` links and the relevant `--skills`.
3. Implement: dispatch implementation subagents with disjoint file ownership.
   Each runs scoped checks (`flutter analyze/test`, `cargo test --workspace
   --locked` where Rust is touched, `pnpm -F <workspace> typecheck` for Vue
   reference changes), updates the parity checklist, closes finished beads via
   `bd --sandbox close <id> --reason`. Verify diffs before integration; the
   main thread owns tracker state.
4. If this lane commits, use `git add -- <explicit paths>` only; never
   `git add -A`/`.`/wildcards and never files owned by the other lane. No push.

Finish: use the shared chaining rule above (create the TS → Rust automation
with its brief from this file).
