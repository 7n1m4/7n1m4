# stage-ui scenes — caption surfaces (source of truth)

Source of truth for the caption/subtitle overlay system: the Electron caption window surface,
the shared typography panel, the Sentence Sync protocol, and the in-scene head-tethered comic
plank (Pixi for Live2D, screen-space Canvas2D for VRM/MMD/Spine).

Migrated from `docs/design-captions-widget-system.md` and
`docs/design-head-tethered-captions.md` (both now architecture pointers).
Pose→transform math lives in `packages/stage-shared/src/utils/caption-perspective.ts`; the
sentiment/trigger analyzer and micro-pacer live in
`packages/stage-shared/src/utils/caption-sentiment.ts`; Canvas2D vector helpers in
`packages/stage-shared/src/utils/caption-canvas2d.ts`; the Live2D Pixi adapter in
`packages/stage-ui-live2d/src/composables/live2d/head-tethered-caption.ts`.

## 1. File map

| Path | Role |
| :--- | :--- |
| `apps/stage-tamagotchi/src/main/windows/caption/index.ts` | Caption window manager (Electron main): creation, transparency, screen bounds, docking. |
| `apps/stage-tamagotchi/src/renderer/pages/caption.vue` | Caption window entry point; click-through + drag controls. |
| `CaptionPanel.vue` | Core DOM presentation: scale, opacity, dark/light capsule, active-word highlight, transitions. No pose logic. |
| `HeadTetheredCaption.vue` | Live2D host wrapper: frame loop + Sentence Sync + micro-pacer; polls `live2dApp()` until the PIXI canvas boots. |
| `HeadTetheredCanvas2D.vue` | Screen-space Canvas2D overlay for VRM/MMD/Spine; queries `getHeadPose()` from the 3D scene ref. |
| `ControlStripHost.vue` | Hardware/coordination host: ties TTS playback events to caption output. |
| `packages/stage-ui/src/stores/settings/captions.ts` | Persisted layout, font scale, docking, follow, head-tethered settings. |
| `apps/stage-tamagotchi/src/shared/eventa.ts` | Typed IPC channels for cross-process coordinate/attachment updates. |
| `packages/stage-ui/src/composables/use-speech-caption-player.ts` | Reference Sentence Sync producer (per-sentence TTS + caption broadcast). |

## 2. Settings, docking & behavior (v4+)

- **Follow-stage split** — `captionFollowStageVisibility` (mirror the Actor Stage window's
  visibility) and `captionFollowStagePosition` (anchor to the Actor Stage window coordinates).
  The legacy ambiguous `captionFollowStage` is gone.
- **Docking (`captionDocking`)** — `none` (free-floating, user-dragged), `top` / `bottom`
  (hard against that edge of the Actor Stage), `character-head` (experimental: head-tethered
  renderer instead of window positioning).
- **Immediate save** — any user resize/drag persists at once; with
  `captionFollowStagePosition` the relative offset `(dx, dy)` is recalculated and stored.
- **Theme (`captionThemeMode`)** — `dark` (translucent dark capsule), `light` (translucent
  light capsule, high-contrast text), `system` (inherit global mode). Opacity is a backing
  alpha percentage (0% transparent, 20% light, 50% medium, 80% opaque).
  Drift: the `caption-theme-mode` control-strip case calls `switchToNextTheme()` from
  `useTheme()` (global theme cycle: light/dark/system), not a caption-specific persisted
  field; no `captionThemeMode` field exists in `stores/settings/captions.ts` — this is a
  global-theme alias, not a caption setting.
- **Head-tethered (this directory)** — `headTetheredCaptionEnabled` (independent toggle,
  `captions-layout` group, second row after the `caption` master toggle), fixed
  `headTetheredCaptionOffset = { x: 0, y: -15 }`, `headTetheredCaptionFollowStrength` 0–100.
  No config-version bump; customizer-only (no Settings panel row); single global toggle;
  single actor; off ⇒ container/ticker destroyed (zero residual render cost). Multi-format
  rollout: Phase 1 Live2D (active), Phase 2 VRM/MMD/Spine via the shared Canvas2D overlay.
- **Control-strip actions** (`use-control-strip-action.ts`): `head-tethered-caption` toggles the plank,
  `caption-docking` cycles `none → bottom → top → head`, `caption-sync-position` / `caption-sync-visibility`
  toggle the follow flags,
  `caption-layout-mode` flips single/multi,
  `caption-theme-mode` currently just cycles the global theme (no caption-specific field yet).

