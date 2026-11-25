# TS Emotion → Godot Expression Mapping

> Superseded/retired Godot mapping; retained as reference for Flutter native renderer parity.

Source: `docs/research-emotion-mapping-reference.md` (§1.1, §2 R1–R14). This doc is the Godot-side *target* mapping, not a re-survey of TS internals. Bead `airi-wxp.4.8` — OPEN/undecided.

## Canonical keys (TS → Godot AnimationTree state)

| TS emotion key | Godot state target | Hold default (ms) |
|---|---|---|
| `happy` | `happy` 0.7 + `aa` 0.2 | 2000 |
| `sad` | `sad` 0.7 + `oh` 0.15 | 2000 |
| `angry` | `angry` 0.7 + `ee` 0.3 | 2000 |
| `surprised` | `surprised` 0.8 + `oh` 0.4 | 1500 |
| `think` | `think` 0.7 | 2500 |
| `awkward` | (raw fallback) + `troubled` 0.6 + `smile` 0.2 | 2000 |
| `question` | (raw fallback) + `troubled` 0.4 + `surprise` 0.2 | 2000 |
| `curious` | (raw fallback) + `surprise` 0.35 + `smile` 0.25 | 2000 |
| `neutral` | reset all to 0.0 | immediate (no auto-reset) |
| `cool` | `Pixel glasses` 1.0 | 3000 |

Cross-fade: all weights lerp to 0 over `blendDuration` (0.3–0.6 s) while target fades in (R5–R10). Transient cues hold then auto-reset to neutral unless `duration_ms = 0` (immediate reset) or absent (no reset).

## Payload consumed by Godot

`emotion.tag` event (see research doc §3.6): `{ actor_id, tag, intensity, duration_ms?, kind?, seq, ts_ms }`. Godot resolves `tag` via R3 precedence (direct → case-insensitive → fuzzy cluster → no-op). `kind` ∈ {emotion, motion, vfx}; motion/vfx never touch facial morphs (R4).

## Implementation notes

- Godot uses `Tween`/`AnimationTree` for cross-fade; do NOT port TS easing code (research doc §4 #8).
- Lip-sync: RMS → `aa` morph, attack snap, decay `dt/0.120`, clamp (research doc §3.5 alg 1). Viseme path is optional upgrade.
- Model-specific names (heart, star_eyes, etc.) pass through as raw strings (R2) and resolve via case-insensitive fallback.
- Do NOT port TS glue (parser, queues, stores); Godot consumes daemon events only.