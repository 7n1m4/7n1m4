// SPDX-License-Identifier: GPL-3.0-or-later
//! End-to-end gate for VRM rendering in the desktop-client shape.
//!
//! `vrm_native_test.rs` drives the Rust driver directly. This file drives the
//! *frozen C ABI* (`cpp/render_contract.h` + `cpp/vrm_backend.h`) with a
//! platform texture-registry double — the same lifecycle
//! `apps/flutter/lib/features/stage/method_channel_backend.dart` issues over
//! `org.moeru.airi/anima/model/vrm`, with the C++ backend table, the VRM
//! dispatch and the Rust `anima_vrm_*` shell all in the loop:
//!
//!   * `anima_vrm_create` / `anima_vrm_load` on the bundled
//!     `AvatarSample_A.vrm` return an opaque native id plus the
//!     platform-minted output texture id — never an id the backend invented,
//!   * `anima_vrm_page_count` reports one RGBA8 page per decoded base colour
//!     plus the shaded output surface, and `anima_vrm_page` uploads real RGBA8
//!     pixels through the frozen size-then-copy pair — the output page is
//!     512x512, non-blank, and distinct from every base-colour page,
//!   * `anima_vrm_frame_counts` + `anima_vrm_render` serialise a real posed
//!     mesh (finite positions, triangles, in-bounds draw ranges into the
//!     output page) and the mesh keeps moving under spring bones / idle motion,
//!   * the same instance exposes finite MToon parameters (base/shade colour, toon
//!     ramp, emissive, rim mix, alpha cutoff) and a non-zero spring-bone chain
//!     count — the frozen surface itself carries no MToon or spring-bone entry
//!     point, so those two read-only views come from the driver the frozen
//!     `anima_vrm_*` shell wraps,
//!   * the three sinks round-trip through the frozen getters
//!     (`anima_vrm_get_lip_sync` / `_get_emotion` / `_get_ambient_phase`),
//!     which read the native renderer rather than a table copy,
//!   * `anima_vrm_dispose` releases every minted id exactly once and is
//!     idempotent,
//!   * a missing or corrupt document fails loudly with a message and mints no
//!     texture,
//!   * `airi_render_load` on the same asset returns the C++-minted handle whose
//!     `texture_id` is a platform id, and the frozen method set in
//!     `render_contract_json` is exactly the set `MethodChannelModelBackend`
//!     calls, with the same argument keys.
//!
//! The generic `airi_render_frame_counts` / `airi_render_render` path now
//! dispatches VRM handles via `airi_vrm_frame_counts`, proven by
//! `tests/vrm_generic_contract_test.rs`; this file still exercises the direct
//! `anima_vrm_*` entry points for finer-grained MToon/mesh assertions.
//!
//! What this cannot prove is the GPU/platform half: no per-OS backend registers
//! itself on a Dart `MethodChannel` yet, so a real `flutter run` still fails
//! loudly with `runtime-unavailable` instead of drawing. That remaining
//! desktop-plugin gap is recorded in `docs/feature-parity-checklist.md`.

use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

use anima_render::contract::{
    airi_render_handle, kind, render_contract_json, DrawCommand, RenderBackend, TextureRegistry,
    Vertex,
};

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../packages/stage-ui/src/assets/vrm/models/AvatarSample-A/AvatarSample_A.vrm"
);

/// Edge length of the shaded output surface, mirrored from the driver.
const OUTPUT_SIZE: u32 = 512;

/// The frozen error code for success, mirrored from `vrm_backend.h`.
const VRM_OK: i32 = 0;

