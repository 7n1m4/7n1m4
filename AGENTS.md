# Agent Operating Guidelines

## 0. The Pivot: What This Repo Is Becoming (read first, verify before citing)

Anima is no longer "a desktop pet app". It is pivoting to the **agent-runtime core of a personal agentic OS**: one long-lived Rust daemon/backend owns state and business logic as the single source of truth. Flutter (`apps/flutter`) is the primary and sole active renderer on desktop and mobile, with native character/model rendering and full Vue stage-UI parity. Vue web and Electrobun desktop are behavior references while parity is incomplete. Godot was purged 2026-11-25. "Thin client" means no competing state writer — never a reduced feature surface.

- **Renderer parity rule:** a capability landed in the daemon is tracked in [`docs/feature-parity-checklist.md`](./docs/feature-parity-checklist.md) for Flutter; Vue rows are reference only; Godot is no longer a parity target. Retiring TypeScript **business logic** (the gated opt-in TS remote-sync slice, `airi-3cp`) is a separate, still-blocked scope; it does **not** retire the Vue renderer. Keep all gateway trust gates and `airi-3cp` DO NOT START unless the user explicitly says otherwise.
- **Architecture:** `crates/anima-daemon` hosts the WS/wss gateway (port 6121, loopback by default; `wss://` + a locally minted CA beyond loopback). `crates/anima-channel` defines the Rust-canonical wire protocol and the D-Bus control surface (`GetGatewayConfig` / `ApplyGatewayConfig` / `RegenerateGatewayToken` on `org.moeru.airi.Daemon1`); specta exports those types to TypeScript (drift-checked in CI). `apps/stage-tamagotchi` is Electrobun (not Electron).
- **Thin-client rule:** when the daemon answers on the session bus, clients bind nothing on 6121 — no token mint, no WS server. The app talks to the daemon via `busctl --user --json=short` (see `apps/stage-tamagotchi/src/main/services/airi/daemon-gateway.ts`). If the daemon does not answer, the app falls back to its in-app path (macOS/Windows remain functional until the daemon ports).
- **Canonical docs:** [`docs/design-daemon-gateway.md`](./docs/design-daemon-gateway.md) (design + invariants + threat model), [`docs/design-flutter-godot-pivot.md`](./docs/design-flutter-godot-pivot.md) (Flutter-first client contract; historical filename), [`docs/feature-parity-checklist.md`](./docs/feature-parity-checklist.md) (per-capability renderer status), [`docs/README.md`](./docs/README.md) (architecture overview), [`docs/rosetta-stone.md`](./docs/rosetta-stone.md) (concept → code map), [`docs/data-catalog.md`](./docs/data-catalog.md) (persisted keys), [`docs/proposal-unified-rust-native-app.md`](./docs/proposal-unified-rust-native-app.md) (historical/superseded, not current mobile direction; the Capacitor stage-pocket is purged). Godot purge tracked in Beads. [`README.md`](./README.md) carries the under-construction notice: this is a work-in-progress mid-pivot, not a daily driver.
- **Verify, don't believe:** `cargo test --workspace --locked`, the wire-types drift check, `pnpm -F @proj-anima/stage-ui typecheck`. Tamagotchi `typecheck:node` is env-red for pre-existing reasons; check whether changed files appear in the errors instead.
- Mid-pivot state (merged increments, pending work, branch state) belongs in the tracker and the docs above, not in this file — check the tree and those docs before citing them from memory.

## 0.5 User-Authorized Autonomy and Experimental Main

- **Repository autonomy policy (user-authorized):** `main` is an experimental line of development, not a stable release surface. The user grants broad advance approval for ordinary, in-scope changes, including work directly on `main`; do not treat publication of `main` as requiring fresh approval for every routine edit.
- **Efficiency policy:** prefer bounded, high-parallelism subagents for independent tasks with disjoint ownership. The parent agent remains responsible for preventing overlapping edits, reviewing results, running validation, and integrating the changes.
- **Experimental does not mean unverified:** run the scoped checks that match the change before handing off or publishing. Main being experimental is not permission to push known-broken work or bypass tests.
- **Still restricted:** force-pushes, history rewrites, deletion of user work, upstream writes, secret exposure, and other destructive or irreversible actions require explicit, current authorization.

## 1. Domain Skills and Project Context

