# Native character rendering in Flutter (`airi-hxz1`) — implementation plan

Status: accepted plan artifact, 2026-11-25. Scope: dependency-ordered path from the current Flutter model-stage seam to native VRM, Spine and MMD rendering; Live2D stays behind its licensing gate. The Dart method-channel contract is frozen for this plan.

## What is already fixed, and why the plan is shaped this way

The Dart half of the stage landed in `airi-362h.2` and is a complete, tested seam. `apps/flutter/lib/ui/model_stage.dart` is the single routing entry point: it reads the card through `cards.get`, extracts `extensions.airi.{vrm,live2d,mmd,spine}` inline descriptors, and fails loudly (`unknown-model-kind`, `missing-asset`, `invalid-asset`) rather than fabricating a model; a card that names only `extensions.airi.displayModelId` is deliberately unresolved. `apps/flutter/lib/features/stage/model_stage_runtime.dart` owns one model's lifecycle (`load`/`lipSync`/`emotion`/`clear`/`dispose`) with a generation counter that drops stale async results and monotone `seq` guards on both sinks. `apps/flutter/lib/features/stage/model_backend.dart` is the seam every renderer must satisfy (`ModelBackend`, `NativeModelHandle(id, textureId)`, `ModelBackendRegistry.fromRuntimes`, `UnavailableModelBackend`, `RecordingModelBackend`). `apps/flutter/lib/features/stage/method_channel_backend.dart` is the cross-language contract: channel `org.moeru.airi/anima/model/<kind>`, methods `load{path,source}→{handle,textureId?}`, `setLipSync{handle,weight}`, `setEmotion{handle,tag,kind,intensity,seq,tsMs}`, `dispose{handle}`, with `MissingPluginException` mapped to `runtime-unavailable` and `PlatformException` mapped to its code. `apps/flutter/lib/features/stage/model_runtime.dart` is the single source of licensing/support policy and already marks Live2D with `ModelRuntimeBlocker.cubismLicense`. `apps/flutter/lib/features/stage/model_asset_resolver.dart` resolves a `file` in place and an `http(s)` URL into a content-named cache with atomic rename. `apps/flutter/lib/features/stage/model_expression.dart` carries the cue parser and the RMS smoother (attack snap, 120 ms linear decay) already proven against `crates/anima-channel/fixtures/lipsync/smoothing.basic.json` by both `crates/anima-render/tests/lipsync_conformance.rs` and `apps/flutter/test/stage_expression_test.dart`. `apps/flutter/lib/features/stage/native_model_surface.dart` already paints `Texture(textureId)` when the handle carries one, so presentation needs no Dart change.

Consequently every remaining line of work sits behind that seam: platform adapters, a real texture path, an id resolver, a real cache, and four renderers. The Rust side already holds the reusable algorithms — `crates/anima-render/src/vrm/*` (doc/geometry/materials/skin/springbone/morph/expression/lipsync/gaze/idle/engine), `crates/anima-render/src/spine/*` plus the C ABI in `crates/anima-render/cpp/spine_shell.h` and the vendored runtimes under `third-party/spine-runtimes/{4.0.64,4.1.00,4.2}/`, and `crates/anima-mmd/src/{pmx,vmd,rest_pose}.rs`. None of it renders; there is no `wgpu`/`glow`/vulkan dependency anywhere in the workspace, so the GPU layer is net-new.

## Phase 0 — Real cache directory and archive bundles

`apps/flutter/lib/features/stage/stage_screen.dart` currently passes `Directory.systemTemp` to `ModelAssetResolver`, which is wrong for a persistent model cache. Introduce an app-cache directory and port the bundle policy already written in `crates/anima-render/src/bundle.rs`: `<platform-data>/model-cache/<slug>-<hash>/`, a `.complete` marker plus `manifest.json`, extraction through a temporary sibling directory and a rename so a crashed extraction never poisons the cache, and the explicit rule that this is an app cache, not profile state. Extend `ResolvedModelAsset` in `apps/flutter/lib/features/stage/model_asset_resolver.dart` with a directory/bundle-root form, because Spine, MMD and Live2D are all multi-file archives while VRM is a single file; the single-file path must keep working unchanged.

**Gate C0:** `apps/flutter/test/stage_asset_resolver_test.dart` extended with archive extraction, cache-hit, and interrupted-extraction cases; whole `flutter test` green.