unsafe extern "C" {
    fn anima_vrm_create(
        register: Option<unsafe extern "C" fn(*mut c_void, u32, u32) -> u32>,
        release: Option<unsafe extern "C" fn(*mut c_void, u32)>,
        ctx: *mut c_void,
        out_renderer: *mut *mut c_void,
    ) -> i32;
    fn anima_vrm_destroy(renderer: *mut c_void);
    fn anima_vrm_load(
        renderer: *mut c_void,
        asset_path: *const c_char,
        out_id: *mut u64,
        out_texture_id: *mut u32,
    ) -> i32;
    fn anima_vrm_page_count(renderer: *mut c_void, id: u64, out_count: *mut usize) -> i32;
    fn anima_vrm_page(renderer: *mut c_void, id: u64, index: usize, out_width: *mut u32, out_height: *mut u32, out_pixels: *mut u8, pixel_cap: usize) -> i32;
    fn anima_vrm_frame_counts(
        renderer: *mut c_void,
        id: u64,
        out_vertices: *mut usize,
        out_indices: *mut usize,
        out_draws: *mut usize,
    ) -> i32;
    fn anima_vrm_render(
        renderer: *mut c_void,
        id: u64,
        delta_seconds: f32,
        out_vertices: *mut Vertex,
        vertex_cap: usize,
        out_indices: *mut u32,
        index_cap: usize,
        out_draws: *mut DrawCommand,
        draw_cap: usize,
    ) -> i32;
    fn anima_vrm_set_lip_sync(renderer: *mut c_void, id: u64, weight: f32) -> i32;
    fn anima_vrm_set_emotion(
        renderer: *mut c_void,
        id: u64,
        tag: *const c_char,
        intensity: f32,
    ) -> i32;
    fn anima_vrm_set_ambient_phase(renderer: *mut c_void, id: u64, phase: f32) -> i32;
    fn anima_vrm_dispose(renderer: *mut c_void, id: u64) -> i32;
    fn anima_vrm_get_lip_sync(renderer: *mut c_void, id: u64, out_weight: *mut f32) -> i32;
    fn anima_vrm_get_emotion(
        renderer: *mut c_void,
        id: u64,
        out_tag: *mut *const c_char,
        out_intensity: *mut f32,
    ) -> i32;
    fn anima_vrm_get_ambient_phase(renderer: *mut c_void, id: u64, out_phase: *mut f32)
        -> i32;
    fn anima_vrm_last_error(renderer: *mut c_void) -> *const c_char;
}

/// The platform's texture registry, as the Dart plugin supplies it: it mints
/// monotonic ids, records every `(width, height)` it was asked for, and counts
/// releases. The backend never fabricates an id, so every id it reports must
/// come from here.
struct PlatformTextures {
    next: AtomicU32,
    registered: AtomicU32,
    released: AtomicU32,
    sizes: Mutex<Vec<(u32, u32)>>,
}

impl PlatformTextures {
    fn new() -> Self {
        Self {
            next: AtomicU32::new(1),
            registered: AtomicU32::new(0),
            released: AtomicU32::new(0),
            sizes: Mutex::new(Vec::new()),
        }
    }

    fn registered(&self) -> u32 {
        self.registered.load(Ordering::SeqCst)
    }

    fn released(&self) -> u32 {
        self.released.load(Ordering::SeqCst)
    }

    fn sizes(&self) -> Vec<(u32, u32)> {
        self.sizes.lock().expect("sizes lock").clone()
    }
}

unsafe extern "C" fn register(ctx: *mut c_void, width: u32, height: u32) -> u32 {
    let state = unsafe { &*(ctx as *const PlatformTextures) };
    state.sizes.lock().expect("sizes lock").push((width, height));
    state.registered.fetch_add(1, Ordering::SeqCst);
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _texture_id: u32) {
    let state = unsafe { &*(ctx as *const PlatformTextures) };
    state.released.fetch_add(1, Ordering::SeqCst);
}

/// Owns the registry box so the `ctx` outlives the instance it is handed to.
struct Platform {
    raw: *mut PlatformTextures,
}

impl Platform {
    fn new() -> Self {
        Self {
            raw: Box::into_raw(Box::new(PlatformTextures::new())),
        }
    }

    fn state(&self) -> &PlatformTextures {
        unsafe { &*self.raw }
    }

    fn ctx(&self) -> *mut c_void {
        self.raw as *mut c_void
    }
}

impl Drop for Platform {
    fn drop(&mut self) {
        unsafe { drop(Box::from_raw(self.raw)) };
    }
}

/// A live VRM instance created through the frozen C ABI, plus the platform that
/// owns its texture ids.
struct Instance {
    platform: Platform,
    raw: *mut c_void,
}

impl Instance {
    fn create() -> Self {
        let platform = Platform::new();
        let mut raw: *mut c_void = std::ptr::null_mut();
        let status =
            unsafe { anima_vrm_create(Some(register), Some(release), platform.ctx(), &mut raw) };
        assert_eq!(status, VRM_OK, "anima_vrm_create must succeed");
        assert!(!raw.is_null(), "anima_vrm_create must return an instance");
        Self { platform, raw }
    }

