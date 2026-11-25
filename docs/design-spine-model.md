# Spine Model Architecture & Integration

> Architecture pointer. The **in-code types and loaders are the source of truth**
> for the Spine package manifest, hit-area schema, and gesture engine; this doc
> only maps the parts. The `model0.json` schema and `SpineHitArea` shape live
> verbatim in the JSDoc of the files below.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Package / variant layout (`SpineModelLayout`, `SpineModelVariant`, `detectAllSpineLayouts`) | [`packages/stage-ui-spine/src/utils/spine-zip-loader.ts`](packages/stage-ui-spine/src/utils/spine-zip-loader.ts) |
| Interaction manifest (`SpineHitArea`: `spring`/`limits`/`follower`/`audio`) + gesture state machine | [`packages/stage-ui-spine/src/composables/spine/gesture-interaction.ts`](packages/stage-ui-spine/src/composables/spine/gesture-interaction.ts) |
| Scene model (parses `model0.json` `hit_areas`/`motions`/`options.scale_factor`) | [`packages/stage-ui-spine/src/components/scenes/spine/Model.vue`](packages/stage-ui-spine/src/components/scenes/spine/Model.vue) |
| Store (`availableVariants`/`availableSkins`, `hitDetectionMode`, `radialHitRadius`) | [`packages/stage-ui-spine/src/stores/spine.ts`](packages/stage-ui-spine/src/stores/spine.ts) |
| Emotion ↔ animation mapping | [`packages/stage-ui-spine/src/constants/emotions.ts`](packages/stage-ui-spine/src/constants/emotions.ts) |

## Model

A Spine character is a single ZIP with one subdirectory per **outfit/variant**
(skeleton `.skel`/`.json` + `.atlas` + textures + an optional `model0.json`
manifest) and shared root-level audio. Internal **skins** (attachments/weapons)
are compiled into the skeleton and exposed via `availableSkins`.

`model0.json` (parsed at runtime by `Model.vue`) declares `hit_areas[]`
(per-bone interaction zones with spring-damper `limits` and `follower` bones)
and `motions` (interaction → animation clip + SFX). The gesture engine resolves
`pull` / `tap` / `pat` / `tickle` / `smash` from `hit_area.type` and name, using
`hitDetectionMode` (`bounds` | `radial`) and `radialHitRadius` from the store.

AI actors drive the model via `<|ACT: ...|>` tokens (emotion / motion / vfx),
mapped to animations by `constants/emotions.ts` and played through the store's
one-shot / idle tracks.

## Related

- Card schema & `extensions.airi`: [`design-airi-card.md`](./design-airi-card.md)

## Relevant Skills

- [[airi-character-rendering]]
- [[airi-vrm-vhack-studio]]