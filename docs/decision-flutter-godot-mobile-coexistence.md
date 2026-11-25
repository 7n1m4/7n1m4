<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Flutter control UI and Godot pet coexistence on one mobile screen (retired historical record)

- **Status:** **superseded / retired 2026-11-25** — the question no longer exists. No implementation authorized.
- **Bead:** `airi-wxp.4.7` (child of epic `airi-wxp.4`) — closed as moot.
- **Scope (historical):** render-surface composition only.

> **Superseded banner (2026-11-25, user decision):** the **Godot pet renderer is purged** from the
> active architecture. Flutter is the primary and sole active renderer on desktop **and** mobile and
> renders characters natively, so there is no second render surface to compose on a phone. The
> option list below is retained as the historical record of the question; it is not an open design
> space and must not be implemented.

## Problem (historical)

On desktop, the Flutter control window and the Godot pet window were independent windows and that was fine. A single mobile screen has no separate-window model, so how the Flutter control UI and the Godot pet were composed was unresolved. (historical only; not current, active, sidecar, or planned)

## Options (historical; not decided, now moot)

1. Embed the Godot view inside Flutter (platform view / Flutter widget). (historical only; not current, active, sidecar, or planned)
2. Flutter overlay compositing.
3. Mode switch (control UI vs pet, one at a time).
4. Compact pet overlay above the control UI.

## Constraints (historical, from prior decisions)

- Render surface only; Rust core unchanged.
- Keep the UI thin for battery life.
- No embedded core / no bundled daemon on mobile (D10).
- Mobile remains a remote client of the daemon.
- Must coexist with mobile distribution/signing lanes (`decision-mobile-distribution-and-code-signing.md`).

## Decision gate

Moot. Composition of two renderers is not a question once there is one renderer. When a second
surface is ever proposed, this document's status moves back to `open` with a new bead.

## References

- `docs/design-flutter-godot-pivot.md` — GUI pivot contract (Flutter-first as of 2026-11-25). (historical context only)
- `docs/decision-mobile-distribution-and-code-signing.md` — mobile distribution lanes.