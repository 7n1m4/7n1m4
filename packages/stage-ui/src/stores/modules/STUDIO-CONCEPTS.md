# Studio Concepts & the Concept Stack (source of truth)

The Studio is the multi-actor and scene orchestration layer on top of a standard card. It
registers reusable **concepts** — outfits, secondary characters, moods, places, filters —
and resolves the active scene from an ordered **concept stack**. **The in-code stores are
the source of truth**; this doc maps them and records the authoring model.

> Image generation (Autonomous Artistry / the Director generation loop) is deprecated and
> disabled — `ARTISTRY_GENERATION_ENABLED = false` in
> [`stores/modules/artistry.ts`](../../stores/modules/artistry.ts). Actor tokens, the
> concept stack, and static-asset pinning still work; only generation is a no-op. Existing
> journal images remain readable.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Concept schema (`visual_assets`, `isBase`, `manifestation`) | [`types/card.schema.ts`](../../types/card.schema.ts) |
| Stack resolution (`resolveConceptStack`) and fold (`foldConceptStack`) | [`stores/modules/artistry-template.ts`](../../stores/modules/artistry-template.ts), [`stores/modules/artistry-autonomous.ts`](../../stores/modules/artistry-autonomous.ts) |
| Actor-token handoff at playback | [actor-token pipeline](\.\./\.\./components/scenes/README-actor-token-pipeline.md) |
| Multi-actor authoring, outfits, ACT setter pattern | [MULTI-ACTOR-STAGING](\.\./\.\./components/scenes/MULTI-ACTOR-STAGING.md) |
| Actor desync invariants (speaker-owned stage model) | `docs/design-fix-actor-stage-desync.md` |
| Skills | `airi-director-orchestration`, `airi-artistry-comfyui-widgets` |

## 1. Three pillars of a concept

A concept is a named package applied to the scene as three **independent** layers:

1. **Identity (prompt snippet)** — tags/narrative appended to the (now disabled)
   generation prompt, e.g. `, (burgundy velvet dress:1.4)`.
2. **Artistry (generation overrides)** — per-concept provider/model/workflow switches.
   Retained only as the seam for the planned external SAI image-control integration.
3. **Manifestation (physical appearance)** — the live stage: `modelId` swap,
   `backgroundId`, `active_expressions` variant lock, mood, and dialogue text colour.

A concept may carry any subset. Which pillars it carries, and when they apply, is what
makes the Studio flexible.

## 2. Base vs. Layer, and the stack fold

- **Base (exclusionary)** — a complete state change; activating one **clears the stack**.
- **Layer (additive)** — stacks on top of the Base and other Layers; only overrides fields
  it declares.

The stack is folded bottom-to-top: prompts concatenate in order; Artistry and
Manifestation resolve **last-wins**.

**The place is the Base.** When characters and locations mix, treating a *person* as the
Base collides the moment two characters share a scene. Register the location as the Base
(`place-bedroom`, `place-kitchen`) and the actors, moods, and weather as Layers
(`actor-first-girl`, `mood-intimate`, `weather-rain`). Room changes then reset the slate
atomically and characters layer in naturally.

## 3. Three orchestration modes

| Mode | Who drives | Shape |
| :--- | :--- | :--- |
| **A — Actor-driven multi-character** | `<\|ACTOR:x\|>` tokens in dialogue | Place = Base; each character = Layer with its own model/voice. The stage model is speaker-owned. |
| **B — Director-driven outfits** (deprecated) | the (disabled) Director | One character, each full look a Base; no actor tokens. |
| **C — Static-preset personalities** | actor tokens, Director **off** | Two aspects of one character, each a Base pinning its own hand-authored background; the token swaps model + background + voice atomically. |

Setup C is the proof the Studio does not require the Director: with Autonomous Artistry
off, no image is ever generated and the whole visual experience is pre-made assets pinned
to actor tokens.

## 4. Authoring a concept

Per concept, in the card's artistry section:

- **Identity** — `id` (short, lowercase, stable: `actor-first-girl`), `description` (for
  the creator/Director), `prompt` snippet, `type` (Base or Layer).
- **Manifestation** — `modelId`, mood/expression lock, `backgroundId`, text colour.
- **Artistry** — provider/model/options overrides (seam only; generation disabled).
- **Speech** — provider/model/voice overrides so each actor sounds distinct.
- **Idle behaviour** — suggested idle animations while the concept's model is on stage.

## 5. Deprecated Director configuration (seam reference)

The `extensions.airi.artistry` block keeps `autonomousEnabled`,
`autonomousThreshold` (1–100 grading gate), `autonomousHistoryDepth`,
`autonomousModelMode`/`autonomousProvider`/`autonomousModel`, and `spawnMode`
(`bg_widget` background, inline, floating panel, or both). These are inert while
generation is disabled and are documented only as the surface the external SAI
integration will drive.

## 6. Troubleshooting

- **Characters swap at the wrong time** — Base/Layer misclassification. Coexisting
  speakers must be Layers; the place is the Base.
- **Model moves mid-speech** — see `docs/design-fix-actor-stage-desync.md`; the stage
  model is speaker-owned and only the playback-level actor handler may move it.
- **A concept's look never appears** — its `manifestation.modelId` is unset, or a
  Base activation wiped the stack.
- **Variant state resets every turn** — the costume is marked Base; make it a Layer.
