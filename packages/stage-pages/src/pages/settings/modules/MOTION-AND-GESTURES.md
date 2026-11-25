# Generative Motion & Gestures (source of truth)

How an avatar moves: built-in VRMA presets, inline `<|ACT:…|>` cues in the LLM stream,
and local neural text-to-motion. **The in-code stores and runtime are the source of
truth**; this doc maps them.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Text-to-motion store (procedural + FlowMDM) | [`stores/modules/text-to-motion.ts`](../../../../../stage-ui/src/stores/modules/text-to-motion.ts) |
| ACT cue parsing / dispatch | [`skill airi-acting-cue-act-tokens`](../../../../../../.agents/skills/airi-acting-cue-act-tokens/SKILL.md), [`skill airi-conversational-pacing`](../../../../../../.agents/skills/airi-conversational-pacing/SKILL.md) |
| Procedural motion models (VAR, AR-HMM) | [`packages/motion-driver-magic/README.md`](../../../../../motion-driver-magic/README.md) |
| FlowMDM (CLIP encoder, DDIM solver, VRMA exporter) | `packages/stage-ui/src/utils/flowmdm/` |
| Model-side expression/idle configuration | [model-settings README](../../../../../stage-ui/src/components/scenarios/settings/model-settings/README.md) |
| Settings page | [`settings/modules/text-to-motion.vue`](./text-to-motion.vue) |

Design background: `docs/design-text-to-motion.md`, `docs/research-text-to-motion.md`.

## 1. Three motion paths

```text
[ LLM turn / user command ]
      ├──► Built-in presets (VRMA library: wave, think, jump, dance, …)
      ├──► Kinetic ACT tokens (<|ACT:motion="excited_wave"|>)
      └──► Generative text-to-motion (FlowMDM, local WebGPU)
```

All three converge on the avatar renderer and blend with the current speech audio.

## 2. ACT motion & emotion cues

The model embeds performance markers directly in its reply; the parser intercepts them
before display and dispatches them to the renderer:

- `<|ACT:motion="wave"|>` — a greeting wave.
- `<|ACT:motion="think",duration="4"|>` — hand-to-chin for 4 s.
- `<|ACT:emotion="happy",intensity="0.8",duration="3"|>` — a smile held 3 s, then a
  smooth return to neutral.
- `<|ACT:emotion="happy",motion="wave",duration="3"|>` — expression and motion together.
- `<|ACT:emotion="neutral"|>` or `duration="0"` — release the active hold immediately.
- `<|DELAY:2|>` — a 2 s pause in speech.
- `<|ACT:vfx="fire",duration="4"|>` — an elemental aura at an emotional peak.

Actor-scoped persistence (`Variant [Skin]` states written into the acting concept) is
covered by the actor-token pipeline doc, not here.

## 3. FlowMDM (local neural text-to-motion)

Given a description such as *"take two steps back and do a dramatic bow"*, the local
WebGPU worker synthesizes a 3D skeletal track and compiles it to VRMA bytecode in-process
— no cloud dependency.

Enable it under **Settings &rarr; Modules &rarr; Text to Motion**: select **FlowMDM (Local
WebGPU)**, download the model weights once (cached locally), then test prompts in the
motion playground.

## 4. Resting postures & idle cycles

Per-model, in the Model Customizer (**Settings &rarr; Character &rarr; Vessel / Display
Model &rarr; Customize Model**):

- **Default idle** — the base resting posture.
- **Random motion cycles** — subtle weight shifts, head tilts, and hair adjustments every
  15–30 s so the avatar reads as alive while idle.