    /// Load a `.vrm`, returning the native id and the platform-minted texture.
    fn load(&mut self, path: &str) -> Result<(u64, u32), String> {
        let c_path = CString::new(path).expect("path has no interior NUL");
        let mut id = 0u64;
        let mut texture_id = 0u32;
        let status =
            unsafe { anima_vrm_load(self.raw, c_path.as_ptr(), &mut id, &mut texture_id) };
        if status != VRM_OK {
            return Err(self.last_error());
        }
        Ok((id, texture_id))
    }

    fn last_error(&self) -> String {
        let ptr = unsafe { anima_vrm_last_error(self.raw) };
        if ptr.is_null() {
            return String::new();
        }
        unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
    }

    fn page_count(&self, id: u64) -> usize {
        let mut count = 0usize;
        let status = unsafe { anima_vrm_page_count(self.raw, id, &mut count) };
        assert_eq!(status, VRM_OK, "anima_vrm_page_count must succeed");
        count
    }

    /// Upload one page's pixels through the frozen size-then-copy pair.
    fn page(&self, id: u64, index: usize) -> (u32, u32, Vec<u8>) {
        let mut width = 0u32;
        let mut height = 0u32;
        let status = unsafe { anima_vrm_page(self.raw, id, index, &mut width, &mut height, std::ptr::null_mut(), 0) };
        assert_eq!(status, VRM_OK, "anima_vrm_page size query must succeed");
        let len = width as usize * height as usize * 4;
        let mut pixels = vec![0u8; len];
        let status = unsafe { anima_vrm_page(self.raw, id, index, &mut width, &mut height, pixels.as_mut_ptr(), len) };
        assert_eq!(status, VRM_OK, "anima_vrm_page copy must succeed: {}", self.last_error());
        assert_eq!(pixels.len(), len);
        (width, height, pixels)
    }

    /// Size the frozen vertex/index/draw buffers, then serialise one frame.
    fn render(&self, id: u64, delta_seconds: f32) -> (Vec<Vertex>, Vec<u32>, Vec<DrawCommand>) {
        let mut vertices = 0usize;
        let mut indices = 0usize;
        let mut draws = 0usize;
        let status = unsafe {
            anima_vrm_frame_counts(self.raw, id, &mut vertices, &mut indices, &mut draws)
        };
        assert_eq!(status, VRM_OK, "anima_vrm_frame_counts must succeed");

        let mut vertex_buf = vec![Vertex::default(); vertices];
        let mut index_buf = vec![0u32; indices];
        let mut draw_buf = vec![DrawCommand::default(); draws];
        let status = unsafe {
            anima_vrm_render(
                self.raw,
                id,
                delta_seconds,
                vertex_buf.as_mut_ptr(),
                vertices,
                index_buf.as_mut_ptr(),
                indices,
                draw_buf.as_mut_ptr(),
                draws,
            )
        };
        assert_eq!(
            status,
            VRM_OK,
            "anima_vrm_render must succeed: {}",
            self.last_error()
        );
        (vertex_buf, index_buf, draw_buf)
    }

    fn set_lip_sync(&self, id: u64, weight: f32) {
        let status = unsafe { anima_vrm_set_lip_sync(self.raw, id, weight) };
        assert_eq!(status, VRM_OK, "anima_vrm_set_lip_sync must succeed");
    }

    fn set_emotion(&self, id: u64, tag: &str, intensity: f32) {
        let c_tag = CString::new(tag).expect("tag has no interior NUL");
        let status =
            unsafe { anima_vrm_set_emotion(self.raw, id, c_tag.as_ptr(), intensity) };
        assert_eq!(status, VRM_OK, "anima_vrm_set_emotion must succeed");
    }

    fn set_ambient_phase(&self, id: u64, phase: f32) {
        let status = unsafe { anima_vrm_set_ambient_phase(self.raw, id, phase) };
        assert_eq!(status, VRM_OK, "anima_vrm_set_ambient_phase must succeed");
    }

    fn get_lip_sync(&self, id: u64) -> f32 {
        let mut weight = f32::NAN;
        let status = unsafe { anima_vrm_get_lip_sync(self.raw, id, &mut weight) };
        assert_eq!(status, VRM_OK, "anima_vrm_get_lip_sync must succeed");
        weight
    }

    fn get_emotion(&self, id: u64) -> (String, f32) {
        let mut tag: *const c_char = std::ptr::null();
        let mut intensity = f32::NAN;
        let status = unsafe { anima_vrm_get_emotion(self.raw, id, &mut tag, &mut intensity) };
        assert_eq!(status, VRM_OK, "anima_vrm_get_emotion must succeed");
        let tag = if tag.is_null() {
            String::new()
        } else {
            unsafe { CStr::from_ptr(tag) }.to_string_lossy().into_owned()
        };
        (tag, intensity)
    }

