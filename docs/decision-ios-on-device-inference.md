<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: iOS on-device inference posture

- **Status:** accepted (2026-11-21, ponytail)
- **Bead:** `airi-u71.8` (child of epic `airi-wxp.3`)
- **References:** `docs/design-ios-core-ai-native-inference.md` (design, reference material only)
- **Scope:** iOS inference posture for the Flutter control/chat app (`apps/flutter`) and AIRI Pocket. Desktop release unchanged.

## Decision

**Daemon (remote) inference remains the default. No iOS-only on-device inference ships now.** The native Core AI / Capacitor plugin plan in `docs/design-ios-core-ai-native-inference.md` is deferred and treated as reference material; it is not a prerequisite for shell delivery.

Rationale:

1. **Mobile is a remote client (D10).** The mobile app stays a remote client of the daemon; on-device LLM/inference is not required for control/chat functionality.
2. **Performance / model / OS constraints.** On-device inference requires Apple Silicon (iPhone 14 Pro / A16 minimum; A17 Pro+ for the full multimodal suite), 6–8 GB unified memory with single-resident or prioritized multi-model allocation, curated `.aimodel` bundles (INT4 / INT8 / palettization, ANE-verified) hosted on Hugging Face, one-time hardware specialization (5–15 s producing a cached `.aimodelc` in the app sandbox), and native `URLSession` background downloads to `Documents/CoreAI/models/` (never through JS buffers). Larger models (12B/27B) trigger Jetsam kills on mobile. This constrains the usable model set to small (≤3B) models and adds download/storage/specialization UX and lifecycle complexity.
3. **Framework availability.** The design depends on Apple "Core AI" (WWDC26-era) and a new native Swift/Capacitor plugin (`@proj-anima/cap-native-ai`) that does not exist yet; building it is a large, separate effort with no current dependency from shell delivery.
4. **Distribution constraints.** iOS distribution is TestFlight (beta) / App Store (production) with sideload dev-only (per `docs/decision-mobile-distribution-and-code-signing.md`); no public IPA hosting, so any on-device model delivery must fit App Store review and size limits.
5. **Daemon path already covers the need.** Daemon inference provides full model access, tool use, and multimodal capabilities without mobile memory/battery/thermal limits.

## Consequences

- `apps/flutter` and AIRI Pocket continue to use daemon inference exclusively; no on-device provider is wired into settings or the chat provider registry.
- `docs/design-ios-core-ai-native-inference.md` remains reference material for a possible future on-device tier; no implementation work is scheduled against it now.
- If a future offline/privacy mode is required, revisit this decision and scope a native plugin as a separate epic, gated on hardware availability and model curation.

## Rejected alternatives

- **Implement now (in-tree Core AI plugin):** rejected — not prerequisite for shell delivery; high cost, unproven framework dependency, and daemon path suffices.
- **Daemon-only forever (delete design doc):** rejected — design doc retained as reference for future offline tier.