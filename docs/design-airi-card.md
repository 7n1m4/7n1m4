# AIRI Character Card Architecture & Import/Export

> Architecture pointer. The **in-code schema is the source of truth** for card
> structure and business detail; this doc only maps the moving parts and links
> the canonical code. Examples and code live verbatim in the JSDoc of the files
> below.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Card schema (Valibot, runtime) | [`packages/stage-ui/src/types/card.schema.ts`](packages/stage-ui/src/types/card.schema.ts) — `AiriCardSchema`, `AiriExtensionSchema`, `AiriOutfitSchema` |
| Card store + runtime `AiriExtension`/`AiriOutfit` interfaces, `applyOutfit`, import/export state | [`packages/stage-ui/src/stores/modules/airi-card.ts`](packages/stage-ui/src/stores/modules/airi-card.ts) |
| CCv2/V3 codec (`Card`, `exportToJSON`, `Asset`, `CharacterBook`, `Extensions`) | [`packages/ccc/src/`](packages/ccc/src) — `exportToJSON` in [`export/json.ts`](packages/ccc/src/export/json.ts), types in [`export/types/`](packages/ccc/src/export/types) |
| Image journal entry types | [`packages/stage-ui/src/types/image-journal.ts`](packages/stage-ui/src/types/image-journal.ts) |

## Shape (see JSDoc for the full field list)

An `AiriCard` is a SillyTavern / Character Card Spec V2/V3 `Card` (from
`@proj-anima/ccc`) with AIRI features under `extensions.airi` (`AiriExtension`).
`AiriExtension` groups: `modules` (consciousness / speech / display-model /
background bindings), `cognition`, `heartbeats`, `dreamState`,
`shortTermMemory`/`lifetimeMemory`, `screenWatching`, `textJournal`, `sandbox`,
`toolCallReflection`, grounding flags, `generation`, `acting`
(+ pacing / cadence / cue allowlist / stickers), `stickers`, `outfits`,
`artistry`, `agents`, `imageJournal`, `visual_assets`, `active_concepts`,
`active_state`, `voice_profiles`, `rwkv`. Both the schema and the store are
**loose** — unknown keys survive import/export round-trips.

## Import / export pipeline

- **PNG (SillyTavern V2)** and **JSON (AIRI v1 / CCv2 / CCv3)**: import parses
  the `chara` tEXt chunk or JSON, normalizes greetings/`messageExample`, then
  validates through `AiriCardSchema`; export builds CCv3 via `exportToJSON()`
  (never hand-rolled) and embeds it.
- **ZIP package (v1 upstream / v2 fork)**: `manifest.json` + `card.json`
  (CCv3 via `exportToJSON`) + `models/` + optional `voices/`, `states/`,
  `memories/`. v1 (`format: "airi-character-card"`) stays clean CCv3 for
  upstream; v2 (`format: "airi-card-package"`) is fork-only multi-model. Built
  with `jszip`. MMD and Tachie are **not** bundled (MMD split storage; Tachie
  unsupported in this fork).
- **Live snapshot**: PNG export composites a live VRM/Live2D preview into a
  fixed framed canvas.

| Component | Path | Description |
| :--- | :--- | :--- |
| **Card UI Page** | [`packages/stage-pages/src/pages/settings/airi-card/index.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-pages/src/pages/settings/airi-card/index.vue) | Main card management, drag-and-drop import, JSON/PNG export handlers |
| **Import Wizard** | [`packages/stage-pages/src/pages/settings/airi-card/components/CardImportWizard.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-pages/src/pages/settings/airi-card/components/CardImportWizard.vue) | Webview download import wizard modal |
| **Card Store** | [`packages/stage-ui/src/stores/modules/airi-card.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/stores/modules/airi-card.ts) | Pinia store managing local IndexedDB persistence (`local:airi-cards`) |
| **Card Schema & Types** | [`packages/stage-ui/src/types/card.schema.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/types/card.schema.ts) | Valibot runtime schema (`AiriCardSchema`) |
| **Data Catalog Doc** | [`docs/data-catalog.md`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/data-catalog.md) | Storage layer reference detailing `AiriCard` and `AiriExtension` |
| **Download Interceptor** | [`apps/stage-tamagotchi/src/main/index.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/apps/stage-tamagotchi/src/main/index.ts) | Electron main process interceptor for webview card downloads |
| **Upstream Import/Export Service** | Upstream-only `packages/stage-ui/src/services/airi-card-import-export.ts` (PR #1998, **not present in this fork** — only `services/speech/*` exists locally) | Upstream `moeru-ai/airi:main` ZIP package service. All `FORMAT` / `manifestSchema` / `sanitizeAiri` / `cardFromCharacterCard` / `MODEL_EXT` / `AiriCardPackageError` symbols below are upstream-claimed, zero local matches. Do not fetch `upstream` remote without explicit user authorization (fork safety). |

- Modular outfits & accessories: [`design-modular-outfits-system.md`](./design-modular-outfits-system.md)
- Spine models: [`design-spine-model.md`](./design-spine-model.md)
- Image journal storage: [`design-image-journal-storage.md`](./design-image-journal-storage.md)
- Storage layer detail: [`data-catalog.md`](./data-catalog.md)

The `AiriExtension` interface in [`packages/stage-ui/src/stores/modules/airi-card.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/stores/modules/airi-card.ts#L121) defines AIRI's rich capability set:
In [`apps/stage-tamagotchi/src/main/index.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/apps/stage-tamagotchi/src/main/index.ts#L235):
## Relevant Skills

- [[airi-card-editor-wizard]]
- [[airi-card-schema]]
- [[airi-modular-outfits-system]]