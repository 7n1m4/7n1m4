# Multi-MOC Packages & ChangeCos Hot-Swapping — Architecture

**Status:** Technical Architecture & UX Specification
**Target Package:** `packages/stage-ui-live2d` & `packages/live2d-runtime`
**Key Files:** [`packages/stage-ui-live2d/src/utils/live2d-zip-loader.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-live2d/src/utils/live2d-zip-loader.ts) & [`packages/live2d-runtime/src/dsl/interpreter.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/live2d-runtime/src/dsl/interpreter.ts)

Source of truth for the upstream-vs-fork ingestion comparison, the in-memory MOC3 VRAM
hot-swap pipeline (why disk re-ingestion is an anti-pattern), the multi-costume import modal
UX and the phased roadmap now lives in
`packages/stage-ui-live2d/src/runtime/README.md` §Multi-MOC packages.

Historical status: Phase 2 (single-MOC intimacy `Bonus`, motion enable/disable, VM reactivity)
is the current focus; Phase 3 (`MultiMocRegistry`, WebGL hot-swap bridge, import modal) is
unbuilt.

1. **Single-MOC Ingestion Bias**: The current zip importer ([`live2d-zip-loader.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-live2d/src/utils/live2d-zip-loader.ts)) and storage stores assume a 1-to-1 mapping between a character card and a single `.moc3` binary.
In our fork, [`live2d-zip-loader.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-live2d/src/utils/live2d-zip-loader.ts) extracts raw manifest JSON blocks before `ZipLoader.unzip` sanitizes away entries, capturing custom motion groups, `VarFloats`, `Choices`, `Intimacy`, and `ChangeCos` directives. However, we stopped short of building a multi-MOC VRAM hot-swap registry.
## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
- [[airi-modular-outfits-system]]
