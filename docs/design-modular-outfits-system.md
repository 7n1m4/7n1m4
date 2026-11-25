# Design: Modular Outfits & Accessories System

> Architecture pointer. The **in-code schema and store are the source of truth**
> for the outfit data model and switching logic; this doc only maps the parts.
> The `AiriOutfit` shape lives verbatim in the JSDoc of the files below.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Outfit schema (`AiriOutfitSchema`) | [`packages/stage-ui/src/types/card.schema.ts`](packages/stage-ui/src/types/card.schema.ts) |
| Runtime `AiriOutfit` interface + `applyOutfit(id)` (base-zeroing / overlay-toggle) | [`packages/stage-ui/src/stores/modules/airi-card.ts`](packages/stage-ui/src/stores/modules/airi-card.ts) |
| Wardrobe editor UI | [`packages/stage-ui/src/components/scenarios/settings/model-settings/`](packages/stage-ui/src/components/scenarios/settings/model-settings) (`vrm-expressions.vue`, `ModelCustomizer.vue`) |
| Island wardrobe view | [`packages/stage-ui/src/components/scenarios/layout/ControlStrip.vue`](packages/stage-ui/src/components/scenarios/layout/ControlStrip.vue) (wardrobe popover at line 2462, `wardrobeItems`/`triggerWardrobeItem`/`applyOutfit`) |

## Model (see JSDoc for fields)

An outfit is a named bundle of blendshape weights (`expressions: Record<string, number>`)
with `type: 'base' | 'overlay'`.

- **Base** outfits are *exclusive*: applying one zeroes the expressions of every
  other base outfit first ("net zero"), preventing overlapping-clothes artifacts.
- **Overlay** outfits are *additive*: they toggle on top of the current state.

## Related

- Card schema & `extensions.airi.outfits`: [`design-airi-card.md`](./design-airi-card.md)

## Relevant Skills

- [[airi-modular-outfits-system]]