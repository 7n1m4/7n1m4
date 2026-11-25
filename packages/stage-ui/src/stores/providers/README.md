# Provider store

Source of truth for how `stores/providers.ts` and `stores/providers/*` are structured.
`docs/arch-provider-store-current-structure.md` is only an architecture pointer here.
Historical migration/handoff context lives in
`docs/archive/project-provider-store-phase1-handoff.md` … `phase5-handoff.md`,
`docs/project-provider-store-restructuring-plan.md` and
`docs/project-codex-provider-restructuring-plan.md`.

## What `providers.ts` does

`stores/providers.ts` (~478 lines) is the runtime orchestration store. The former
3,000-line monolith is decomposed; this file only wires modules together and exposes the
public surface:

- multi-instance state + persistence projections (`runtime/instance-store.ts`)
- provider runtime state and reactive validation (`runtime/validation.ts`)
- instance caching/disposal, model loading and lifecycle
  (`runtime/instances.ts`, `runtime/models.ts`, `runtime/lifecycle.ts`)
- registry composition (`registry/index.ts`)
- pure config/availability selectors (`selectors/config.ts`, `selectors/availability.ts`)
- UI-facing derived provider lists for the stage application

## Module seams

### 1. Pure definition layer (`libs/providers/`)

Decoupled from Pinia, UI and `vue-i18n`:

- `types.ts` — framework-agnostic contracts (`ProviderDefinition`, `ProviderInstance`,
  `ProviderTranslationFn`).
- `providers/registry.ts` + `providers/<id>/index.ts` — cloud provider schemas
  (OpenAI, Anthropic, Gemini, DeepSeek, Ollama, …).
- `validators/run.ts` — generic config and connectivity validation plan execution.

### 2. Specialized modality registries (`stores/providers/registry/`)

- `speech.ts` — TTS metadata and voice catalogs (Kokoro, Pocket TTS, MOSS TTS,
  ElevenLabs, Azure, Polly, …).
- `transcription.ts` — STT metadata and Whisper model catalog.
- `local-engines.ts` — in-browser WebGPU/WASM engines (Web-RWKV, WebLLM, BLIP Local,
  Apple Core AI).
- `chat-local.ts` — self-hosted chat servers (vLLM, Player2).
- `index.ts` — `createProviderRegistry(t, definitions)` merging modular definitions with
  the modality registries.

### 3. Runtime orchestration (`stores/providers/runtime/`)

- `instance-store.ts` — multi-instance storage engine. Persists
  `settings/credentials/providers` as `{ version: 2, instancesByInstanceKey }` where the
  instance key is `${providerId}:${instanceId}` and `'*'` holds the primary instance that
  the legacy single-instance surface reads/writes. Also migrates the Phase 1 shape and
  normalizes upstream snake_case credential aliases (`api_key` → `apiKey`,
  `base_url` → `baseUrl`) only when the camelCase key is absent.
- `instances.ts` — SDK client instantiation, caching, fail-fast unconfigured-provider
  guards.
- `models.ts` — model fetching/caching per configured provider.
- `lifecycle.ts` — initialize/delete/reset provider settings and credential watchers.
- `validation.ts` — validation runner, IPC reporting, toast notification, debounced
  credential checking, secret redaction.

### 4. Selectors (`stores/providers/selectors/`)

- `config.ts` — `isProviderConfigured`, `shouldListProvider`, default/instance config
  resolution. Pure: state is passed in explicitly so `computed()` can compose it.
- `availability.ts` — `configuredProviders`, `availableProviders`,
  `allProvidersMetadata`, `availableProvidersMetadata`.

### 5. Local hardware & inference (`libs/inference/`)

- `gpu-resource-coordinator.ts` — estimated VRAM budget accounting, memory-pressure
  telemetry, device-loss telemetry, LRU worker eviction (advisory; workers own the
  actual `GPUDevice`).
- `cache-utils.ts` — storage inspection and model cache eviction across OPFS, Cache
  Storage and the Native App Sandbox.
- `constants.ts` — model IDs, repo paths, timeout/retry budgets, catalog specs.

## Runtime flow

1. `createProviderInstanceStore()` loads multi-instance config from
   `settings/credentials/providers` and runs legacy migration.
2. `createProviderRegistry(t, providerDefinitions)` builds the unified registry.
3. Reactive runtime state is created for added (`settings/providers/added`) and
   configured providers (`settings/providers/runtime`).
4. `createProviderValidation()` auto-validates configured providers on change.
5. `createProviderInstances()` / `createProviderModels()` create, cache and dispose SDK
   instances and model lists on demand.
6. Selectors expose derived metadata, categories and model queries to UI surfaces.

## Related

- `docs/data-catalog.md` §4.18 — credential/runtime key inventory.
- Skills: `airi-provider-core-registry`, `airi-provider-store-instances`,
  `airi-provider-ui-pages`, `airi-local-inference-engines`.