## 3. Sentence Sync protocol

Data channel: `BroadcastChannel('airi-caption-overlay')` (VueUse `useBroadcastChannel`):

```typescript
type CaptionChannelEvent
  = | { type: 'caption-speaker', text: string } // active speaker name (e.g. "User")
    | { type: 'caption-assistant', segments: CaptionSegment[] } // streamed sentences

interface CaptionSegment {
  text: string // this sentence/chunk
  color: string // display color (character identity color)
  actorId: string // "user" or card id
  isActive?: boolean // MUST be true only for the segment currently playing
}
```

Lifecycle when an audio session begins:

1. **Sentence split** — the spoken block is split on punctuation (`/(?<=[.!?])\s+/`).
2. **Audio pre-fetch** — audio per chunk is generated and preloaded.
3. **Active progression** — when chunk `i` starts, broadcast all segments `0..i-1` with
   `isActive: false` plus chunk `i` with `isActive: true`; on completion flip `i` to `false`
   and rebroadcast. The renderer scales/glows/brightens only the `isActive` segment.
4. **Turn boundary** — on user-message ingestion or a new speech turn, broadcast
   `{ type: 'caption-assistant', segments: [] }`; `CaptionPanel.vue` also listens to
   `airi-chat-stream` `session-updated` for `role === 'user'` and clears locally.

Client rules: never post isolated text chunks without the accumulated context; always
`clearCaption()` (speaker `''` + empty segments) on completion.

## 4. Head-tethered plank — architecture

```text
@proj-anima/stage-shared
  • analyzeCaptionSentence(text)   (5-tier triggers, negation filter, exclusions)
  • CaptionEffectCue / AnalyzedSentenceEffects
  • poseToCaptionTransform(...)    (squash, skew, roll perspective math)
  • subChunkText(text, maxChars)   (micro-pacer clause splitter)
        │ emits { effects, transform, anchor }
        ├───────────────────────────────┐
        ▼                               ▼
  stage-ui-live2d                 Screen-Space Canvas2D
  PIXI.Graphics / Container       CanvasRenderingContext2D
  (native Pixi WebGL)             (VRM, MMD, Spine — HeadTetheredCanvas2D.vue)
```

| Renderer | Engine | Head anchor | Surface |
| :--- | :--- | :--- | :--- |
| `live2d` | Pixi.js v6 | `coreModel` params + drawable bounds | In-stage PIXI child, native Pixi transform |
| `vrm` | Three.js | `vrm.humanoid.getNormalizedBoneNode('head')` | Canvas2D overlay; `project(camera)` + Euler yaw/pitch/roll |
| `mmd` | Three.js | `skeleton.bones['頭']` / `neck` | Canvas2D overlay (shared with VRM) |
| `spine` | Spine-WebGL | `skeleton.findBone('head')` | Canvas2D overlay; `(bone.worldX, bone.worldY)` direct |
| none/configure | — | — | fall back to the Electron caption window |

Canvas2D was chosen over `CSS3DObject` (multi-renderer sync overhead, blurry FOV rasterization)
and pure CSS/DOM (cannot draw starburst outlines, 60 FPS sine tails, masked particles): it has
1:1 syntax parity with PIXI's vector model (`beginPath`, `bezierCurveTo`, `arcTo`, `clip`),
Retina-sharp, zero GPU texture uploads.

## 5. Pose snapshot & perspective math

Per frame, each adapter fills a `PoseSnapshot` (`yaw`, `pitch`, `roll`, each clamped to
[-1, 1]; Live2D divides raw `ParamAngle*` by `PARAM_RANGE = 30`) plus an `AnchorPoint` in
stage space, then calls `poseToCaptionTransform`:

```text
strength = perspectiveStrength(anchor) * followStrength     // 0..1
x        = clamp(headYaw / 30,   -1..1)
y        = clamp(headPitch / 30, -1..1)
flatten  = |x| * 0.18 * strength
scaleX   = 1 - flatten                    // squash as the head turns
scaleY   = 1 + |y| * 0.04 * strength
skewX    = x * 0.10 * strength
skewY    = -y * 0.04 * strength
rotation = headRoll in radians (±0.35 rad ≈ ±20°)
position = anchor stage-space point + user offset
```

Pixi maps 1:1 to `position.set` / `scale.set` / `skew.set` / `rotation` / `alpha`; DOM/CSS maps
to `matrix3d(...)` or split `translate / skew / scale / rotate`. Frame cadence: after the model
pose update, before canvas present — Live2D uses `app.ticker` at `UPDATE_PRIORITY.LOW`.

