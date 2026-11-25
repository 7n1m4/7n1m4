# Multi-MOC Packages & ChangeCos Hot-Swapping — Architecture

Architecture-level pointer. This covered the multi-`.moc3` package problem: stateful VTuber
packs drive `ChangeCos` from motion groups, but ingestion assumed one `.moc3` per card and the
WebGL runtime had no registry to swap geometry into.

Source of truth for the upstream-vs-fork ingestion comparison, the in-memory MOC3 VRAM
hot-swap pipeline (why disk re-ingestion is an anti-pattern), the multi-costume import modal
UX and the phased roadmap now lives in
`packages/stage-ui-live2d/src/runtime/README.md` §Multi-MOC packages.

Historical status: Phase 2 (single-MOC intimacy `Bonus`, motion enable/disable, VM reactivity)
is the current focus; Phase 3 (`MultiMocRegistry`, WebGL hot-swap bridge, import modal) is
unbuilt.

## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
- [[airi-modular-outfits-system]]
