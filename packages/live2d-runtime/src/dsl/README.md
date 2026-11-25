# Live2D DSL runtime — source of truth

This directory holds the headless Live2D DSL virtual machine: the parser, the reactive
`VarFloats` heap, the eligibility selector, the template compiler and the dispatcher. It is
the single source of truth for the manifest "special sauce" semantics (custom motion-group
entries that `pixi-live2d-display` strips before WebGL init because they carry no `File`).

Migrated from `docs/design-live2d-dsl-interpreter-spec.md` and
`docs/design-live2d-dsl-test-cases.md` (both now architecture pointers). Host-side
rendering, the `change_cos` bottleneck and multi-`.moc3` ingestion live in
`packages/stage-ui-live2d/src/runtime/README.md`.

## Module map

| Module | Responsibility |
| :--- | :--- |
| `types.ts` | Manifest wire format (PascalCase keys, `#lane`/` :item` hints). |
| `var-store.ts` | `ReactiveVarStore` — the `VarFloats` heap, atomic guard+mutation. |
| `selector.ts` | Eligibility pipeline: guards → intimacy → `TimeLimit` → weighted pick. |
| `command-parser.ts` | `;`-delimited `Command` / `PostCommand` chain parser. |
| `template.ts` | `{$vi_*}` / `{$vf_*}` / `{$intimacy}` / `{$timenow}` / `{$br}` interpolation. |
| `interpreter.ts` | `DSLVirtualMachine` — dispatch, mutation, commands, intimacy write-back, choices, `NextMtn`. |
| `../ports.ts` | The only output surface (port interfaces). |

The VM never imports PIXI/Vue/DOM. A host implements the ports; tests inject fakes.

## 1. Stateful reactive store (`VarFloats`)

Two VarFloat kinds, applied **atomically** per entry (every Type 1 guard must pass before any
Type 2 mutation runs; mutations never partially apply):

- **Type 1 — conditional guard**: `{"Name": "stop", "Type": 1, "Code": "equal 1"}`. Failure
  discards the candidate interaction.
- **Type 2 — state modifier**: `{"Name": "ChatTimer", "Type": 2, "Code": "assign rand(20,25)"}`.

Condition ops (`CONDITION_OPS`): `equal`, `not_equal`, `greater`, `greater_equal`, `less`,
`lower` (alias of `less`), `lower_equal`.
Mutation ops (`MUTATION_OPS`): `assign` (literal or `rand(min,max)` inclusive integer),
`add`, `subtract`, `init` (assign-if-absent — the flag-heap idiom; existing values win).
Unrecognized op tokens are no-ops, never throws. Absent names read as `0` (manifest
convention). `rand()` is the deterministic injection point (`ReactiveVarStore(random)`).

```typescript
interface VarFloat {
  Name: string
  Type: 1 | 2 // 1 = Condition, 2 = Assignment
  Code: string
}
```

## 2. Branching choice overlay (`Choices`)

Choices are compiled and rendered as floating glassmorphic buttons composed over the stage
(not detached dialog windows): `backdrop-filter: blur(12px) saturate(180%)`, gradient border,
hover micro-animation. Labels containing `{$vi_IntimacyVI}`-style tags are interpolated with
the live heap before render. Selecting a choice resumes the VM via `selectChoice(index)`,
which follows that choice's `NextMtn`.

The VM suspends the chain while a menu is pending (`hasPendingChoices()` /
`getPendingChoices()`); the host renders `IEventEmitter.showChoices` and calls back.

## 3. Instruction sequencer (`Command` pipeline)

Grammar (lane-aware), parsed by `parseCommandChain` / `parseMotionRef`:

```text
start_mtn B40                          -> { group: 'B40' }
start_mtn Sound#1:011501_051_01_01     -> { group: 'Sound', lane: 1, item: '011501_051_01_01' }
start_mtn Face#2:07;clear_exp          -> sequential chain, split on ';'
change_cos model1.json                 -> costume swap by sibling manifest path
change_cos 2 / change_cos #2           -> costume swap by numeric slot ('#' stripped)
ChangeCos 1                            -> verbs are case-insensitive
motions enable/disable Leave60_70_80   -> motion-pool gate
mouse_tracking enable/disable          -> gaze tracking gate
eye_blink enable/disable               -> blink gate
stop_sound 2                           -> stop audio channel 2
replace_tex 0 Motions_x.png            -> texture slot swap
hit_areas enable head,menu             -> collider gate (',' or '，' separated)
```

