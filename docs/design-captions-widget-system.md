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

## Relevant Skills

- [[airi-caption-subsystem]]