## Phase 1 — Resolve `displayModelId`

Real cards name a model by id, and `DisplayModel.fromCard` intentionally cannot resolve one. A daemon settings section exists (`StageModelSettings { model_id }` at `crates/anima-core/src/settings.rs:583`, surfaced as the `stage-model` key at `crates/anima-daemon/src/core.rs:74`), but the 36-verb registry (`docs/rosetta-stone.md:77`) has no display-model catalog verb. Either add one, or keep a client-local catalog; reference behaviour is `packages/stage-ui/src/stores/display-models.ts` (formats `vrm`, `live2d-zip`, `live2d-directory`, `spine-zip`, `pmx-zip`, `pmx-directory`, `pmd`) plus the remote manifests fetched in `packages/stage-ui/src/stores/sync-engine.ts:495-595`. Until this lands every real card keeps failing loudly, which is correct but is not parity.

**Gate C1:** the id-resolution decision recorded and the unresolved-id failure covered by a test in `apps/flutter/test/model_stage_router_test.dart`.

## Phase 2 — Plugin skeleton and real texture presentation

Create a Flutter plugin (suggested `packages/flutter_anima_render/`) that registers one GPU texture per model handle and pumps frames on the platform thread, leaving Dart holding only the integer id. Android wiring goes into `apps/flutter/android/app/build.gradle.kts`, `apps/flutter/android/settings.gradle.kts` and `apps/flutter/android/app/src/main/kotlin/com/example/anima_control/MainActivity.kt`; iOS into `apps/flutter/ios/Runner/AppDelegate.swift` and `apps/flutter/ios/Runner/GeneratedPluginRegistrant.m`. Desktop hosts must be created from nothing: `apps/flutter/` today contains only `android/`, `ios/`, `lib/`, `test/`, so `linux/`, `windows/` and `macos/` are new. This is the riskiest cross-language piece and must land before any renderer.

**Gate C2:** a plugin-level test that registers a texture and releases it on `dispose`, with all existing hermetic stage tests (`apps/flutter/test/stage_native_surface_test.dart`, `stage_runtime_test.dart`, `model_stage_lipsync_sink_test.dart`) still green via `RecordingModelBackend`.

## Phase 3 — Spine

Cheapest first renderer because the core is essentially finished: `crates/anima-render/src/spine/session.rs` (`load`, `skins`, `set_skin`, `animations`, `set_animation`, `set_default_mix`, `update`, `pages`, `collect_draws`), `atlas.rs`, `skeleton.rs`, `version.rs` (4.0/4.1/4.2 bucket detection), `animation.rs` (`EMOTION_TRACK`, `IDLE_TRACK`, `resolve_animation`, `resolve_idle`), driven through `airi_spine_create/load/update/collect_draws/destroy` with caller-sized buffers and no allocation inside the call. Native work is compiling `spine-cpp` plus `spine_shell.cpp` per platform (one runtime line only, selected as today by `AIRI_SPINE_RUNTIME`, default 4.2, per `crates/anima-render/build.rs`), uploading each `PageInfo` image as a texture, and translating `DrawCommand` batches into the GPU pipeline.

**Gate C3:** a synthetic skeleton (reuse the in-memory atlas/skeleton of `crates/anima-render/tests/spine_session.rs`) renders, and the three sinks are observable through a recording platform double.

## Phase 4 — VRM

The 3D pipeline is the large net-new piece; the model semantics are not. `crates/anima-render/src/vrm/doc.rs` extracts VRM 0.x and 1.0 extensions, `morph.rs::collect_morph_targets` keeps only expression-bound targets, `expression.rs::ExpressionEngine` implements ease-in-out-cubic with additive layering that never zeroes unmanaged morphs, `engine.rs` exposes `set_lip_sync`, `look_at`, `set_expression_weight`, `tick`, and `materials.rs` carries MToon parameters. Native work is the raster pipeline, MToon shading, texture upload and spring-bone integration, with `packages/stage-ui-three/src/components/Model/VRMModel.vue` and `packages/stage-ui-three/src/composables/vrm/expression.ts` as behaviour reference. Lip-sync is the `aa` morph; do not disturb blink.

**Gate C4:** a user-supplied `.vrm` renders with MToon and spring bones, `aa` follows real RMS frames, and an additive-safety test proves blink and lip-sync survive an emotion switch.

