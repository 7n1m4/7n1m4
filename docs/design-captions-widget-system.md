# Caption Widget & Overlay System — Architecture

Architecture-level pointer. The capability is AIRI's subtitle/caption overlay: an Electron
caption window plus a shared typography panel, driven by the Sentence Sync
BroadcastChannel protocol that animates subtitle segments in lock-step with TTS playback.

Source of truth for the file map, settings/docking/theme behavior (v4+), the
`airi-caption-overlay` channel and `CaptionSegment` schema, the Sentence Sync protocol and
client integration rules now lives in
`packages/stage-ui/src/components/scenes/README.md` §1–3.

Historical status: implemented and in use; the head-tethered in-scene plank is covered
separately in `docs/design-head-tethered-captions.md`.

*   **Caption Window Manager (Electron Main)**: [`apps/stage-tamagotchi/src/main/windows/caption/index.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/apps/stage-tamagotchi/src/main/windows/caption/index.ts)
*   **Caption Overlay Renderer (Vue UI Page)**: [`apps/stage-tamagotchi/src/renderer/pages/caption.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/apps/stage-tamagotchi/src/renderer/pages/caption.vue)
*   **Modular Caption Panel**: [`packages/stage-ui/src/components/scenes/CaptionPanel.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/components/scenes/CaptionPanel.vue)
*   **Caption Settings Store (Pinia)**: [`packages/stage-ui/src/stores/settings/captions.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/stores/settings/captions.ts)
*   **Hardware/Coordination Host**: [`packages/stage-ui/src/components/scenes/ControlStripHost.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/components/scenes/ControlStripHost.vue)
*   **IPC Eventa Contracts**: [`apps/stage-tamagotchi/src/shared/eventa.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/apps/stage-tamagotchi/src/shared/eventa.ts)
## Relevant Skills

- [[airi-caption-subsystem]]
