# Design: Modular Outfits & Accessories System

> Architecture pointer. The **in-code schema and store are the source of truth**
> for the outfit data model and switching logic; this doc only maps the parts.
> The `AiriOutfit` shape lives verbatim in the JSDoc of the files below.

## Where the truth lives

### 1. Data Layer (The Schema)
**File**: [packages/stage-ui/src/types/card.schema.ts](file:///c:/Users/h4rdc/Documents/Github/airi-rebase-scratch/packages/stage-ui/src/types/card.schema.ts)
- **Requirement**: Extend `AiriExtensionSchema` to include an `outfits` array.
- **Structure**:
```typescript
export interface AiriOutfit {
  id: string
  name: string
  icon: string // Iconify identifier
  type: 'base' | 'overlay' // Base = Exclusive, Overlay = Additive
  expressions: Record<string, number> // Weights for specific blendshapes
}
```

### 2. State Logic (The Store)
**File**: [packages/stage-ui/src/stores/modules/airi-card.ts](file:///c:/Users/h4rdc/Documents/Github/airi-rebase-scratch/packages/stage-ui/src/stores/modules/airi-card.ts)
- **Logic**: Implement `applyOutfit(id: string)`.
- **Base Switch**: If `type === 'base'`, the store must iterate through the current `activeExpressions` and set any expression found in *other* base outfits back to 0 before applying the new values. This ensures that switching from "Dress" to "Suit" doesn't leave lingering blendshapes active.
- **Overlay Switch**: If `type === 'overlay'`, it simply toggles the expressions on top of the current state.

### 3. Management UI (The Settings Editor)
**Primary Coordinator**: [packages/stage-ui/src/components/scenarios/settings/model-settings/index.vue](file:///c:/Users/h4rdc/Documents/Github/airi-rebase-scratch/packages/stage-ui/src/components/scenarios/settings/model-settings/index.vue)
**The Expression List**: [packages/stage-ui/src/components/scenarios/settings/model-settings/vrm-expressions.vue](file:///c:/Users/h4rdc/Documents/Github/airi-rebase-scratch/packages/stage-ui/src/components/scenarios/settings/model-settings/vrm-expressions.vue)
- **Addition**: Add a "Wardrobe Management" section at the top of the expressions tab.
- **Interaction**: Allow expressions from the lists to be "Long Pressed" or "Dragged" into one of 9 destination slots to create a bundle.

### 4. Interactive UI (The Island)
**File**: [apps/stage-tamagotchi/src/renderer/components/stage-islands/controls-island/index.vue](file:///c:/Users/h4rdc/Documents/Github/airi-rebase-scratch/apps/stage-tamagotchi/src/renderer/components/stage-islands/controls-island/index.vue)
- **State**: The `view` state is expanded to include `'wardrobe'`.
- **Layout**: A 3x3 `overflow-y-auto` container followed by a fixed utility row for filtering.
- **Visual Feedback**:
  - `Base`: Solid amber background.
  - `Overlay`: Blue ring/outline highlight.

## Related

- Card schema & `extensions.airi.outfits`: [`design-airi-card.md`](./design-airi-card.md)

## Relevant Skills

- [[airi-modular-outfits-system]]