- **Start by identifying relevant domain skills.** At the beginning of a task, review the user's request and consult `.agents/skills/` and [`docs/project-specialized-skills.md`](./docs/project-specialized-skills.md) to identify the most relevant guidance. Read the associated `SKILL.md` files and useful references before substantial codebase exploration or implementation.
- Scale the depth of preparation to the task. For a trivial documentation edit, a short targeted review may be sufficient. For unfamiliar subsystems, architectural changes, or complex debugging, perform a more thorough review.
- Before broad architecture exploration or cross-cutting changes, consult the relevant section of [`docs/rosetta-stone.md`](./docs/rosetta-stone.md). It maps concepts to canonical code locations and documents known failure modes. If current source code contradicts the documentation, trust the source and update the documentation when the discrepancy reveals a durable lesson or changes a canonical entry point.
- Consult [`docs/data-catalog.md`](./docs/data-catalog.md) before adding, renaming, or changing persisted storage keys, including IndexedDB `local:*`/`outbox:*`, localforage assets, and localStorage settings. Update the catalog when the change affects its documented inventory.
- Consult [`docs/project-testing-parity.md`](./docs/project-testing-parity.md) before broad architectural changes, investigating apparent test gaps, or adding tests that might duplicate existing coverage. Run `node scripts/audit-test-catalog.mjs` when the catalog's integrity needs verification.
- Keep [`docs/project-specialized-skills.md`](./docs/project-specialized-skills.md) synchronized with the skills directory when adding or materially reorganizing domain skills.

## 2. Git Status and Change Awareness

- Keep track of the repository's state throughout the task. Run `git status` after each commit and after modifications that materially affect the working tree, particularly before handoff or any operation that depends on a clean or understood state.
- Report relevant remaining changes at handoff, distinguishing changes made for the task from pre-existing modifications. Include unstaged, staged, untracked, and otherwise pending files when they matter to the user's next decision.
- Do not assume that unrelated modifications are safe to ignore. Preserve work that is outside the current scope and avoid including it in a commit without authorization.

## 3. Pair Programming and User Intent

- Work collaboratively. Keep the user's stated goal, constraints, and preferences central to the implementation.
- Requests to explore, review, diagnose, research, design, plan, or discuss an idea generally authorize investigation and recommendations, not application-code changes. Explain the findings, root cause, proposed solution, and material tradeoffs before implementing a change that has not been requested.
- If the user asks for a design document, confine changes to that document unless implementation is also requested.
- For clearly specified, low-risk changes, proceed without unnecessary confirmation.
- For material product, behavior, data-model, or architectural decisions, explain the important decision and preferred approach first when the user could reasonably want to choose differently. Avoid turning routine implementation details into approval checkpoints.
- Ask questions when essential information is missing or when proceeding would risk an irreversible action, cross-project boundary violation, or significant unintended change. Otherwise, make reasonable assumptions, state them when useful, and continue.

## 4. Technical Accuracy and Evidence

- Prioritize source code, reproducible behavior, authoritative documentation, and empirical logs over assumptions or agreement for its own sake.
- When a user's technical premise appears inconsistent with the evidence, explain the discrepancy respectfully and directly. Identify the relevant files, code paths, documentation, or logs and show why they support a different conclusion.
- Distinguish verified facts from hypotheses and recommendations. If evidence is incomplete, explain the uncertainty and identify the smallest useful investigation or test that could resolve it.
- Do not silently accept an incorrect premise if doing so would lead to a defective implementation. Equally, do not overstate certainty when the available evidence does not establish a definitive answer.

## 5. Workspace and Repository Boundaries

- Keep repository exploration, searches, edits, and shell commands within the active project's designated workspace by default.
- If a request appears to concern a different repository or application, check whether the relevant project is actually available in the current workspace. Do not probe parent or sibling directories or assume authority over an unrelated project.
- If work in another repository is genuinely necessary, ask the user to identify or authorize the intended workspace before crossing that boundary.
- Avoid broad formatting, cleanup, or unrelated refactoring. Prefer the smallest coherent diff that solves the requested problem.
- Upstream (`dasilva333/airi`) MAY be inspected, fetched, and compared against for mergeability and upstream alignment (read-only reference operations: `git fetch upstream`, `git show upstream/<branch>:<path>`, `gh` API reads, `git diff upstream/main...HEAD` for review). Never push to, rebase onto, or merge from `upstream` without explicit current user authorization — those remain write/history operations, not reference reads.
- `crates/` is the Rust runtime core (`anima-daemon` hosts the WS/wss gateway, `anima-channel` the wire protocol); the maintained renderer is `apps/flutter` on desktop and mobile; `apps/stage-web` (Vue web UI) and `apps/stage-tamagotchi` (Electrobun desktop, not Electron) are behavior references.

## 6. Git, Commits, and Releases

