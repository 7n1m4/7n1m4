# Production Studio & Autonomous Artistry

> [!WARNING]
> **Artistry is deprecated and image generation is disabled.** AI image generation is stubbed out in this build; no new images are produced. Everything you already generated stays available as read-only history in the Scene Vault and the image journal. The Studio surfaces below (Director's Monitor, timelines, World Bible, Scene Vault) remain usable for authoring and browsing. Image control is moving to an external SAI integration, and the generation pipeline documented here is retained only as the seam that integration will drive.

![Production Studio & Autonomous Artistry](/showcase/hero-09-artistry-studio.avif)

**Historical reference — generation is disabled.** The **Production Studio & Autonomous Artistry** subsystem turns Anima from a conversational agent into a full-fledged cinematic director. It is powered by an autonomous **Director Loop**, ComfyUI Bring-Your-Own-Workflow (BYOW) integration, persistent visual state tracking, and a durable Scene Vault. The generation path described here is deprecated and stubbed; it is kept as the technical seam for the planned external SAI integration.

---

## The Director's Monitor

![Director's Monitor](/showcase/studio-directors-monitor.avif)

The **Director's Monitor** is the command deck for cinematic storytelling:
- **Narrative Tension & Pacing Gauges**: Live evaluation of story tension (`82/100`), pacing coefficients, and narrative arc progress.
- **Multi-Actor Manifestation Tags**: Tracks which cast members and locations are currently manifested (`PLACE_ALT_2`, `ACTOR_OSHINO_SHINOBU`, `ACTOR_MR_SQUEAKS`).
- **Live Visual State Board**: Maintains consistent character outfits, hairstyles, lighting conditions, and environments across consecutive generated images.

---

## Timelines & Multi-Arc Visual State

![Branching Story Timelines & Visual State Board](/showcase/studio-timelines-and-visual-state.avif)

Storylines branch and evolve over time:
- **Branching Universe Timelines**: Switch between divergent story timelines (e.g. *Main Timeline*, *Timeline 6*, *Beach Trip Arc*) with complete visual isolation.
- **World Bible Directives**: Author rigid prompt constraints, cast character tags, and wardrobe tokens to ensure generated art remains true to character lore.

![Stage Directives & World Bible](/showcase/studio-stage-directives-world-bible.avif)

---

## Scene Vault: Generated Art & Selfie History

![Scene Vault Gallery](/showcase/studio-scene-vault.avif)

The **Scene Vault** is a persistent visual archive preserving every illustration generated during conversations:

New generation is disabled, so the archive is read-only history — nothing is added to it, and nothing in it is removed.

- **Universe-Scoped Galleries**: Browse generated art grouped by character, universe arc, and episode session.
- **Metadata Overlays**: Inspect prompt seeds, sampler settings, LoRA weights, and generation timestamps.
- **1-Click Stage Background Binding**: Set any generated illustration as the active stage backdrop with a single click.

---

## Global Generation Canvas & Autonomous Controls

![Live Studio Generation Canvas](/showcase/settings-artistry-live-studio-canvas.avif)

- **Universal Engine Support**: Direct integration with local ComfyUI, Pollinations AI, Replicate, and Nano Banana Google AI Studio. (Deprecated — the generation path is stubbed; these backends are documented as the seam for the external SAI integration.)
- **Autonomous Director Sensitivity Deck**: Fine-tune the manifestation threshold (`23%`), evaluation targets, and context history depth for spontaneous background image generation.

![Director Sensitivity Tuning Deck](/showcase/studio-director-sensitivity-controls.avif)

---

## Key Capabilities

- **Autonomous Director Loop**: Evaluates narrative shifts and generates matching imagery without manual prompts. **Deprecated/stubbed:** the loop no longer produces images.
- **Persistent Visual State Board**: Guarantees visual continuity of clothing, hairstyles, and scenery across turns.
- **Branching Story Universes**: Multiple timeline tracks with isolated scene and image histories.
- **Scene Vault Archive**: Durable local storage for generated art, character selfies, and stage backgrounds.
- **ComfyUI BYOW Protocol**: Upload custom `workflow_api.json` templates with exposed field substitution. **Deprecated/stubbed:** retained as the technical seam for the planned external SAI integration.
- **Director Sensitivity Tuning**: Configurable autonomy thresholds for seamless background generation.
