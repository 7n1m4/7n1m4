# Multi-Actor Staging & Wardrobes (source of truth)

How one card hosts several speakers, and how per-costume visual state persists across
turns. **The in-code pipeline is the source of truth**; this doc maps it and records the
authoring rules.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| `<\|ACTOR:x\|>` pipeline (capture → chunk → resolve → playback handoff) | [`packages/stage-ui/src/components/scenes/README-actor-token-pipeline.md`](README-actor-token-pipeline.md) |
| Concept stack fold + `activateConcept` | [`stores/modules/artistry-autonomous.ts`](\.\./\.\./stores/modules/artistry-autonomous.ts) |
| Card/outfit schema and `applyOutfit` | [`types/card.schema.ts`](\.\./\.\./types/card.schema.ts), [`stores/modules/airi-card.ts`](\.\./\.\./stores/modules/airi-card.ts) |
| Wardrobe UI (mesh outfits, base/overlay toggles) | [`ControlStrip.vue`](\.\./scenarios/layout/ControlStrip.vue), [ModelCustomizer](\.\./scenarios/settings/model-settings/ModelCustomizer.vue) |
| Modular outfits design | `docs/design-modular-outfits-system.md` |
| Actor desync invariants | `docs/design-fix-actor-stage-desync.md` |
| Skills | `airi-acting-cue-act-tokens`, `airi-modular-outfits-system`, `airi-director-orchestration` |

## 1. Multi-actor cards & the ACTOR token

Multiple personas live in one card definition. The model prefixes each dialogue block
with the speaker's token:

```text
<|ACTOR:Alice|> Hey Bob, did you finish the review?
<|ACT:motion="think"|>
<|ACTOR:Bob|> Almost — running the typecheck suite now.
```

At playback time each token resolves that actor's provider/model/voice and swaps the
physical stage model in sequence with the audio. Inactive actors idle. The raw token text
is preserved in message `rawContent`, so history keeps the orchestration syntax.

## 2. Outfits & wardrobes

Outfits ride on the card schema (`extensions.airi.outfits`), not a separate store. Each
entry carries `id`, `name`, `type` (`base` or `overlay`), an optional `displayModelId`, and
an `expressions` weight map.

Author them in **Settings &rarr; AIRI Card Editor &rarr; Outfits** (or the Model
Customizer's wardrobe builder for VRM sub-mesh clothing parts): add an outfit, name it,
bind the model or Live2D expression preset, and pick which meshes show/hide.

Switching:

- **Manual** — the Control Strip wardrobe menu calls `cardStore.applyOutfit(id)`.
  `base` outfits zero out rival base weights first; `overlay` outfits toggle off when
  re-applied.
- **In-character** — the model emits an outfit change through the ACT/concept path during
  the narrative (e.g. pajamas on *"goodnight, let's sleep"*).

## 3. Concept stacks: Base vs. Layer

Studio concepts are the deeper layer under both features. Two types:

- **Base (exclusionary)** — a full-state change; activating one clears the stack.
- **Layer (additive)** — stacks on top of the Base and other Layers.

The authoring rule that avoids scene collisions: make the **place** the Base
(`place-bedroom`, `place-kitchen`) and the **actors, moods, and weather** Layers. Two
coexisting speakers must never both be Bases — that is the one conflict the Studio is
intentionally not designed for. Full resolution order and the Director's (deprecated)
grading loop are documented with the actor-token pipeline.

## 4. Costume state that sticks (ACT setter pattern)

An `<|ACT:emotion="…"|>` tag inside an actor's dialogue block does not just play a
state — under that actor's scope it **writes the state into the actor's concept**
(`manifestation.active_expressions`), so the next turn's opening token re-enters already
in that variant.

Naming convention is `Variant [Skin]` — e.g. `French Maid [Normal]`,
`French Maid [Gun]`, `French Maid [Weapon_Off]`. The bracketed skin is the sub-state
(held prop, accessory); the unbracketed name is the costume variant.

Card authors split the contract across two fields:

- **System prompt** — the roster: every active costume token mapped to its concept, plus
  the rule that every dialogue block is prefixed with the matching token and that bare
  unscoped actor tokens are deprecated.
- **Acting tab Model Expression Prompt** — the machine-readable vocabulary: approved
  `Variant [Skin]` emotion strings grouped by costume, approved motion cues, the
  short-format `<|ACT:emotion="…",motion="…"|>` syntax, and the four orchestration rules
  (turn-start prefix, mid-speech transformation, subsequent-turn sync, fluid physical
  acting).

Constraint: costumes must be **Layers**. A Base costume would wipe the stack on entry and
discard the persisted variant state on every wardrobe change.

## 5. What is deprecated

Autonomous Artistry / the Director generation loop is deprecated and disabled
(`ARTISTRY_GENERATION_ENABLED = false`). Actor tokens, the concept stack, outfit
switching, and static-asset pinning all still work; only *image generation* is a no-op.
Existing journal images remain available read-only.