    fn get_ambient_phase(&self, id: u64) -> f32 {
        let mut phase = f32::NAN;
        let status = unsafe { anima_vrm_get_ambient_phase(self.raw, id, &mut phase) };
        assert_eq!(status, VRM_OK, "anima_vrm_get_ambient_phase must succeed");
        phase
    }

    fn dispose(&self, id: u64) {
        let status = unsafe { anima_vrm_dispose(self.raw, id) };
        assert_eq!(status, VRM_OK, "anima_vrm_dispose must succeed");
    }
}

impl Drop for Instance {
    fn drop(&mut self) {
        unsafe { anima_vrm_destroy(self.raw) };
    }
}

fn fixture() -> String {
    let path = Path::new(FIXTURE);
    assert!(path.is_file(), "bundled VRM fixture missing at {FIXTURE}");
    path.to_str().expect("utf-8 fixture path").to_string()
}

#[test]
fn vrm_c_abi_load_mints_the_output_texture_and_reports_real_pages() {
    let mut instance = Instance::create();
    let (id, texture_id) = instance.load(&fixture()).expect("AvatarSample_A.vrm loads");

    // Dart holds exactly this integer; it must be the platform's id.
    assert_ne!(id, 0, "expected a native model id");
    assert_ne!(
        texture_id,
        u32::MAX,
        "the platform must mint the model's output texture"
    );
    let sizes = instance.platform.state().sizes();
    assert_eq!(
        sizes.len(),
        instance.platform.state().registered() as usize,
        "every minted id has a size"
    );
    assert!(
        sizes.contains(&(OUTPUT_SIZE, OUTPUT_SIZE)),
        "the handle's texture is the shaded {OUTPUT_SIZE}x{OUTPUT_SIZE} output surface"
    );

    // One page per decoded base colour, plus the shaded output surface.
    let page_count = instance.page_count(id);
    assert!(
        page_count >= 2,
        "expected base-colour pages plus the output surface, got {page_count}"
    );
    assert_eq!(
        sizes.len(),
        page_count,
        "one platform texture per page, the last being the output surface"
    );

    instance.dispose(id);
    assert_eq!(
        instance.platform.state().released(),
        sizes.len() as u32
    );
}

#[test]
fn vrm_c_abi_render_serialises_a_real_meshed_frame() {
    let mut instance = Instance::create();
    let (id, _) = instance.load(&fixture()).expect("load AvatarSample_A");
    let page_count = instance.page_count(id);

    let (vertices, indices, draws) = instance.render(id, 0.0);

    assert!(
        vertices.len() > 1000,
        "real mesh, got {} vertices",
        vertices.len()
    );
    assert!(
        indices.len() > 3000 && indices.len() % 3 == 0,
        "triangles, got {} indices",
        indices.len()
    );
    assert!(!draws.is_empty(), "expected draw ranges");
    assert!(
        vertices
            .iter()
            .all(|v| v.x.is_finite() && v.y.is_finite() && v.z.is_finite()),
        "non-finite vertex position"
    );
    assert!(
        indices.iter().all(|i| (*i as usize) < vertices.len()),
        "index out of range"
    );

    for draw in &draws {
        assert!(
            (draw.page as usize) < page_count,
            "draw references page {} but only {page_count} pages exist",
            draw.page
        );
        assert!(draw.index_count > 0 && draw.index_count % 3 == 0);
        assert_eq!(draw.blend.to_wire(), 0, "opaque geometry");
        assert!(draw.alpha > 0.0, "visible alpha");
        assert!(
            (draw.vertex_offset + draw.vertex_count) as usize <= vertices.len(),
            "draw vertex range out of bounds"
        );
        assert!(
            (draw.index_offset + draw.index_count) as usize <= indices.len(),
            "draw index range out of bounds"
        );
    }

    // The frame is live, not a frozen snapshot: spring bones and idle motion
    // keep moving the mesh while the topology stays identical.
    let first = vertices[0];
    let mut moved = false;
    for _ in 0..60 {
        let (next, next_indices, next_draws) = instance.render(id, 1.0 / 60.0);
        assert_eq!(next.len(), vertices.len());
        assert_eq!(next_indices, indices);
        assert_eq!(next_draws.len(), draws.len());
        if next[0] != first {
            moved = true;
        }
    }
    assert!(moved, "spring bones / idle motion must move the mesh");
}

