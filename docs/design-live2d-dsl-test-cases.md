# Live2D DSL Test Cases — Architecture

Architecture-level pointer. This document covered the technical hand-off for verifying the
Live2D DSL: downloading/packaging stateful Steam Workshop models (`.lpk`), the per-model DSL
feature matrix, and the interpreter/state-machine verification checklist.

Source of truth now lives in `packages/live2d-runtime/src/dsl/README.md` §7 (acquisition
commands, workshop-id feature table, verification checklist) and the Vitest suites under
`packages/live2d-runtime/test/`.

Historical status: single-MOC parsing, intimacy mapping and conditional branching are
implemented and tested; `change_cos` verification waits on the ingestion fix.

## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
