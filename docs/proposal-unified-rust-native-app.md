# Proposal: Unified Rust Native App (replaces stage-pocket)

**Status:** superseded 2026-11-25 · **Recorded:** 2026-11-13 · **Decision owner:** project lead

> **Superseded banner (2026-11-25, user decision):** the "unified Rust native (Slint) app" direction
> recorded here is **not** the current mobile plan. `crates/anima-slint` was deleted in the Wave-6
> cutover, and mobile is now the **Flutter app (`apps/flutter`)** — the same primary and sole active
> renderer used on desktop — as a **remote thin client** of the desktop `anima-daemon`
> (`docs/design-flutter-godot-pivot.md` decision 10 / decision B). No new UI stack is created for
> mobile. This file is kept as the historical record of why the Capacitor `stage-pocket` was purged.

## Decision (historical, 2026-11-13)

The Capacitor/WebView hybrid mobile app (`apps/stage-pocket`) is **purged** (2026-11-13):

- Web tech on mobile is a lost cause for AIRI — it reintroduces the two-runtimes-one-codebase tax on the surface where touch, lifecycle, and device APIs matter most, and it was never more than a packaging of the shared Vue renderer in a phone shell.
- Mobile gets replaced by a **unified native app**: one native codebase, no webview, state owned by the daemon (see the pivot in [`README.md`](./README.md)), surfaces as thin WS clients.
- The unified app was expected to grow out of [`crates/anima-slint`](../crates/anima-slint), the then-existing Rust shell. **Superseded:** Slint was deleted; the native app is Flutter.

Historical design context is kept in [`archive/project-mobile-revamp.md`](./archive/project-mobile-revamp.md) (superseded — useful for the interaction-plane UX research, not for implementation). The desktop Electrobun/Vue app is **not** affected by this decision.

## UI requirement: one codebase, two form factors (historical)

**The (then Slint) UI had to be reactive to screen-size changes so the same app could be built for both desktop and mobile.** The requirement survives the Slint→Flutter move; only the implementation stack changed:

- No fixed-pixel desktop layouts; layouts derive from the window/screen size (breakpoint categories, portrait vs landscape, phone vs tablet vs desktop).
- Touch-first metrics on small screens (target sizes, spacing), mouse/keyboard affordances on large screens — selected on size, not on a separate code path.
- Navigation that collapses gracefully (rail/strip on desktop → drawer/tabbed on phone) without a second component tree.
- Shared components; only the layout roots and density presets diverge. A screen-size breakpoint system is a prerequisite for any mobile release.

Flutter targets desktop and mobile natively (Android + iOS), so no port to a second UI stack is required.

## Consequences

- **Mobile gateway pairing is the unlock**: a native client speaks the same WS gateway protocol (`airi-gateway`/`anima-channel`, port 6121) as every other surface. LAN/remote use makes gateway TLS (rustls + rcgen) mandatory, not optional — see the daemon-always-on topology notes.
- **On-device inference stays relevant**: [`design-ios-core-ai-native-inference.md`](./design-ios-core-ai-native-inference.md) remains the reference for iOS-side local inference and now feeds the Flutter app rather than a Capacitor wrapper.
- **`stage-pocket` is gone from the workspace**: root scripts, CI (swiftlint step), `packages/cap-vite` (now unused — removal candidate), `isStageCapacitor()` gating sites in the shared renderer, and public docs iOS sections are all affected; cleanup is tracked in the purge notes.
- **Screen telemetry, push, haptics, camera**: mobile-only platform bridges are needed for device integration; expected to land as Flutter platform-channel plugins, not as webview shims.

## Open questions

- Code signing + distribution (App Store / Play Store vs sideload) — resolved for Flutter in [`decision-mobile-distribution-and-code-signing.md`](./decision-mobile-distribution-and-code-signing.md).
- Exact breakpoint system and minimum screen-size floor; whether the desktop shell keeps its Shell (portrait-anchored control strip) as a `mode` preset or as a layout root variant.
- Whether `apps/stage-web` remains the browser behaviour reference long-term, or is retired once Flutter parity lands (decision C in `docs/design-flutter-godot-pivot.md`).
- Rust gateway client placement: **decided — the blocking client is a module in `crates/anima-channel`** (see [`design-daemon-client.md`](./design-daemon-client.md)).