#[test]
fn vrm_c_abi_sinks_round_trip_through_the_frozen_getters() {
    let mut instance = Instance::create();
    let (id, _) = instance.load(&fixture()).expect("load AvatarSample_A");

    // Defaults before any cue: silence, no emotion, phase 0.
    assert_eq!(instance.get_lip_sync(id), 0.0);
    assert_eq!(instance.get_ambient_phase(id), 0.0);
    let (tag, intensity) = instance.get_emotion(id);
    assert!(tag.is_empty() && intensity == 0.0);

    // The exact calls `MethodChannelModelBackend` issues over the channel.
    instance.set_lip_sync(id, 0.75);
    instance.set_emotion(id, "happy", 0.5);
    instance.set_ambient_phase(id, 0.25);

    assert_eq!(instance.get_lip_sync(id), 0.75);
    let (tag, intensity) = instance.get_emotion(id);
    assert_eq!(tag, "happy");
    assert!((intensity - 0.5).abs() < 1e-6);
    assert_eq!(instance.get_ambient_phase(id), 0.25);

    // Rendering does not disturb the sinks, and the sinks do not disturb the
    // frame: the additive channels are independent of the geometry pass.
    for _ in 0..10 {
        instance.render(id, 1.0 / 60.0);
    }
    assert_eq!(instance.get_lip_sync(id), 0.75);
    assert_eq!(instance.get_ambient_phase(id), 0.25);
    assert_eq!(
        instance.get_emotion(id).0,
        "happy",
        "render must not clear the emotion"
    );

    // A second instance reads back its own sinks, not the first instance's.
    // (`anima_vrm_*` ids are per-instance 1-based slots, so both models are
    // id 1 in their own instance — exactly the isolation under test.)
    let mut other = Instance::create();
    let (other_id, _) = other.load(&fixture()).expect("second load");
    assert_eq!(other.get_lip_sync(other_id), 0.0);
    assert_eq!(instance.get_lip_sync(id), 0.75);

    instance.dispose(id);
    other.dispose(other_id);
    // Idempotent: a second dispose neither errors nor releases again.
    let released = instance.platform.state().released();
    instance.dispose(id);
    assert_eq!(instance.platform.state().released(), released);
}

#[test]
fn vrm_c_abi_missing_or_corrupt_document_fails_loudly_without_textures() {
    let mut instance = Instance::create();

    let err = instance
        .load("/nonexistent/does-not-exist.vrm")
        .expect_err("a missing file must fail loudly");
    assert!(!err.is_empty(), "the frozen error message must be filled");

    let dir = tempfile::tempdir().expect("temp dir");
    let corrupt = dir.path().join("corrupt.vrm");
    std::fs::write(&corrupt, b"not a glTF binary at all").expect("write corrupt");
    let err = instance
        .load(corrupt.to_str().expect("utf-8 path"))
        .expect_err("a corrupt VRM must fail loudly");
    assert!(!err.is_empty());

    // Nothing was fabricated: no texture minted, none leaked.
    assert_eq!(instance.platform.state().registered(), 0);
    assert_eq!(instance.platform.state().released(), 0);
    assert!(instance.platform.state().sizes().is_empty());
}

/// The C++ `airi_render_load` entry point on the same asset: the table-minted
/// handle whose `texture_id` is a platform id.
#[test]
fn vrm_airi_render_load_returns_a_platform_texture_handle() {
    let platform = Platform::new();
    let registry = TextureRegistry::new(register, release, platform.ctx());
    let mut backend = RenderBackend::create(kind::VRM, registry);

    let handle: airi_render_handle = backend.load(&fixture()).expect("AvatarSample_A.vrm loads");
    assert_ne!(handle.id, 0, "expected a table-minted model id");
    assert_ne!(
        handle.texture_id,
        u32::MAX,
        "the platform must mint the model's output texture"
    );
    assert!(
        platform
            .state()
            .sizes()
            .contains(&(OUTPUT_SIZE, OUTPUT_SIZE)),
        "the handle's texture is the shaded output surface"
    );

    backend.dispose(handle).expect("dispose");
    assert_eq!(
        platform.state().released(),
        platform.state().registered(),
        "dispose releases every minted id exactly once"
    );
}