Unrecognized verbs are preserved as `{ kind: 'noop', raw }` so sequencer ordering stays
intact and hosts can introspect them.

Execution order inside `executeEntry`: atomic `VarFloats` → `Command` chain → bound
`Sound`/`Expression` → intimacy `Bonus` write-back → interpolated `Text`/`Choices` →
`PostCommand` → `NextMtn` hop (loop-guarded by `maxHops`, default 64; a runaway chain emits
`showText` with a `[live2d-runtime] NextMtn chain exceeded …` notice instead of hanging).

`start_mtn` is dual-purpose: it always drives `IMotionSink.startMotion`, and when the target
names a group the VM also dispatches it as a DSL group.

## 4. RPG intimacy gating

```json
{
  "Intimacy": { "Min": 27450, "Max": 50000, "Bonus": 300 },
  "Weight": 4,
  "NextMtn": "HappyReaction"
}
```

- `Min`/`Max` gate eligibility (absent bound = open); `Intimacy: {}` is a no-gate stub.
- `Bonus` is written back to `IIntimacyStore.addIntimacy` on success and mirrored through
  `IEventEmitter.onIntimacyChanged(next, delta)`.
- Raw scores are model-author-native (0..`DSL_INTIMACY_MAX` = 100 000, see
  `packages/stage-ui-live2d/src/stores/dsl-intimacy.ts`); the HUD shows a normalized 0–100
  projection. The heap is per-load and ephemeral; intimacy is persisted per model id.
- `TimeLimit.Month` marks the first month of a quarter `[Month, Month+2]` (3/6/9/12),
  wrapping the year boundary; `Sustain` is an author duration budget and does not gate.

## 5. Delta ticking engine (auto-ticks & heartbeats)

A host-driven tick loop (500–1000 ms) subtracts delta from countdown variables
(`ChatTimer = ChatTimer - deltaTime`); when `ChatTimer <= 0` the VM rolls a random pick,
dispatches an idle/conversational nudge group, plays the idle motion and re-seeds the timer
(`ChatTimer = rand(20,25)`). The runtime itself stays clock-agnostic: it reads `IClockLike`
from the ports and never owns a timer.

## 6. Dating Sim Blend staging vision

Single-window visual-novel staging: generative background (Artistry/ComfyUI concept stack)
+ Live2D character + subtitle overlay + branching choices, all layered in one canvas without
window spawns. Dialogue text interpolates `VarFloats` (player name, intimacy, time of day,
location); a text bubble coordinates the physical reaction, the pre-recorded voice line and,
when speech is generated, lip-sync token mapping. A "Dating Sim Preferences" settings surface
owns the DSL toggles. Historical concept; the implemented subset is the VM above plus the
host bridge in `packages/stage-ui-live2d/src/runtime/`.

## 7. Test cases — model acquisition & verification

The reference corpus is a curated set of stateful Steam Workshop Live2D packages, packaged
with the external `steam-lpk-packager` helper (`.lpk` asset packages):

```bash
git clone https://github.com/dasilva333/steam-lpk-packager.git
# inside steam-lpk-packager:
python process_batch2_safe.py batch-dsl-test-cases.txt
```

The packager downloads, extracts and moves each model into the correct asset sub-folders.
Drop the generated directories into the Airi asset/cache paths
(`packages/stage-ui-live2d/` or the dev runtime cache).

Manifest features to cover, by workshop id:

| Model id | DSL feature |
| :--- | :--- |
| `live2d_2883004043`, `live2d_3626567931` | `Choices` menus — `{"Text": "Option", "NextMtn": "A"}` |
| `live2d_2262182171` | Command + intimacy hooks — `{"Command": "start_mtn Face#2:01", "Intimacy": {"Min": 20, "Bonus": 1}}` |
| `live2d_3626567931` | Stateful vars — `{"Name": "DoubleClickTimer", "Type": 2, "Code": "assign 0"}` |

Verification checklist:

1. Commands parse and run: `clear_exp`, `start_mtn`, `change_cos`, dynamic UI buttons.
2. Intimacy/tension map into the active session store (`"Intimacy": {"Min": 80, "Bonus": 1}`).
3. Conditional branches fire on intimacy level and expression state.
4. `pnpm -F @proj-anima/live2d-runtime test` (parser, heap, selector, template, interpreter,
   extracted-model integration, headless scenario runner).

Per-model DSL payload extraction is documented in `docs/research-live2d-special-sauce.md`
(raw manifest survey, 220 KB) — that file remains the corpus evidence, not a spec.