Anchor fallbacks (Live2D): drawable mesh names (`head`, `hair`, `face`, `頭`, `顔`, `髮`) →
top-center bounding box `(bounds.x + bounds.width * 0.5, bounds.y + min(height*0.02, 15))`.
Parameter ids are resolved through `PARAM_ID_ALIASES` (`ParamAngleX`, `PARAM_ANGLE_X`,
`ParamHeadAngleX`, `HeadAngleX`, `FaceAngleX`, `AngleX`, …), reading `coreModel._parameterIds`
/ `_parameterValues` (a `Float32Array` over WASM memory) first, then index enumeration, then
`getParameterValueById`; neutral angles fall back to `internalModel.focusController`.

## 6. Four-channel in-bubble effects

```text
Motion container
├── Bubble body + fill
├── Body mask
├── Interior effects container (mask = Body mask)
│   ├── Ambient layer
│   └── Interior accent layer
├── Rim/tail layer
├── Exterior accent layer
└── Text
```

Four orthogonal channels, one effect each, all concurrent; same-channel conflicts resolve by
`priority`, no cross-channel suppression:

1. `ambient` — continuous atmosphere (hearts, rain, cyber grid, starfield, mist).
2. `accent` — 250–600 ms pops/icons (lightbulb, impact ring, checkmark, sweat drop, `💢`).
3. `motion` — container spring/sine transforms (wobble, bounce, shake, breath, squash-stretch).
4. `rim` — vector border + tail limb poses (wag, heart-curl, droop, jagged starburst,
   scalloped thought cloud, frost rim, flower bloom).

```ts
export interface CaptionEffectCue {
  id: string
  channel: 'ambient' | 'accent' | 'motion' | 'rim'
  effect: string
  durationMs: number
  intensity: number // 0.0 .. 1.0
  priority: number // higher pre-empts lower in the same channel
}
```

Tail/border poses: `wag` (playful/cat), `heart-curl` (affection), `droop` (sadness),
`jagged-pointer` (anger/CAPS), `scalloped-cloud` (thinking/asides), `heartbeat-pulse`
(yandere), `frost-rim` (fear/cold), `flower-bloom` (gratitude/compliments).

`vectorBubblePathBuilder` (Pixi, `head-tethered-caption.ts`) and the Canvas2D helpers in
`caption-canvas2d.ts` emit **one closed outer path + one stroke pass** for connected
body+tail (no seams); disconnected decorations (thought dots) go through
`drawAuxiliaryShapes`. `drawInteriorMask` is body-only so ambient particles never leak into
the tail.

## 7. Trigger resolution hierarchy & catalog

5-tier priority (highest first): explicit `<|ACT:emotion|>` / `[bracket]` token → structural
patterns (stutters `u-um`, ellipses, CAPS, asides) → multi-word phrases (`I miss you`,
`what if`) → regex word boundaries (`\bmad\b`) → character persona defaults.

Rules: phrase priority resolves semantic conflicts (`"I'm not angry"`) without blocking
compatible structural effects (`"I miss you!!"` = sadness ambient + impact accent); negation
filtering suppresses the matched span only; all keywords use word boundaries; code blocks,
URLs and quoted user text are excluded before scanning.

