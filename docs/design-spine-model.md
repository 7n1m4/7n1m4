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

### Key Packaging Rules:
1. **Subdirectory Variants:** `detectAllSpineLayouts` scans the ZIP and automatically populates `availableVariants` using the subdirectory names (`Basic Civvies`, `Safety Guard`, etc.).
2. **Internal Spine Skins:** Skeleton attachments/weapons (e.g., `Normal` vs `Gun`) are compiled inside the `.skel` binary and exposed via `availableSkins`.
3. **Shared Audio:** WAV files are placed at the root of the ZIP file to prevent duplication across outfit subfolders and allow flat blob URL lookup.

---

## 3. Extended Physics & Interaction Manifest (`model0.json`) — Forward-Planning Specification

> [!NOTE]
> **Implementation Status: Planned / Asset Pre-Baked**
> The `model0.json` manifest schema described below has been pre-baked into Trickcal Spine model packages to preserve tactile interaction metadata. AIRI's runtime loading pipeline (`spine-zip-loader.ts` and `Model.vue`) does not yet parse this manifest; this section serves as the canonical specification for the future physics and gesture integration roadmap.

Each outfit directory in a Spine package contains an extended `model0.json` manifest defining target interaction zones (`hit_areas`), spring-damper physical constants, bone follower relationships, and animation/audio event mappings (`motions`).

---

### 3.1 Schema Specification

```json
{
  "hit_areas": [
    {
      "name": "Character_Ball_Move",
      "id": "Character_Ball_Move",
      "type": "pull",
      "spring": {
        "stiffness": 1680,
        "damping": 20
      },
      "limits": {
        "maxStretch": 60,
        "maxBackward": 1,
        "perpRatio": 0.7
      },
      "follower": {
        "bone": "Character_Ball_Move_Re",
        "mode": "same"
      },
      "audio": {
        "pull": "SFX_Common_PullCheek.wav",
        "release": "SFX_Common_PullCheekEnd.wav"
      }
    },
    {
      "name": "Character_Pat",
      "id": "Character_Pat",
      "type": "tap"
    },
    {
      "name": "Character_Tickle",
      "id": "Character_Tickle",
      "type": "tap"
    }
  ],
  "motions": {
    "tap_Character_Ball_Move": [
      {
        "file": "Touch_End",
        "sound": "SFX_Common_PullCheekEnd.wav"
      }
    ],
    "tap_Character_Pat": [
      {
        "file": "Pat_End",
        "sound": "SFX_Common_RubbingEnd.wav"
      }
    ],
    "tap_Character_Tickle": [
      {
        "file": "Tickle_End",
        "sound": "SFX_Tickle.wav"
      }
    ]
  }
}
```

---

### 3.2 Property Specifications

#### `hit_areas` Array
Defines interactive target zones mapped to specific Spine skeleton bones.

| Property | Type | Description |
| :--- | :--- | :--- |
| `name` / `id` | `string` | The target bone name in the Spine skeleton (e.g., `Character_Ball_Move`, `Character_Pat`). |
| `type` | `"pull" \| "tap"` | Interaction mode. `"pull"` designates spring-damper physics dragging (cheek stretch); `"tap"` designates touch gesture dispatching (head pat / smash / tickle). |

#### `spring` Object (Applies when `type == "pull"`)
Parameters for 2D spring physics simulation when pulling or releasing a mesh bone.

| Property | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `stiffness` | `number` | `1680` | Spring constant $k$. Higher values pull the bone back faster upon release. |
| `damping` | `number` | `20` | Damping coefficient $c$. Prevents infinite oscillation upon release. |

#### `limits` Object
Restricts maximum displacement to prevent mesh tearing or visual distortion.

| Property | Type | Default | Description |
| :--- | :--- | :--- | :--- |
| `maxStretch` | `number` | `60` | Maximum displacement (in WebGL canvas units) allowed outward from setup pose. |
| `maxBackward` | `number` | `1` | Maximum displacement allowed inward toward skeleton center. |
| `perpRatio` | `number` | `0.7` | Multiplier capping perpendicular drag displacement. |

#### `follower` Object (Optional)
Links a secondary bone to move symmetrically with the primary dragged bone.

| Property | Type | Description |
| :--- | :--- | :--- |
| `bone` | `string` | Name of follower bone (e.g., `Character_Ball_Move_Re` for opposite cheek). |
| `mode` | `"same" \| "mirror" \| "none"` | `"same"` moves follower in parallel; `"mirror"` mirrors displacement across vertical axis. |

#### `audio` & `motions` Mapping
* `audio.pull` / `audio.release`: Shared WAV audio files located at package root to trigger during drag and release events.
* `motions`: Event dictionary mapping interaction triggers (`tap_Character_Pat`, `tap_Character_Tickle`) to Spine animation clip names (`Pat_End`, `Tickle_End`) and SFX audio files.

---

### 3.3 Planned Runtime Implementation Strategy

When AIRI's Spine interaction engine is updated to support this schema:

1. **Loader Parsing:** `spine-zip-loader.ts` will parse `model0.json` during outfit ZIP extraction and expose the manifest on the active model object.
2. **Dynamic Bone Binding:** AIRI will locate skeleton bones matching `hit_area.name` and attach 2D hitboxes centered on bone world coordinates.
3. **Physics Simulation Loop:** Dragged displacement will be clamped against `limits.maxStretch`. On pointer release, the animation loop will step Hooke's Law ($\vec{F} = -k \vec{x} - c \vec{v}$) frame-by-frame until the bone returns to its setup pose.

---

## 4. Hit Detection Architecture

The interaction engine in `Model.vue` supports dual hit-detection modes configured via `spineStore`:

