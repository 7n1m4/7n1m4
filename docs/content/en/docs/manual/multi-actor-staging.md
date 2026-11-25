---
title: Multi-Actor Staging & Wardrobes
description: How to orchestrate multi-character conversations in Studio, manage character outfits, and switch costumes dynamically.
---

# Multi-Actor Staging & Wardrobes

Anima's multi-actor staging (`<|ACTOR:x|>` handoff), card-level outfits, and the ACT-setter pattern that persists in-costume state are implemented in the stage-ui actor-token pipeline, card store, and wardrobe UI.

See the code-colocated [Multi-Actor Staging & Wardrobes](https://github.com/7n1m4/AnimA/blob/main/packages/stage-ui/src/components/scenes/MULTI-ACTOR-STAGING.md) document for multi-actor cards, outfit authoring and switching, Base vs. Layer concepts, and the `Variant [Skin]` persistence rules.

> [!NOTE]
> Studio image generation (Autonomous Artistry / the Director loop) is deprecated and disabled; actor tokens, outfits, and static-asset pinning still work.