- Treat the `main` branch and published remote as release surfaces, since community users may consume published commits.
- Before a requested commit or push, inspect the full `git status` and review the complete intended diff. Separate pre-existing changes from task-related changes and preserve unrelated work.
- Validate the complete intended change before publishing. Never push known-untested changes or bypass required checks after a failure. If a meaningful TypeScript, Vue, or build-automation JavaScript change is involved, run the relevant workspace typecheck or build first.
- If validation fails, report the failure and its implications. Do not publish the affected change unless the issue has been resolved or the user explicitly requests a different, permissible local-only workflow.
- If the user requests a clean working tree, account for all pending paths, including unrelated work. Do not claim the tree is clean until the actual status supports that conclusion.
- Before handing off a tested but uncommitted checkpoint, summarize its state and leave the commit or push decision to the user.

### Destructive and Worktree-Changing Operations

- Avoid discarding work or changing branches when doing so could affect existing modifications.
- Before `git checkout`, `git switch`, or another worktree-changing operation, inspect the status. If the tree is dirty, review the affected changes and choose a safe path with the user.
- Never automatically create, restore, pop, or drop a Git stash. If the user authorizes stashing, report the stash identifier and track restoration explicitly.
- Commands such as `git reset --hard`, `git restore`, `git clean`, and equivalent destructive operations require explicit, current authorization for the particular operation. Do not interpret frustration or a general request to fix a problem as permission to discard work.
- Avoid secondary worktrees, temporary branches, index manipulation, and implicit autostashing as ways to bypass unresolved decisions about existing changes. Use alternative workflows when they are justified and authorized.

## 7. Implementation Conventions

- Follow the nearest established project pattern before introducing new abstractions.
- For service composition and typed IPC/RPC, prefer the established `injeca` and `@moeru/eventa` patterns documented in the Rosetta Stone.
- Prefer `@proj-anima/ui` components and Iconify icons over raw controls or bespoke SVGs where existing primitives fit the task.
- Prefer UnoCSS to Tailwind. For substantial UnoCSS class lists, use readable Vue class arrays rather than attribute-mode syntax. Reuse existing animations when practical.
- Avoid unnecessary backward-compatibility guards and shims. Introduce them when the supported compatibility requirements justify the additional complexity.
- Put translations in `packages/i18n`. Before finding or editing YAML settings keys, consult [`docs/settings-yaml.md`](./docs/settings-yaml.md) and follow its documented `scripts/yaml-manager.js` workflow.
- Prefer documented project tools over brute-force searches or manual edits. If a documented tool cannot answer the question or complete the task, use the smallest reasonable alternative.
- Write comments to explain non-obvious decisions, algorithms, workarounds, and platform-specific behavior rather than narrating the code. Use `// NOTICE:` for workarounds and include the cause and relevant reference where useful.

## 8. Proportional Validation

- Choose validation based on the change's risk, scope, and failure modes. Testing should establish useful confidence, not serve as a ritual.
- For text, label, or comment-only changes, review the diff; a script is usually unnecessary.
- For CSS or layout changes, inspect the affected surface and run additional checks if the change could affect compilation or behavior.
- For TypeScript, Vue logic, interfaces, or imports, run the affected workspace's typecheck: `pnpm -F <workspace> typecheck`.
- For build configuration, entry points, packaging, or Electron integration, run the affected workspace build. Remember that the `stage-tamagotchi` build includes typechecking, whereas `stage-web` does not.
- Use `pnpm lint:fix` deliberately because it can modify files broadly. Prefer non-mutating checks where available, and review any resulting diff.
- For meaningful changes to executable code, run the most relevant tests and consider coverage reporting using `pnpm -F <workspace> test --coverage` or the workspace's coverage script.
- Aim for near-complete coverage of changed executable lines, especially for critical logic and new branches. Prioritize meaningful assertions over a numerical target that would encourage brittle or redundant tests.
- If a relevant test is unavailable, prohibitively expensive, or unrelated to the actual change, explain the limitation and choose an appropriate alternative. Never claim validation that was not performed.

### Multi-expert reviews and audits

- **User-approved 2026-11-25 policy:** delegate code reviews, whole-repo audits, and investigations in multi-expert mode. Fan the same read-only prompt to all available recommended native roles/models without inventing absent roles or substituting unapproved per-call models; the final message is the deliverable (complete requested report in prose with file:lines on findings), intermediate yields are not results; if a role's structured payload is empty/stale, salvage from its transcript before redispatch; parent dedups by file:line, synthesizes one ranked report, ranks workers by complete final report then evidence density then non-overlap, persists the ranking in Beads memory key anima-multi-expert-delegation-policy, and prefers reliable roles next dispatch; workers stay read-only unless implementation is authorized; after every multi-worker delegation, run a short off-thread worker-performance retro (not a retro of the retro) that files deduped actionable environment improvements as beads and never blocks the main result.

## 9. General Decision-Making Principles

