# flutter_anima_render

Native model rendering plugin for AIRI. It registers **one GPU texture per
loaded model** and pumps frames on the platform thread; the Dart side holds
**only the opaque integer texture id**. This package is the Dart half of the
frozen native render/texture contract whose native half lives in
`crates/anima-render` (`src/contract/**`, `cpp/render_contract.{h,cpp}`).

## The frozen contract

The contract is frozen: the Dart method-channel shape and the native C ABI are
both fixed, and neither changes without a version bump
(`CONTRACT_VERSION` in `crates/anima-render/src/contract/contract.rs`).

### Dart surface (this package)

`FlutterAnimaRender(kind)` addresses one model kind over the frozen method
channel `org.moeru.airi/anima/model/<kind>` (`kind` ∈ `vrm`, `spine`, `mmd`,
`live2d`). The Dart surface is kind-generic, but **the only plugin host
implemented today is Linux, and it registers only the VRM channel**:
`linux/flutter_anima_render_plugin.cc` creates one `AIRI_RENDER_KIND_VRM`
backend and registers `org.moeru.airi/anima/model/vrm`. Spine, MMD and Live2D
have no registered platform channel on any host; calling them fails loudly at
the method channel rather than returning a fabricated texture. macOS/Windows
have no plugin implementation (`pubspec.yaml` declares no such platform), and
Android/iOS are not wired either. `load(assetPath)` returns a
`NativeRenderTexture`:

| method | arguments | returns |
| --- | --- | --- |
| `load` | `path` | `handle:string`, `textureId:int` |
| `setLipSync` | `handle`, `weight` | void |
| `setEmotion` | `handle`, `tag`, `kind`, `intensity`, `seq`, `tsMs` | void |
| `setAmbientPhase` | `handle`, `phase` | void |
| `dispose` | `handle` | void |

`NativeRenderTexture` exposes `textureId` (the only value Dart keeps), the four
sinks, and an idempotent `dispose()` that releases the texture. Failures surface
as a typed `NativeRenderException` (`runtime-unavailable`, `invalid-handle`,
`invalid-texture`, or the platform error code) — never a fabricated model.

### Native surface (`crates/anima-render`)

* `cpp/render_contract.h` — the frozen C ABI the platform binds against.
  Lifecycle: `airi_render_create -> airi_render_load -> (setLipSync |
  setEmotion | setAmbientPhase | render)* -> airi_render_dispose ->
  airi_render_destroy`. `airi_render_load` returns an opaque
  `airi_render_handle` whose `texture_id` is minted by the platform's injected
  registry (`register_texture`/`release_texture` at create time); the backend
  never fabricates ids.
* `src/contract/frame.rs` — the renderer-agnostic frame shape (`TexturePayload`,
  `Vertex`, `DrawCommand`/`BlendMode`, `FrameGeometry`, `RenderFrame`). 2D
  (Spine/Live2D) and 3D (VRM/MMD) scenes both reduce to it.
* `src/contract/backend.rs` — `BackendKind` (wire indices 0–3) and the
  `RendererBackend` trait every per-OS GPU backend implements.
* `src/contract/ffi.rs` — safe Rust wrapper (`RenderBackend`, `TextureRegistry`)
  over the C ABI.

Dart never sees vertices, draws or pages — only the integer `textureId`.

## Per-OS GPU backends (beneath the contract)

The C ABI is implemented once (`cpp/render_contract.cpp`). The Linux plugin
links the Rust staticlib `libanima_render.a` plus the C++ backend archives
(`libairi_render_backends.a`, `libairi_spine_cpp.a`); build them with
`packages/flutter_anima_render/linux/build_native.sh` before a desktop build.
The live host registers only the VRM C++ backend (`cpp/vrm_backend.*`), which
writes RGBA pixels into platform-minted `FlTexture`s; the app's VRM desktop
integration test proves real frame output through this path. A spine-cpp
shell (`cpp/spine_shell.*`) exists but has no registered platform channel, and
MMD (`cpp/mmd_backend.*`) plus Live2D are not host-wired. The GPU layer
(texture mint/release, raster) is injected by the platform, so the contract is
designed to back other OSes. **Follow-ups:** macOS/Windows/Android/iOS hosts,
Metal/Vulkan/EGL backends, registered Spine/MMD channels, and the gated Live2D
renderer land in their own phases (see
`docs/plan-flutter-native-model-rendering.md`).

## Testing

```
cd packages/flutter_anima_render && flutter test
```

`test/render_contract_test.dart` is hermetic (mock method channel, no GPU): it
proves `load` mints an opaque texture id, `dispose` releases it exactly once and
is idempotent, the sinks forward the frozen argument keys, and a missing native
renderer fails loudly with a typed error.

Native-side tests live in `crates/anima-render/tests/render_contract.rs`
(end-to-end load/render/dispose through the C ABI with a synthetic spine bundle)
and the byte-stability test in `src/contract/contract.rs`.

## License

GPL-3.0-or-later. See `LICENSE`. Third-party Spine runtime notices are shipped
separately.