| Trigger | Channels | Effect |
| :--- | :--- | :--- |
| Stutter `I-I`, `w-wait`, `u-um` | ambient+accent+motion | wobble + blush wash + sweat drop |
| Pause `...` `…` | ambient+motion | firefly dots + slow scale-down |
| Shock `!!` `!?` `[gasp]` | accent+motion | impact ring + speed lines + spring punch |
| Ponder `??` `hmm` `wonder` | ambient+rim | orbiting `?` + scalloped cloud |
| Laughter `haha` `hehe` `lol` | ambient+motion | confetti freckles + double hop |
| Affection `love` `cute` `darling` | ambient+rim | rising hearts + heart-curl |
| Compliment `pretty` `beautiful` | ambient+rim | blush wash + flower bloom |
| Gratitude `thanks` `appreciate` | rim | daisy/star blooms on border |
| Success `yay` `perfect` `we did it` | accent+motion | confetti + checkmark sweep + bounce |
| Epiphany `aha` `what if` | accent | lightbulb flash + idea rings |
| Apology `oops` `my bad` `sorry` | accent+motion | squash + sweat/bandage sticker |
| Sadness `sad` `miss you` `lonely` | ambient+rim | raindrops + droop + blue wash |
| Anger `angry` `hmph` `grr` | all four | starburst + `💢` + red pulse + shake |
| Yandere `mine` `jealous` `don't leave` | ambient+rim | vignette + black hearts + heartbeat |
| Fear `scared` `eek` `cold` | ambient+motion+rim | frost creep + tremble + frost rim |
| Sleepy `sleep` `yawn` `goodnight` | ambient+motion | floating `Z z z` + breathing scale |
| Cozy `cozy` `warm` `purr` | ambient+motion | sunbeam + dust motes + slow pulse |
| Music `sing` `hum` `la la` | ambient+rim | notes on a staff + waveform outline |
| Magic `magic` `wish` `spell` | accent | constellations draw, rotate, dissolve |
| Tech `analyze` `code` `data` | ambient | cyan scanline + grid drift + cursor |
| Glitch `error` `glitch` `404` | accent | RGB split + scanline tear + pixel recovery |
| Whisper `secret` `psst` | ambient+motion | dimmed edges + hush ripple |
| Food `yummy` `cake` `cookie` | accent | candy sprinkle icons on border |
| Cat `meow` `nya` `purr` | accent+rim | paw-print trail + tail wag |
| Boop `boop` `poke` `bonk` | accent+motion | contact ripple + elastic rebound |
| Self-correct `—no` `I mean` | accent | scribble cross-out + replacement pop |
| Elongated `soooo` `cuteeee` | motion | motif stretch scaled by repeat count |
| ALL CAPS | motion+rim | drop shadow + outline pulse + impact |
| Aside `(inner thoughts)` | rim | mini thought bubbles behind text |
| Countdown `3... 2... 1...` | accent | dots extinguish + confetti burst |

## 8. Micro-pacer

`subChunkText(text, maxChars = 80)` splits a long active segment at clause boundaries
(`~ , . ! ? ; — :`) or spaces into ≤80-char sub-phrases; each sub-phrase is its own comic
frame. Cadence ≈16 chars/sec (~250 ms/word), min 1.5 s per sub-phrase; the final sub-phrase
holds. `HeadTetheredCaption.vue` paces at 80 chars, `HeadTetheredCanvas2D.vue` at 75.

## 9. Performance & pooling guardrails

Max 16–32 active sprites across all channels, pre-allocated and recycled; one shared 512×512
icon atlas (`heart`, `star`, `dot`, `drop`, `flower`, `spark`, `music_note`, `paw`); zero
allocation inside `updateTick(timeMs)`; target <0.08 ms/frame.

## 10. Kinetic anchor paradigms

- **2D planar roll-tilt (Live2D, Spine)** — anchors from 2D bounds/planar skeleton
  (`ParamAngleZ`, `bone.getWorldRotationX()`); the bubble rolls and swings along the head
  crown arc when the character is dragged/tilted. Kinetic, tactile, comic-strip feel.
- **3D camera-projected (VRM, MMD)** — `headBone.getWorldPosition() + headUp * offset`
  through `PerspectiveCamera.project(camera)`; Euler yaw/pitch/roll feed
  `poseToCaptionTransform`. Rigid spatial stability, depth-consistent during orbits/zooms.

## 11. Implementation history — failure modes (keep when touching the adapter)

1. **`defineExpose` double-unwrap** — exposing `pixiApp` as a `Ref` and wrapping it in
   `computed` produced `ComputedRef<Ref<Application>>`; the plank silently never attached.
   Fix: `Live2D.vue` exposes `live2dApp: () => live2dCanvasRef.value?.pixiApp` (function
   accessor) and `HeadTetheredCaption.vue` polls it lazily.
2. **PIXI v6 `BatchRenderer` missing** — scoped `@pixi/graphics`/`@pixi/text` carry
   `pluginName = 'batch'`; the Cubism renderer never built `renderer.plugins.batch`, so
   `Graphics`/`Text` threw `Cannot read properties of undefined (reading 'MAX_TEXTURES')`.
   Fix: `ensureBatchRendererOnLiveRenderer(app)` constructs `new BatchRenderer(renderer)`,
   assigns it and calls `contextChange()` once.
3. **Anchor on the face** — `FALLBACK_HEAD_ANCHOR.y = 0.18` put the bubble over the eyes and
   the tail sheared sideways. Fix: top-center fallback at `bounds.y + min(h*0.02, 15)`, pivot
   at the tail tip, offset `{ x: 0, y: -15 }`, moderated skew multipliers.
