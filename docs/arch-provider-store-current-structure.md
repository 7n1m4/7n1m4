# Provider Store Current Structure (pointer)

**Status:** historical Phase 1–5 restructuring snapshot; the technical content moved into code.

Module seams and runtime flow for `packages/stage-ui/src/stores/providers.ts` — the pure
definition layer (`libs/providers/`), modality registries (`stores/providers/registry/`),
runtime orchestration (`runtime/instance-store.ts`, `instances.ts`, `models.ts`,
`lifecycle.ts`, `validation.ts`), selectors (`selectors/config.ts`, `availability.ts`) and
local inference coordination (`libs/inference/`) — are documented in
[`packages/stage-ui/src/stores/providers/README.md`](../packages/stage-ui/src/stores/providers/README.md).

Historical migration context stays in `docs/archive/project-provider-store-phase{1..5}-handoff.md`,
`docs/project-provider-store-restructuring-plan.md` and `docs/project-codex-provider-restructuring-plan.md`.

Skills: `airi-provider-core-registry`, `airi-provider-store-instances`, `airi-provider-ui-pages`,
`airi-local-inference-engines`.