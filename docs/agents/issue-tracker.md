# Issue Tracker: Beads (`bd`) — project overrides

This file wins where it differs from `~/.config/opencode/beads/BRIDGE.md`. The global file remains the source for the full skill→command translation table.

## Project-specific state

- Active workspace: `/home/vi/Code/AnimA/.beads` (`bd where`). Issue prefix: `airi`.
- **Solo-work override:** use `bd --sandbox` for all Beads writes (claims, checkpoints, closures, comments). Do **not** run `bd sync` or `bd dolt push/pull` after tracker writes unless the user explicitly asks for remote handoff.

## Frontier and parallel dispatch

- `ready-for-agent` means executable now. Gated work carries `blocked`/`needs-info`/`ready-for-human` plus a real blocking edge on the gate. Never keep work off the frontier with prose alone.
- Epics (`-t epic`) are never `ready-for-agent`; only child tasks enter `bd ready`.
- Canonical dependency order: `bd dep add <blocked-id> <blocker-id>` (same as `bd dep add <id> --blocked-by <blocker>`). Verify edge direction with `bd show <id>` and `bd ready` after wiring.
- Before parallel dispatch, the coordinator posts a checkpoint comment on the bead with: worker name, exact model ID (or `default`), exact owned paths (one writer per file), acceptance commands, and Beads/git authority (normally none). Cancel or redirect a superseded worker before transferring its files.

## Closure

- Close only with the coordinator's actual verification command/output in the bead reason or a preceding comment; a worker's prose report is not acceptance.
- File follow-up work discovered during a task as its own bead with the appropriate blocker/dependency edges.
