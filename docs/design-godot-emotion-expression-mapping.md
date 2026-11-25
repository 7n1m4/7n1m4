# Godot Emotion/Expression Mapping (from TS reference)

> Superseded/retired Godot design; retained as historical mapping reference.
Bead `airi-wxp.4.8` — OPEN/undecided. Study-only; no implementation authorized.
Source: `docs/research-emotion-mapping-reference.md` (§1.1, §2 R1–R14, §3.6, §4).

## Canonical keys → Godot animation state (per backend)

### VRM 3D backend (morph targets via expressionManager)

| TS key | VRM morph targets (weight) | Blend (s) | Hold (ms) |
|---|---|---|---|
| `happy` | `happy` 0.7 + `aa` 0.2 | 0.4 | 2000 (single default) |
| `sad` | `sad` 0.7 + `oh` 0.15 | 0.4 | 2000 (single default) |
| `angry` | `angry` 0.7 + `ee` 0.3 | 0.3 | 2000 (single default) |
| `surprised` | `surprised` 0.8 + `oh` 0.4 | 0.15 | 2000 (single default) |
| `think` | `think` 0.7 | 0.5 | 2000 (single default) |
| `awkward` | raw fallback (no dedicated preset) | 0.4 | 2000 (single default) |
| `question` | raw fallback (no dedicated preset) | 0.4 | 2000 (single default) |
| `curious` | raw fallback (no dedicated preset) | 0.4 | 2000 (single default) |
| `neutral` | all weights → 0.0 | 0.6 | immediate (no auto-reset) |
| `cool` | `Pixel glasses` 1.0 | 0.3 | 2000 (single default) |

### MMD 3D backend (morph slots via candidate-name lists)

| TS key | MMD morph slots (weight) | Blend (s) | Hold (ms) |
|---|---|---|---|
| `happy` | `smile` 0.8 + `vowelA` 0.2 | 0.4 | 2000 (single default) |
| `sad` | `sad` 0.75 + `troubled` 0.3 | 0.4 | 2000 (single default) |
| `angry` | `anger` 0.8 | 0.3 | 2000 (single default) |
| `surprised` | `surprise` 0.8 + `vowelO` 0.4 | 0.15 | 2000 (single default) |
| `think` | `troubled` 0.5 + `serious` 0.4 | 0.5 | 2000 (single default) |
| `awkward` | `troubled` 0.6 + `smile` 0.2 | 0.4 | 2000 (single default) |
| `question` | `troubled` 0.4 + `surprise` 0.2 | 0.4 | 2000 (single default) |
| `curious` | `surprise` 0.35 + `smile` 0.25 | 0.4 | 2000 (single default) |
| `neutral` | no influences | 0.6 | immediate (no auto-reset) |

### Live2D (GDCubism) backend — exp3 resolution, NOT fixed morph names

Live2D uses model-authored `.exp3` blend shape files; Godot must discover them at load and build the `emotion key → local expression/motion` mapping from the card's model metadata (research doc §3.1, R3). Resolution precedence:

1. `emotionMappings` (fileName → emotion key) direct match.
2. Case-insensitive `availableExpressions.name` match.
3. Keyword cluster fallback: `happy`→`happy/smile/joy/laugh/glad/fun/喜/笑`; `sad`→`sad/cry/tear/sorrow/depressed/泣/悲`; `angry`→`angry/anger/mad/frown/disgust/upset/hate/怒`; `surprised`→`surprise/shock/gasp/驚`; `think`→`think/confused/what/困/思`; `awkward`→`blush/shy/embarrass/red/照/恥`.
4. Raw pass-through (model-specific names).
5. No-op with warning.

### Spine backend

Emotion → animation name via `EMOTION_SpineAnimationName_value`, falling back to raw name then any existing animation (`packages/stage-ui-spine/src/constants/emotions.ts:50-66`).

## VFX cues → Godot particle/aura triggers

| VFX key | Godot target (proposed) | Duration |
|---|---|---|
| `fire` | `VFX/FireAura` (proposed GPUParticles3D node) | as specified in ACT payload |
| `electric` | `VFX/ElectricArc` (proposed) | as specified in ACT payload |
| `magic` | `VFX/MagicBurst` (proposed) | as specified in ACT payload |
| `verdant` | `VFX/VerdantGlow` (proposed) | as specified in ACT payload |

## Resolution rules (R3)

1. Direct expression name match (model authored).
2. Case-insensitive `expressionMap` scan.
3. Fuzzy keyword cluster (Live2D only).
4. Raw pass-through (model-specific names like `heart`, `star_eyes`).
5. No-op with warning.

## Godot implementation contract

- **Cross-fade**: all weights lerp to 0 over `blendDuration` while target fades in (R5–R10). Use `Tween` or `AnimationTree` blend spaces.
- **Hold-then-reset**: transient cues hold for `duration_ms` (default 2000 ms), then auto-reset to neutral unless `duration_ms = 0` (immediate) or absent (no reset).
- **Hold default**: single 2000 ms — Live2D uses `Math.max(0.1, duration ?? 2) * 1000` (`packages/stage-ui-live2d/src/stores/live2d.ts:351`); VRM takes ms from caller via `setEmotionWithResetAfter(name, ms, …)` (`packages/stage-ui-three/src/composables/vrm/expression.ts:202`). Override via `duration_ms` in `emotion.tag` payload; `0` = immediate reset, absent = no auto-reset. No per-emotion holds exist in TS source.
- **Lip-sync**: RMS → `aa` morph, attack snap, decay `dt/0.120`, clamp (research doc §3.5 alg 1). Viseme path is optional upgrade.
- **Do NOT port** TS glue (parser, queues, stores, easing composables). Godot consumes `emotion.tag` daemon events only (research doc §4).
- **Do NOT promise** 30–60 Hz lip-sync; in-tree tap is ~15–40 Hz (research doc §3.5).