## Phase 5 — MMD

Reuses the Phase 4 pipeline. `crates/anima-mmd/src/lib.rs` states plainly that it parses PMX 2.0 and VMD but does not render, simulate, evaluate IK, or decode CP932, so this phase adds morph/bone application, VMD track playback and the vowel set. Mapping reference is `packages/stage-ui-mmd/src/constants/morphs.ts` (Japanese-first candidates `あ/い/う/え/お`, `まばたき`, `笑い`, …; `VOWEL_SLOTS`) and `packages/stage-ui-mmd/src/components/scenes/MMD.vue:431-436` (`vowelA = mouthOpen × 0.7`, loud warning when no vowel morphs resolve).

**Gate C5:** a user PMX renders with VMD playback and vowel lip-sync; the missing-vowel case fails loudly rather than silently animating nothing.

## Phase 6 — Live2D, behind the licensing gate

`model_runtime.dart:66-72` already blocks this kind and `ModelBackendRegistry.fromRuntimes` converts the block into a loud `UnavailableModelBackend`, so nothing here may start before the gate is recorded as resolved. The proprietary Cubism Core must be user-fetched after the Live2D terms are accepted and must never be committed; the in-tree precedent is the git-ignored `.cache/` (`.gitignore:77`, `**/.cache/`) holding `apps/stage-web/.cache/assets/js/CubismSdkForWeb-5-r.3/Core/live2dcubismcore.js`, and the policy is recorded at `docs/design-flutter-godot-pivot.md:365-366` and `:401-404` (legal review before release, 3D ships first). Native work: Core loading, `.moc3`/`.model3.json`/`.exp3.json` parsing with the validation rules of `packages/stage-ui-live2d/src/libs/live2d-model-loader.ts`, and the DSL interpreter parity described in `docs/design-live2d-dsl-interpreter.md`.

**Gate C6:** user-fetched Core present, `.moc3` validation and `.exp3` blend modes verified, DSL parity checklist satisfied.

## Phase 7 — Parity bookkeeping

Update `docs/feature-parity-checklist.md:34-35`, `:53` and `:89`, and the Wave 3 "remaining" note at `docs/design-flutter-godot-pivot.md:275-277`, from gap to landed per kind.

**Gate C7:** those entries state landed only for kinds whose C3–C6 passed; Live2D stays gated until C6.

## Cross-cutting mapping rule

One spec table drives all four adapters, derived from `docs/research-emotion-mapping-reference.md` §2 (R3–R13): resolve explicit mapping → exact name → case-insensitive → fuzzy cluster → no-op; separate `kind` before touching morphs so a motion cue never becomes a facial morph; intensity multiplies a curated 0.7–0.8 target; fixed-duration ease-in-out-cubic; only previously-managed expressions fade; lip-sync is an independent additive channel that owns the vowel slots. The wire already carries `tag`, `kind`, `intensity`, `duration_ms`, `seq`, `ts_ms`, `actor_id` (`crates/anima-channel/src/wire.rs:819-840`); `StageExpressionCue` in `apps/flutter/lib/features/stage/model_expression.dart` needs `durationMs` added to reach hold-then-neutral parity. Keep the RMS→morph mapping from the shared smoothing fixture; do not invent a daemon-published audio stream — `docs/decision-bridge-scope.md` remains authoritative.

## Decisions the maintainer must approve

1. **Display-model catalog ownership** — new daemon verb versus client-local catalog (Phase 1). Everything downstream of real cards waits on this.
2. **GPU/rendering API for the plugin** — one API across four platforms versus per-platform backends (Phase 2). No rendering dependency exists in the workspace today, so this choice is open.
3. **Desktop host targets and their timing** — creating `linux/`, `windows/`, `macos/` for `apps/flutter` is net-new scope, not a port.
4. **Live2D legal gate** — who records the legal review and the user-fetch flow, and confirmation that 3D ships first (Phase 6).
5. **Spine runtime line shipped** — 4.2 default versus multi-line, given `build.rs` compiles exactly one line into a binary while the Vue reference lazy-loads three.
6. **MMD scope** — whether physics/IK and CP932 (absent from `crates/anima-mmd`) are in scope for parity or deferred.
7. **Third-party licence notices** — approval of the notice set that must ship with the plugin (Spine Runtimes License requires the notice and each user's own Spine Editor licence; MMD assets stay user-supplied).