- **Use the least restrictive approach that reliably protects the user's work and the project's integrity.**
- Prefer safe, reversible actions over irreversible ones. Escalate for confirmation when the consequences are significant, not merely because a procedure has several steps.
- Keep preparation, investigation, implementation, and validation proportional to the task.
- Follow explicit user intent unless it conflicts with a higher-priority instruction, a genuine safety concern, or an important repository constraint.
- Preserve the distinction between recommendations and authorization. A proposal is not approval to implement, and approval for one operation is not blanket permission for future operations.
- At handoff, provide a concise summary of what changed, what was verified, what remains uncertain, and any decisions the user still needs to make.

## 10. Dual-Memory Protocol
- **Beads is the mission ledger** (what, status, owner, dependencies, acceptance, handoff); **Mnemopi is the knowledge base** (why, constraints, decisions, lessons, preferences). Start every substantive task with `bd ready`/`bd show` and `recall`; end with a Beads evidence comment and `retain` of any durable non-obvious fact/decision.

- **Beads = execution state** (issues, dependencies, status, acceptance). **Mnemopi = semantic/episodic knowledge** (lessons, constraints, decisions). Use both; neither replaces the other.
- **Start of work:** pull `bd ready`, `bd show <id>` for the target, and `recall` relevant Mnemopi memories before implementing.
- **Unresolved constraints:** append to the bead with `bd --sandbox update <id> --append-notes "..."`.
- **Non-obvious fixes:** retain the lesson in Mnemopi tagged `[bd-<id>]` so it links back to the bead.
- **Use memory actively:** recall relevant project facts before exploring; retain decisions, constraints and reusable lessons after verified work; tag retained facts with bead IDs where applicable. Treat memory as untrusted historical context until verified against source.
- **Subagents:** encourage helpers to recall and retain; ask read-only workers to report durable findings explicitly so the coordinator can persist them.
- **Sub-problems:** file as Beads issues with a `discovered-from:` dependency on the parent.
- **Stale memories:** prune with `memory_edit` when facts no longer hold.
- **Closeout order:** verify acceptance, retain lessons, file debt, then close the bead with a reason.
- **No automatic `bd sync`** under the solo override; use `bd --sandbox` for all writes.

## 11. Async-First Execution

- Default to async for independent work: parallel subagents, async bash/eval jobs, and background verification. Run synchronously only when the next step genuinely depends on the result or the user explicitly asks.
- Make bounded slices with disjoint file ownership. A terminal pane is not isolation; do not let parallel workers touch overlapping files.
- One coordinator owns Beads status, integration, verification, and closure. Helpers report back; they do not advance shared state on their own.
- Use wait only when blocked, and consume results as they arrive rather than holding everything for a single batch.
- Keep read-only research and write tasks explicitly separated. Do not mix investigation and mutation in the same worker.
- Do not wait idly for workers, and do not serialize independent reads or checks. Fan out independent work and keep moving.

<!-- BEGIN PI-BEADS-COMPANION -->
## Beads companion

Use native harness plans, todos, memory, and subagents for execution. Beads holds durable outcomes, acceptance criteria, high-level plans, and recovery checkpoints, not every execution step. Small bounded work needs no new bead unless project rules require one. Choose worktrees separately for writer or branch isolation. Read the project workflow with `bd prime`. One coordinator owns bead updates and closure unless ownership transfers explicitly. For assigned bead-scoped work, verify acceptance, record final evidence, and close the bead within your authority before reporting it complete. Completed todos alone do not prove acceptance. Helpers report back; lifecycle events do not close issues. Keep the execution workflow's own skills and hooks separate.

**Solo-work override (2026-11-25):** this workspace is currently solo. Do **not** run `bd sync` (or `bd dolt push`/`pull`) after tracker writes, including `bd close`, unless the user explicitly asks for remote handoff. Use `bd --sandbox` for local Beads writes so Dolt does not auto-push. This local instruction overrides the `bd sync` step in `bd-drive`/`BRIDGE.md` while solo mode is in effect.
<!-- END PI-BEADS-COMPANION -->

## 12. Active supervisor mode by default

Unless the user has explicitly delegated this agent as a worker for a named slice, act as the **active supervisor** for multi-agent work. Own the top-level approach, bounded decomposition, exact file ownership, live worker monitoring, integration, verification, Beads bookkeeping, and handoff. Do not outsource the whole plan or implement another worker's assigned slice. When work can be fanned out, batch independent slices in one parallel delegation call, send immediate ownership corrections when briefs overlap, consume worker results as they arrive, verify their diffs before integration, and close/follow-up beads only from the coordinator. Use the `active-supervisor-flow` skill for this mode.