4. **`getParameterCount() === 0`** — Cubism initializes `_model` lazily. Fix:
   `readCoreModelParamValue` reads `_parameterIds`/`_parameterValues` first (guard
   `typeof directValues.length === 'number'`, not `Array.isArray` — it's a `Float32Array`),
   then index enumeration, then by-id.
5. **Reactive proxy in the ticker** — reading `useLocalStorage` proxies at 60 FPS adds
   reactivity overhead. Fix: unwrap `offset` to plain numbers once at attach.
6. **PIXI v6 `lineStyle` signature** — object-form `lineStyle({ width, color })` (v7 API)
   corrupts batch state. Fix: positional `lineStyle(width, color, alpha, alignment)`.
7. **Static plank** — neutral idle angles sit at 0 and `Array.isArray(Float32Array)` is false.
   Fix: `typeof length === 'number'` guard + `focusController.x/y` fallback so cursor movement
   drives squash/shear/rotation.
8. **Long-segment clipping** — 180+ char active segments overflow the top of the screen. Fix:
   micro-pacer (§8).

## 12. Upstream synthesis (post-PR #2657)

Upstream `moeru-ai/airi` PR #2657 (`@chiba233`, commit `d3a51672b0ac`) added a presence
bubble: `stage-shared/src/presence-bubble/{advance,follow,painter,placement,content,clock}.ts`
(critically-damped spring `stiffness 170 / damping 20`, sub-step `1000/120`, arc-length
perimeter tail, `left/right/above` placement with hysteresis, 8-phase thinking dots over
unread badge), a perturbation-probing Live2D head source, Pixi/Three adapters and
`docs/ai/adr/2026-09-24-presence-bubble-in-canvas.md`.

Divergence: fork = Sentence-Sync TTS dialogue, 2.5D skew/squash, 6-alias + bbox anchor,
zero-upload Canvas2D for 3D runtimes, sentiment tail, persistent last line. Upstream = thinking
indicator, spring inertia, strict `ParamAngleX/Y/Z` probe (disables the bubble on unrigged
models), per-tick `CanvasTexture` uploads, 360° perimeter tail, no spoken text, vanish on turn
end.

Target synthesis: spring position (upstream) + 2.5D skew (fork); 3-tier anchor (perturbation →
alias table → 50%/18% bbox); arc-length tail + sentiment morphology; zero-upload Canvas2D for
VRM/MMD; four-state lifecycle — speaking > thinking > soft decay (3–5 s) > unread badge.

## 13. Cross-model visual parity test payloads

Post via DevTools (`new BroadcastChannel('airi-caption-overlay').postMessage({ type:
'caption-assistant', segments: [{ text, isActive: true, color }] })`) and verify the resolved
4-channel composition:

| # | Text | Expected |
| :-- | :--- | :--- |
| 1 | `Thank you so much, you are amazing! pretty...` | rim `flower-bloom`, ambient `stars` |
| 2 | `Don't leave me alone... sniff...` | tail `droop`, ambient `rain` |
| 3 | `Thank you... pretty sparkle star...` | rim `flower-bloom`, ambient `stars` |
| 4 | `You belong to me forever... 🖤` | ambient `vignette`, rim `heartbeat-pulse` |
| 5 | `Analyzing system telemetry and running data diagnostic...` | ambient `scanline` |
| 6 | `I really love spending time with you! ♡` | tail `heart-curl`, ambient `hearts` |
| 7 | `Nya~ meow! I want a treat right now! purr...` | tail `wagging` |
| 8 | `WHAT?! No way!! System diagnostic failed?!` | accent `flash-burst`, motion `bounce` |
| 9 | `Hmph! Shut up! Don't get the wrong idea! 💢` | body `jagged-starburst`, tail `jagged-pointer`, accent `anger-mark`, motion `shake` |
| 10 | `U-um... w-wait a second! b-dummy!` | ambient `blush`, accent `sweat-drop`, motion `wobble`, tail `heart-curl` |
| 11 | `Time to relax and have a warm cozy evening... yawn...` | ambient `sunbeam`, motion `breath` |
| 12 | `Hello there! I'm so happy to see you today! Let's work together… ✨` | micro-pacer sub-chunking |

Gates: `pnpm -F stage-ui typecheck && pnpm -F stage-ui-live2d typecheck`,
`pnpm -F stage-tamagotchi build`, manual smoke (toggle on → plank above head; turn head →
skew/flatten; toggle off → plank destroyed).