#[test]
fn vrm_c_abi_contract_matches_the_dart_method_channel_arguments() {
    let json = render_contract_json();
    let doc: serde_json::Value = serde_json::from_str(&json).expect("contract json");
    assert_eq!(doc["version"], "1");
    assert_eq!(doc["channel_prefix"], "org.moeru.airi/anima/model/");

    let methods: Vec<(&str, Vec<&str>)> = doc["methods"]
        .as_array()
        .expect("methods array")
        .iter()
        .map(|method| {
            let name = method["name"].as_str().expect("method name");
            let args = method["args"]
                .as_array()
                .expect("method args")
                .iter()
                .map(|arg| arg.as_str().expect("arg name"))
                .collect();
            (name, args)
        })
        .collect();

    // Exactly what `MethodChannelModelBackend` invokes, with the same keys.
    assert_eq!(
        methods,
        vec![
            ("load", vec!["path", "source"]),
            ("setLipSync", vec!["handle", "weight"]),
            (
                "setEmotion",
                vec!["handle", "tag", "kind", "intensity", "seq", "tsMs"]
            ),
            ("setAmbientPhase", vec!["handle", "phase"]),
            ("dispose", vec!["handle"]),
        ]
    );
}

/// The shaded output page is real, non-empty RGBA8: the frozen size-then-copy
/// pair reports the output dimensions and the pixels are not a blank fill.
#[test]
fn vrm_c_abi_output_page_is_non_empty_shaded_rgba8() {
    let mut instance = Instance::create();
    let (id, _) = instance.load(&fixture()).expect("load AvatarSample_A");
    let page_count = instance.page_count(id);
    assert!(page_count >= 2, "expected pages plus the output surface");

    // The output surface is the last page (the driver appends it after the
    // decoded base colours).
    let (width, height, pixels) = instance.page(id, page_count - 1);
    assert_eq!((width, height), (OUTPUT_SIZE, OUTPUT_SIZE));
    assert_eq!(
        pixels.len(),
        OUTPUT_SIZE as usize * OUTPUT_SIZE as usize * 4,
        "tightly packed RGBA8"
    );

    let non_blank = pixels.chunks_exact(4).any(|px| px[0] != 0 || px[1] != 0 || px[2] != 0);
    assert!(non_blank, "the shaded output must not be a blank fill");

    // The shaded surface is not a copy of any base-colour page.
    let base_colour_pages = page_count - 1;
    for index in 0..base_colour_pages {
        let (_, _, base) = instance.page(id, index);
        assert_ne!(
            base, pixels,
            "output page {index} must be shaded, not the raw base colour"
        );
    }

    // And it carries real alpha coverage, not a fully transparent surface.
    let opaque = pixels
        .chunks_exact(4)
        .filter(|px| px[3] > 0)
        .count();
    assert!(opaque > 0, "the shaded output must cover some pixels");
}

/// MToon parameters and the spring-bone chains are observable on the same
/// instance the frozen entry points drive, so the gate asserts them rather than
/// only the geometry. The read-only views live on the driver the frozen
/// `anima_vrm_*` shell wraps; the frozen surface itself carries no MToon or
/// spring-bone entry point, which is the ABI segment this cannot prove.
#[test]
fn vrm_c_abi_document_exposes_mtoon_materials_and_spring_bones() {
    use anima_render::contract::airi_render_handle;
    use anima_render::vrm_native::VrmNativeRenderer;

    let platform = Platform::new();
    let mut renderer = VrmNativeRenderer::create(TextureRegistry::new(
        register,
        release,
        platform.ctx(),
    ));
    let (handle, _frame) = renderer.load(&fixture()).expect("load AvatarSample_A");
    let handle: airi_render_handle = handle;

    let materials = renderer.materials(handle);
    assert!(!materials.is_empty(), "the document must expose MToon materials");
    for material in &materials {
        assert!(
            material.base_color.iter().all(|c| c.is_finite()),
            "non-finite MToon base colour"
        );
        assert!(
            material.shade_color.iter().all(|c| c.is_finite()),
            "non-finite MToon shade colour"
        );
        assert!(
            material.toon_shades.iter().all(|s| s.is_finite()),
            "non-finite toon ramp level"
        );
        assert!(
            material.emissive.iter().all(|c| c.is_finite()),
            "non-finite emissive factor"
        );
        assert!(material.rim_mix.is_finite(), "non-finite rim mix");
        assert!(material.alpha_cutoff.is_finite(), "non-finite alpha cutoff");
    }

    let bones = renderer.spring_bone_count(handle);
    assert!(bones > 0, "the document must expose spring-bone chains");

    renderer.dispose(handle).expect("dispose");
    assert_eq!(
        platform.state().released(),
        platform.state().registered(),
        "dispose releases every minted id exactly once"
    );
}
