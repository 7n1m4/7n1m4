# stage-ui-live2d runtime — source of truth

Host side of the Live2D DSL: the adapter that binds the headless VM
(`@proj-anima/live2d-runtime`, see `packages/live2d-runtime/src/dsl/README.md`) to the live
`pixi-live2d-display` model, the pre-sanitize manifest capture, and the `change_cos` /
multi-`.moc3` design record.

Migrated from `docs/design-live2d-change-cos-challenge.md` and
`docs/design-live2d-multimoc-changecos.md` (both now architecture pointers).

## Files

| Path | Role |
| :--- | :--- |
| `live2d-runtime-adapter.ts` | Implements the VM output ports over the model's own managers; defers view effects to `RenderHostActions`. |
| `dsl-capture.ts` | Captures raw `FileReferences.Motions` DSL entries before `ZipLoader.unzip` sanitizes them. |
| `../utils/live2d-zip-loader.ts` | Zip ingestion, CP437/mojibake path recovery, CDI/EXP extraction, fake-settings synthesis. |
| `../stores/dsl-intimacy.ts` | Raw per-model intimacy (0..`DSL_INTIMACY_MAX`), localStorage-backed. |
| `../composables/live2d/head-tethered-caption.ts` | In-stage Pixi caption plank (see `packages/stage-ui/src/components/scenes/README.md`). |

## Adapter contract

`Live2DRuntimeAdapter` is additive. It never replaces the existing motion/beat-sync/ArtMesh
pipeline, it only implements the ports by delegating to facilities `Model.vue` already owns.
`buildAdapterPorts(adapter)` yields `{ motion, sound, tracking, events }`; the caller wires
`costume`, `intimacy` and `clock` into `VMOptions`.

Cross-window bridge (`BroadcastChannel('live2d-dsl-bridge')`, no cross-package import):
`dsl-choices` (VM → dating-sim overlay), `dsl-choice-selected` (overlay → VM, matched by
`requestId`), `dsl-widget-dispatch`, `dsl-widget-command`, `dsl-intimacy-changed`
(`next` raw + `display` normalized 0–100).

Sound uses one `HTMLAudioElement` per channel (0 = voice, 1 = BGM, 2 = ENV); without a
`resolveAssetUrl` resolver, opaque zip/OPFS assets are skipped but motion continues.

## `change_cos` dependency bottleneck (design record)

Creator packs (SoulTide, Alice, Gura, Saba …) swap costume/stance with
`change_cos <manifest>.json`. Under Live2DViewerEX this swaps the skeleton (`.moc`/`.moc3`)
inside one viewport wrapper. AIRI has two constraints:

1. **No Cubism 1/2 support** — legacy `.moc` is not renderable.
2. **Split-on-import** — a ZIP with N `.moc3` skeletons becomes N standalone library models.

Why it is a core dependency, not an optional extra:

- **Mesh/collider coupling** — `hit_areas` bind to vertex ids in the active `.moc3`
  (`{"hit_areas": [{"name": "head", "id": "D_FACE.00"}, {"name": "menu", "id": "D_HAIR_BACK.04"}]}`).
  A failed swap leaves the interpreter reading hit areas/motions that don't exist on the
  active skeleton.
- **Motion incompatibility** — `.motion3.json` is compiled against one skeleton's parameter
  ids; running Costume B's motion on Costume A glitches or freezes.
- **Menu gating divergence** — menus load from the active manifest; staying on one config
  while state advances desynchronizes menu text from the worn costume.

Two architectural paths were weighed:

- **Option A — lookup mapping + actor-token bridge** (chosen direction): keep split-on-import,
  map manifest file ids (`model0.json` … `model6.json`) to standalone display ids, rewrite
  `change_cos` as a higher-level `<|ACTOR|>` swap, persist `VarFloats`/intimacy globally.
  Pro: no importer change. Con: viewport re-load overhead may miss the sub-second target.
- **Option B — unified multi-skeleton imports**: teach the importer to treat a multi-`.moc3`
  archive as one asset with a sub-model library and hot-swap `.moc3` + atlas in WebGL.
  Pro: faithful, seamless. Con: heavy importer + staging work.

Current state: the adapter's `onCostumeWillSwap` is a render-side hint no-op and
`Model.vue`'s `changeCostume` is a stub — `change_cos` is **deferred** until ingestion lands.
The heap and intimacy are already preserved across the swap by construction
(`DSLVirtualMachine` never touches them on `change_cos`).

## Multi-MOC packages, hot-swap & ingestion normalization (design record)

Upstream `moeru-ai/airi` hardcodes `model0` in multi-MOC zips and ignores the rest; it has no
stateful DSL, intimacy or costume switching. This fork extracts and captures the raw manifest
DSL groups in `live2d-zip-loader.ts` + `dsl-capture.ts` and normalizes assets into
OPFS/IndexedDB model stores, but has not built the multi-MOC VRAM registry.

**Anti-pattern:** wiring `change_cos` back to disk/OPFS re-ingestion. Re-fetching costs a
100–500 ms visible stutter and re-instantiating the model store resets the VM heap
(`VarFloats`, intimacy, expression flags) — destroying character memory.

**Target pipeline (in-memory MOC3 hot-swap, single frame boundary, <16 ms):**

```text
1. DSL VM triggers ChangeCos("gura_casual")
   └─► Heap state (Intimacy, VarFloats, Active Expressions) PRESERVED.
2. Live2dCostumeRegistry lookup
   └─► Fetches pre-parsed .moc3 ArrayBuffer & texture atlas from RAM/OPFS.
3. WebGL buffer hot-swap
   ├── Pause render ticker for 1 frame.
   ├── Unbind previous MOC3 vertex/index buffers & textures.
   ├── Bind target MOC3 geometry & texture atlas.
   └── Re-attach shared physics controller & resume render ticker.
```

**Import UX for multi-`.moc3` archives** — the importer counts `.moc3` entries and, when
> 1, offers:

- *Unified character card with outfits (recommended)* — one gallery card, in-chat
  `ChangeCos` switching, single intimacy state, `N Outfits` badge, hover/click thumbnail
  cycling to pick the default outfit.
- *Split into N standalone cards* — normalize into independent gallery cards.

**Roadmap:** Phase 2 (current) finishes host intimacy `Bonus`, `MotionEnable`/`MotionDisable`
and VM reactivity for single-MOC models without touching the production zip uploader.
Phase 3 adds `MultiMocRegistry` in `live2d-zip-loader.ts`, the MOC3 pre-load + WebGL
hot-swap bridge, and the multi-costume import modal.
