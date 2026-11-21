<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Flutter control UI and Godot pet coexistence on one mobile screen

- **Status:** open — explicitly undecided (2026-11-21). No implementation authorized.
- **Bead:** `airi-wxp.4.7` (child of epic `airi-wxp.4`)
- **Scope:** render-surface composition only. Rust core, daemon ownership, and "UI thin / no embedded core / no bundled daemon" decisions are unaffected.

## Problem

On desktop, the Flutter control window and the Godot pet window are independent windows and that is fine. A single mobile screen has no separate-window model, so how the Flutter control UI and the Godot pet are composed is unresolved.

## Options (to consider later; not decided)

1. Embed the Godot view inside Flutter (platform view / Flutter widget).
2. Flutter overlay compositing.
3. Mode switch (control UI vs pet, one at a time).
4. Compact pet overlay above the control UI.

## Constraints (non-negotiable, from prior decisions)

- Render surface only; Rust core unchanged.
- Keep the UI thin for battery life.
- No embedded core / no bundled daemon on mobile (D10).
- Mobile remains a remote client of the daemon.
- Must coexist with mobile distribution/signing lanes (`decision-mobile-distribution-and-code-signing.md`).

## Decision gate

Composition approach is recorded only after an explicit user decision. Until then, no implementation. When decided, this document's status moves to `accepted` and a follow-up bead is created for implementation.

## References

- `docs/design-flutter-godot-pivot.md` — GUI pivot contract.
- `docs/decision-mobile-distribution-and-code-signing.md` — mobile distribution lanes.
