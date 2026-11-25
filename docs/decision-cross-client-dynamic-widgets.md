# Cross-client dynamic widgets: keep two systems

- **Status:** accepted (2026-11-25; bead `airi-osn`)
- **Scope:** dynamic generated widgets in Flutter, Godot, and the Vue reference app. Art/image-journal work stays separately tracked.

## Decision

The Flutter GenUI/A2UI surfaces and the Vue `stage_widgets` sandbox are **two distinct capabilities**, not one cross-client protocol. Do not replace either with the other, and do not add a new shared daemon/tool contract for them.

Flutter's path is an **inline presentation surface**: `chat.send` with `genUi: true` asks the daemon to include the A2UI v0.9 system instruction; assistant output can create/update components from a curated, no-asset/no-URL catalog inside the chat bubble. It has no persistent window, no component-defined callbacks, no tool lifecycle, and no generated-code execution. Its system prompt is a per-turn opt-in, so ordinary chat turns are unchanged.

The Vue reference path is an **out-of-band desktop window tool**: the LLM calls `stage_widgets` with `spawn`/`update`/`remove`/`clear`/`open`, and the Electrobun main process owns snapshot state, per-widget windows, TTLs, IPC events, and sandbox/mount rendering (`packages/stage-ui/src/libs/sandbox/*`). It supports arbitrary component props and a generic JSON-card fallback, and its artistry bridge can drive long-running generation. Those properties depend on desktop IPC and window management, not on the chat transport.

A single protocol would force one of two bad outcomes: flatten the Vue tool to an inline text-only surface (losing window lifecycle, TTL, callbacks, and artistry integration), or grant an inline A2UI stream the desktop tool's mutable surface/window powers. The daemon already exposes general MCP/ACP tool calls; widget interoperability can be built there if a real need appears, without pretending the present systems are equivalent.

## Consequences

- The feature-parity checklist records the difference explicitly rather than claiming parity: Flutter has inline A2UI surfaces; Vue has desktop sandbox windows; Godot has no equivalent.
- A2UI support is not implied by `chat.send` support. Only `genUi: true` opts a turn into the instruction; Vue clients remain plain-text unless they implement their own A2UI renderer.
- Keep generated component execution, external URLs, and arbitrary component names out of the Flutter catalog. Keep the Vue tool's Zod validation and sandbox boundary intact.
- If a future product requires one shared widget language, open a new cross-client contract effort. Its acceptance must enumerate every lifecycle and capability lost by the migrated client; this decision is not a blocker to that future work, but no such migration is authorized here.

## References

- `docs/guide-flutter-genui-widgets.md` — Flutter GenUI catalog, streaming, and failure behavior.
- `docs/project-widget-system-status-report.md` — Vue tool, window manager, sandbox, and artistry bridge.
- `docs/feature-parity-checklist.md` — user-visible parity row.
- `crates/anima-channel/src/wire.rs` — `gen_ui` capability flag on `ChatSendRequest`.
