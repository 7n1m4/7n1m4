# Character Card, Scenes & Models (source of truth)

How a card's identity, behaviour, per-card module overrides, and visual assets are
configured. The **in-code schema is the source of truth** for every field; this doc maps
the surfaces and the order you configure them in.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Card schema (`AiriCardSchema`, `AiriExtensionSchema`, `AiriOutfitSchema`) | [`packages/stage-ui/src/types/card.schema.ts`](../../../../../stage-ui/src/types/card.schema.ts) |
| Card runtime store (activation, per-card module resolution, outfit switching) | [`packages/stage-ui/src/stores/modules/airi-card.ts`](../../../../../stage-ui/src/stores/modules/airi-card.ts) |
| Editor shell + tabs | [`index.vue`](./index.vue), [`components/tabs/`](./components/tabs) |
| Scene backgrounds | [`packages/stage-ui/src/stores/background.ts`](../../../../../stage-ui/src/stores/background.ts), [`settings/scene/index.vue`](../scene/index.vue) |
| Model import / customization | [model-settings README](../../../../../stage-ui/src/components/scenarios/settings/model-settings/README.md) |

Architecture pointers: `docs/design-airi-card.md`, `docs/design-modular-outfits-system.md`.

## 1. Creating a card

Open **Settings &rarr; AIRI Card Editor** and click **Create New Card**. The editor tabs
map onto the schema sections:

1. **Identity** (`CardCreationTabIdentity.vue`) — required `name`, `description`,
   `systemPrompt`; optional `nickname`, `creatorNotes`, `personality`, `scenario`,
   `greetings`, `version`. `postHistoryInstructions` is part of the same identity block.
2. **Generation** (`CardCreationTabGeneration.vue`) — the LLM provider/model pair, max
   tokens, temperature. The provider must already exist in
   [Providers](../../../../../stage-ui/src/stores/providers/README.md). Cap max tokens on
   non-local models to control cost; lower temperature for stability.
3. **Acting** (`CardCreationTabActing.vue`) — idle loops, ACT/model expression mapping,
   the Model Expression Prompt (the machine-readable `Variant [Skin]` / motion
   vocabulary), and optional vocal tags.
4. **Modules** (`CardCreationTabModules.vue`) — per-card overrides for LLM, STT, TTS,
   scene, and avatar. Anything unset falls back to the global module settings.
5. **Proactivity** (`CardCreationTabProactivity.vue`) — interaction intervals, trigger
   ratios, heartbeat events, stealth prompts, and the `NO_REPLY` keyword.
6. **Tools** (`CardCreationTabTools.vue`) — the `allowedTools` gate (`web_search`,
   `filesystem`, `mcp`, …). Tools are strictly opt-in; an empty gate strips every tool
   schema from the model's context.

Cards serialize to the shared `airi-card` JSON format; import/export mapping lives in
`CardImportWizard.vue` and `docs/design-character-card-import-export.md`.

## 2. Scenes (backgrounds)

Backgrounds are blob-backed `background` store entries, not card fields.

- Upload and switch from the scene gallery (**Settings &rarr; Stage Backgrounds**); all
  standard raster formats are accepted.
- A card can pin a default background; the Studio concept stack can override it per
  concept (see the
  [actor token pipeline](../../../../../stage-ui/src/components/scenes/README-actor-token-pipeline.md)).

## 3. Models

Supported formats and the full import/customization flow live in the
[model-settings README](../../../../../stage-ui/src/components/scenarios/settings/model-settings/README.md):
VRM (`.vrm`), Live2D (`.model3.json` bundle or `.zip`), Spine (`.skel`/`.json` + atlas +
atlas pages), and MMD (`.pmx`). Scale, position, expression mapping, and idle animation
are per-model settings resolved by `display-models.ts` and the renderer packages.
