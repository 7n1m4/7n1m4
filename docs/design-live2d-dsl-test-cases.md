# Live2D DSL Test Cases — Architecture

Architecture-level pointer. This document covered the technical hand-off for verifying the
Live2D DSL: downloading/packaging stateful Steam Workshop models (`.lpk`), the per-model DSL
feature matrix, and the interpreter/state-machine verification checklist.

Source of truth now lives in `packages/live2d-runtime/src/dsl/README.md` §7 (acquisition
commands, workshop-id feature table, verification checklist) and the Vitest suites under
`packages/live2d-runtime/test/`.

Historical status: single-MOC parsing, intimacy mapping and conditional branching are
implemented and tested; `change_cos` verification waits on the ingestion fix.

* **Insights & Stripped Schema Document**: [research-live2d-special-sauce.md](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/research-live2d-special-sauce.md)
   * Review [design-live2d-dsl-interpreter-spec.md](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/design-live2d-dsl-interpreter-spec.md) for context on how the interpreter parses variables, conditional statements (`equal`, `greater`, etc.), and sequence triggers.
   * Understand the game mechanics integration: [design-dating-sim-gamestate-mechanics.md](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/design-dating-sim-gamestate-mechanics.md) and [design-dating-sim-intimacy-spec.md](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/design-dating-sim-intimacy-spec.md).
## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
