# Intelligence & Modules (source of truth)

The module layer is the set of replaceable faculties (mind, voice, ears, eyes, memory,
messaging) plus the provider registry that backs them. **In-code stores are the source of
truth**; this doc maps each module to its store and settings route.

## Where the truth lives

| Module | Store | Settings route |
| :--- | :--- | :--- |
| Consciousness (main LLM) | [`stores/modules/consciousness.ts`](../../../../../stage-ui/src/stores/modules/consciousness.ts) | `/settings/modules/consciousness` |
| Speech (TTS) | [`stores/modules/speech.ts`](../../../../../stage-ui/src/stores/modules/speech.ts) | `/settings/modules/speech` |
| Hearing (STT) | [`stores/modules/hearing.ts`](../../../../../stage-ui/src/stores/modules/hearing.ts) | `/settings/modules/hearing` |
| Vision (VLM) | [vision README](../../../../../stage-ui/src/stores/modules/vision/README.md) | `/settings/modules/vision` |
| Short-term memory | [compaction](../../../../../stage-ui/src/stores/chat/compaction.ts) | `/settings/memory` |
| Long-term memory | [anima-core memory README](../../../../../../crates/anima-core/src/memory/README.md) | `/settings/memory` |
| Artistry (**deprecated**) | [`stores/modules/artistry.ts`](../../../../../stage-ui/src/stores/modules/artistry.ts) | `/settings/modules/artistry` (hidden) |
| Text to Motion | [`stores/modules/text-to-motion.ts`](../../../../../stage-ui/src/stores/modules/text-to-motion.ts) | `/settings/modules/text-to-motion` |
| Discord | [`stores/modules/discord.ts`](../../../../../stage-ui/src/stores/modules/discord.ts) | `/settings/modules/messaging-discord` |
| MCP servers & tools | [`stores/mcp-tool-bridge.ts`](../../../../../stage-ui/src/stores/mcp-tool-bridge.ts) | `/settings/modules/mcp` |

The settings catalog that drives the hub's navigation (ids, routes, `clusterGroup`,
`deprecated` flags) is
[`packages/stage-ui/src/constants/settings-catalog.ts`](../../../../../stage-ui/src/constants/settings-catalog.ts).

## Module semantics

- **Consciousness** — the primary chat provider/model pair. `useLLM()` dispatches every
  chat, tool, and suggestion call through the provider registry.
- **Speech** — TTS provider, model, voice, pitch, rate. Playback is serialized
  (`maxVoices: 1`) so audio never overlaps; see
  [`stores/chat/INTERACTION-PIPELINES.md`](../../../../../stage-ui/src/stores/chat/INTERACTION-PIPELINES.md).
- **Hearing** — STT provider/model, microphone device, VAD sensitivity, hotkey toggles.
- **Vision** — a *dedicated* VLM, deliberately separate from the chat model so image cost
  is bounded; the attention-ecology capture loop is documented in the vision README.
- **Short-term memory** — the conversation window and token budget; compaction is
  incremental (`stores/chat/compaction.ts`).
- **Long-term memory** — the append-only text journal, echo chips, and lifetime artifacts
  owned by the `anima-core` memory crate.
- **Artistry** — deprecated. `ARTISTRY_GENERATION_ENABLED = false` in
  `stores/modules/artistry.ts` makes every generation path a no-op returning the
  deprecation message; the provider/workflow configuration remains only as the seam a
  future external SAI image-control integration targets. Existing journal images stay
  readable and `image_journal.apply` still switches to them.
- **Integrations** — X/Twitter, Factorio, Discord, and MCP, each a self-contained module
  store under `stores/modules/`.

## Providers

Providers are the underlying services (OpenAI, Anthropic, Gemini, Ollama, local
WebGPU/WASM runtimes, …). The registry, instance lifecycle, health checks, and credential
storage are documented in
[`packages/stage-ui/src/stores/providers/README.md`](../../../../../stage-ui/src/stores/providers/README.md).
Provider credentials never live in the card; they are per-provider-instance settings under
`/settings/providers`.