### Modes
1. **Mesh / Bounding Box Mode (`'bounds'` - Default):**
   Performs exact point-in-polygon / ray-cast intersection on Spine bounding box attachments (`BoundingBoxAttachment`) or rendered meshes projected through WebGL canvas coordinates.
2. **Radial Distance Mode (`'radial'`):**
   Fallback mode computing 2D Euclidean distance around bone origin points:
   $$\text{dist} = \sqrt{(\text{targetX} - \text{boneCanvasX})^2 + (\text{targetY} - \text{boneCanvasY})^2}$$
   Distance is evaluated against `radialHitRadius` (configurable from 10px to 250px).

### Gesture & Tactile Interaction Mechanics

The Spine interaction engine processes gestures using dedicated gesture state machines bound to target bones:

```text
                          Pointer Down / Touch
                                   │
               ┌───────────────────┴───────────────────┐
               ▼                                       ▼
     Bone: Character_Pat                    Bone: Character_Tickle
               │                                       │
      ┌────────┴────────┐                     ┌────────┴────────┐
      ▼                 ▼                     ▼                 ▼
   Tap (<280ms)    Drag (>6px)          Slow Swipe        Fast Swipe (>10k px/s)
[Smash / Bonk]     [Head Pat]        [Tickle_Idle_1]     [Tickle_Idle_2 (Furious)]
 (Smash_End_1/2)   (Pat_Idle)                │                 │
                                             └────────┬────────┘
                                                      ▼
                                                [Tickle_End]
```

1. **Head Bonk / Smash (`smash`):**
   - **Target Bone:** `Character_Pat`
   - **Trigger:** Quick tap on head ($\text{duration} \le 280\text{ms}$, swipe $< 6\text{px}$).
   - **Animation Pipeline:** Plays two-stage reaction: `Smash_End_1` (impact) transitioning into `Smash_End_2` (stunned/dizzy recovery loop).

2. **Head Pat (`pat`):**
   - **Target Bone:** `Character_Pat`
   - **Trigger:** Dragging pointer beyond $6\text{px}$ threshold.
   - **Animation Pipeline:** Switches to `Pat_Idle` and follows pointer with exponential smoothing (`dragFollow: 8`, `dragRadius: 50`). Plays `Pat_End` on release.

3. **Tickle / Furious Gestures (`tickle`):**
   - **Target Bone:** `Character_Tickle`
   - **Velocity Metric:** $\text{speed} = \frac{\sqrt{\Delta x^2 + \Delta y^2}}{\Delta t} \times 1000$ (px/sec).
   - **Normal Tickle ($\text{speed} < 10,000$ px/s):** Triggers `Tickle_Idle_1`.
   - **Furious Tickle ($\text{speed} \ge 10,000$ px/s):** Triggers `Tickle_Idle_2` (intense animation loop).
   - **Release:** Plays `Tickle_End`.

4. **Cheek / Ball Pull (`ballPull`):**
   - **Target Bones:** `Character_Ball_Move` & follower `Character_Ball_Move_Re`
   - **Physics:** Hooke's Law spring damper ($\text{stiffness} = 1680$, $\text{damping} = 20$).
   - **Animation Pipeline:** Triggers `Touch_Idle` while stretched, returning to setup pose with `Touch_End` SFX on release.

### Settings & Controls
* `hitDetectionMode`: `'bounds' | 'radial'` (Persisted in `settings/spine/hit-detection-mode`).
* `radialHitRadius`: `number` (Persisted in `settings/spine/radial-hit-radius`).
* UI Controls located under **Settings ➔ Advanced (Spine)** in `spine.vue`.

---

## 5. Downstream AI & `ModelCustomizer` Mapping

The AI actor interacts with the 3D Spine model exclusively via `<|ACT: ...|>` tokens generated during dialogue. `ModelCustomizer` categorizes and exposes Spine features into two distinct tabs:

```text
                                 ModelCustomizer
                                        │
           ┌────────────────────────────┴────────────────────────────┐
           ▼                                                         ▼
     Emotions Tab                                               Motions Tab
(Persistent Visual States)                                 (Time-Based Animations)
 ├── Outfits/Variants: "Safety Guard"                       ├── Actions: "Happy_1", "Eat_1"
 └── Skins/Attachments: "Gun"                               └── Reactions: "Panic_1", "Taunt_1"
```

### Exact Token Mapping:
* **Variant / Outfit Switch:** `<|ACT:emotion="Safety Guard"|>`
* **Weapon / Attachment Swap:** `<|ACT:emotion="Gun"|>`
* **Motion Action:** `<|ACT:motion="Taunt_1"|>`
* **Combined Performance:** `<|ACT:emotion="Gun",motion="Taunt_1"|>`

---

## 6. Key Code Entry Points

| Component / Subsystem | File Path |
| :--- | :--- |
| **Spine Scene Model** | [`packages/stage-ui-spine/src/components/scenes/spine/Model.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-spine/src/components/scenes/spine/Model.vue) |
| **Spine ZIP Loader** | [`packages/stage-ui-spine/src/utils/spine-zip-loader.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-spine/src/utils/spine-zip-loader.ts) |
| **Spine Store** | [`packages/stage-ui-spine/src/stores/spine.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui-spine/src/stores/spine.ts) |
| **Spine Settings UI** | [`packages/stage-ui/src/components/scenarios/settings/model-settings/spine.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/components/scenarios/settings/model-settings/spine.vue) |
| **Unified Customizer** | [`packages/stage-ui/src/components/scenarios/settings/model-settings/ModelCustomizer.vue`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/components/scenarios/settings/model-settings/ModelCustomizer.vue) |
| **Capabilities Resolver**| [`packages/stage-ui/src/stores/display-models.ts`](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/packages/stage-ui/src/stores/display-models.ts) |
