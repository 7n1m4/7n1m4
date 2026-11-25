# Head-Tethered Caption Plank — Architecture

Architecture-level pointer. The capability is an in-scene caption plank rendered inside the
active avatar renderer, anchored above the head and skewed/scaled/rotated per frame from the
model's own pose — a clean-room adaptation of NekoGPT's Live2D accessory perspective fake,
spanning Pixi (Live2D) and a screen-space Canvas2D overlay (VRM/MMD/Spine).

Source of truth for the pose→transform math, per-renderer anchor strategies, the 4-channel
effect engine, trigger catalog, micro-pacer, pooling guardrails, the failure-mode journal, the
upstream PR #2657 synthesis and the cross-model parity test payloads now lives in
`packages/stage-ui/src/components/scenes/README.md` §4–13, with the pure math in
`packages/stage-shared/src/utils/caption-perspective.ts` and the analyzer in
`packages/stage-shared/src/utils/caption-sentiment.ts`.

Historical status: Phase 1 (Live2D) implemented; Phase 2 (VRM/MMD/Spine via Canvas2D) partly
landed; the upstream-synthesis pipeline is a target spec.

## Relevant Skills

- [[airi-caption-subsystem]]
