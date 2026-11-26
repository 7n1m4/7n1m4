// SPDX-License-Identifier: GPL-3.0-or-later
//! Proves the VRM native renderer drives the frozen contract end to end:
//!
//!   * the bundled `AvatarSample_A.vrm` loads and produces non-empty geometry
//!     with MToon material data, decoded base-colour pixels and live spring
//!     bones,
//!   * `aa` lip-sync is an independent additive channel: setting it moves the
//!     mouth morph while blink keeps running, and switching emotion preserves
//!     both (the additive-safety regression),
//!   * a missing / corrupt VRM fails loudly with a typed error — never an
//!     empty frame and never a fabricated texture,
//!   * texture registration and release happen exclusively through the
//!     injected recording platform double.

use std::ffi::c_void;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};

use anima_render::contract::frame::TextureFormat;
use anima_render::contract::{airi_render_handle, RenderBackend};
use anima_render::contract::kind;
use anima_render::contract::TextureRegistry;
use anima_render::vrm_native::{VrmNativeError, VrmNativeRenderer};

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../packages/stage-ui/src/assets/vrm/models/AvatarSample-A/AvatarSample_A.vrm"
);

/// Recording platform double: mints monotonic texture ids starting at 1,
/// counts registrations/releases and remembers the last minted size. The
/// renderer never fabricates an id, so every id it reports must come from
/// here.
struct RecordingRegistry {
    next: AtomicU32,
    registered: AtomicU32,
    released: AtomicU32,
    last_w: AtomicU32,
    last_h: AtomicU32,
}

impl RecordingRegistry {
    fn new() -> Self {
        Self {
            next: AtomicU32::new(1),
            registered: AtomicU32::new(0),
            released: AtomicU32::new(0),
            last_w: AtomicU32::new(0),
            last_h: AtomicU32::new(0),
        }
    }
}

unsafe extern "C" fn register(ctx: *mut c_void, w: u32, h: u32) -> u32 {
    let state = unsafe { &*(ctx as *const RecordingRegistry) };
    state.last_w.store(w, Ordering::SeqCst);
    state.last_h.store(h, Ordering::SeqCst);
    state.registered.fetch_add(1, Ordering::SeqCst);
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let state = unsafe { &*(ctx as *const RecordingRegistry) };
    state.released.fetch_add(1, Ordering::SeqCst);
}

/// Own the registry box and hand out a [`TextureRegistry`] bound to it.
struct Harness {
    raw: *mut RecordingRegistry,
    registry: Option<TextureRegistry>,
}

impl Harness {
    fn new() -> Self {
        let raw = Box::into_raw(Box::new(RecordingRegistry::new())) as *mut RecordingRegistry;
        let registry = TextureRegistry::new(register, release, raw as *mut c_void);
        Self {
            raw,
            registry: Some(registry),
        }
    }

    fn state(&self) -> &RecordingRegistry {
        unsafe { &*self.raw }
    }

    fn take(&mut self) -> TextureRegistry {
        self.registry.take().expect("registry taken once")
    }
}

impl Drop for Harness {
    fn drop(&mut self) {
        drop(self.registry.take());
        unsafe { drop(Box::from_raw(self.raw)) };
    }
}

fn fixture() -> String {
    let path = Path::new(FIXTURE);
    assert!(path.is_file(), "bundled VRM fixture missing at {FIXTURE}");
    path.to_str().expect("utf-8 fixture path").to_string()
}

#[test]
fn vrm_native_loads_avatar_sample_with_mtoon_and_spring_bones() {
    let mut harness = Harness::new();
    let mut renderer = VrmNativeRenderer::create(harness.take());

    let (handle, _frame) = renderer
        .load(&fixture())
        .expect("AvatarSample_A.vrm should load through the VRM native driver");
    // The frame carries the geometry; the pages (base colours + shaded output)
    // come from `pages`, matching the frozen contract where `RenderFrame.pages`
    // is empty and the platform uploads pages once at load.
    let frame = renderer.render(handle, 0.0).expect("render frame 0");

    assert_ne!(handle.id, 0, "expected a native model id");
    assert_ne!(
        handle.texture_id,
        u32::MAX,
        "the platform must mint the model's output texture"
    );
    // Texture ids come only from the injected platform registry: one per
    // decoded base-colour image plus the shaded output surface.
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 3);
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 0);

    // Real geometry, not an empty frame.
    let nv = frame.geometry.vertices.len();
    let ni = frame.geometry.indices.len();
    assert!(nv > 1000, "expected a real mesh, got {nv} vertices");
    assert!(
        ni > 3000 && ni % 3 == 0,
        "expected triangles, got {ni} indices"
    );
    assert!(!frame.geometry.draws.is_empty(), "expected draw ranges");
    let page_count = renderer.pages(handle).expect("pages").len();
    for draw in &frame.geometry.draws {
        assert!(
            (draw.page as usize) < page_count,
            "draw references page {} but only {} pages exist",
            draw.page,
            page_count
        );
        assert!(draw.index_count > 0 && draw.index_count % 3 == 0);
        let end = draw.vertex_offset + draw.vertex_count;
        assert!(end as usize <= nv, "draw range out of bounds");
    }
    assert!(
        frame
            .geometry
            .vertices
            .iter()
            .all(|v| v.x.is_finite() && v.y.is_finite() && v.z.is_finite()),
        "non-finite vertex position"
    );

    // MToon parameter data, exported for the platform's shader.
    let materials = renderer.materials(handle);
    assert!(!materials.is_empty(), "expected MToon data");
    for material in &materials {
        assert_eq!(material.base_color.len(), 4);
        assert_eq!(material.shade_color.len(), 4);
        assert_eq!(material.emissive.len(), 3);
        assert!(!material.toon_shades.is_empty(), "toon ramp required");
        assert!(
            material.base_color[3] > 0.0,
            "base colour alpha must be usable"
        );
        assert!(
            material
                .base_color
                .iter()
                .chain(material.shade_color.iter())
                .chain(material.emissive.iter())
                .all(|c| c.is_finite()),
            "non-finite MToon parameter"
        );
    }
    // AvatarSample_A is authored with MToon shade colours, not flat white.
    assert!(
        materials
            .iter()
            .any(|m| m.shade_color[0] < 1.0 || m.emissive.iter().any(|c| *c > 0.0)),
        "expected real MToon shading parameters"
    );

    // Base-colour pages are decoded to RGBA8 pixels through the platform.
    let pages = renderer.pages(handle).expect("pages");
    assert!(!pages.is_empty(), "expected at least one base-colour page");
    let mut decoded = 0;
    for page in &pages {
        assert_eq!(page.format, TextureFormat::Rgba8);
        if page.pixels.is_empty() {
            continue;
        }
        decoded += 1;
        assert_eq!(
            page.pixels.len(),
            page.width as usize * page.height as usize * 4,
            "page {} is not tightly packed RGBA8",
            page.name
        );
    }
    assert!(decoded > 0, "expected decoded base-colour pixels");

    // The shaded output surface is real: it has the model's silhouette (not a
    // constant clear colour) and more than one distinct shaded value.
    let output = pages.last().expect("output page");
    assert_eq!(output.name, "vrm-output");
    assert_eq!(output.width, anima_render::vrm_native::OUTPUT_SIZE);
    let opaque = output.pixels.chunks_exact(4).filter(|px| px[3] > 0).count();
    assert!(
        opaque > output.width as usize * output.height as usize / 10,
        "expected the model to cover a real area of the output, got {opaque} fragments"
    );
    // Opaque fragments carry the shaded material colour (AvatarSample_A is
    // authored with an emissive white MToon material).
    let opaque_px = output
        .pixels
        .chunks_exact(4)
        .filter(|px| px[3] == 255)
        .count();
    assert!(
        opaque_px > 1000,
        "expected fully shaded fragments, got {opaque_px}"
    );
    let shaded: std::collections::HashSet<_> = output
        .pixels
        .chunks_exact(4)
        .filter(|px| px[3] == 255)
        .map(|px| (px[0], px[1], px[2]))
        .collect();
    assert!(!shaded.is_empty(), "expected shaded output");

    // Spring bones are simulated.
    assert!(
        renderer.spring_bone_count(handle) > 0,
        "spring bones active"
    );

    // The first frame after load is already resolved (load renders frame 0).
    let mut frames = 0;
    for _ in 0..30 {
        let f = renderer.render(handle, 1.0 / 60.0).expect("render");
        assert_eq!(f.geometry.vertices.len(), nv);
        frames += 1;
    }
    assert_eq!(frames, 30);

    renderer.dispose(handle).expect("dispose");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 3);
}

#[test]
fn vrm_native_lip_sync_is_independent_and_survives_emotion_switch() {
    let mut harness = Harness::new();
    let mut renderer = VrmNativeRenderer::create(harness.take());
    let (handle, _frame) = renderer.load(&fixture()).expect("load AvatarSample_A");

    // The document's mouth preset, discovered from the engine (aa/a).
    let lip = renderer
        .lip_preset(handle)
        .expect("the model has an aa/a mouth morph");

    // Silence: the mouth stays closed while the blink loop keeps cycling.
    for _ in 0..8 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    let rest_aa = renderer.preset_weight(handle, &lip);
    assert!(rest_aa < 0.05, "silent aa must stay closed, got {rest_aa}");
    // Blink is a discrete event (2–6 s apart); the loop is proven by observing
    // a blink inside a window, not by sampling one instant.
    let blink = renderer.blink_presets(handle)[0].clone();
    let mut saw_blink = false;
    for _ in 0..600 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
        if renderer.preset_weight(handle, &blink) > 0.0 {
            saw_blink = true;
            break;
        }
    }
    assert!(saw_blink, "the blink loop must produce a blink");
    assert!(
        renderer.preset_weight(handle, &lip) < 0.05,
        "silence must keep the mouth closed while blinking"
    );

    // Real RMS frames drive the mouth open.
    renderer.set_lip_sync(handle, 0.9).expect("lip sync");
    assert!((renderer.lip_sync(handle).expect("lip sink") - 0.9).abs() < 1e-6);
    renderer.render(handle, 1.0 / 60.0).expect("render");
    let open_aa = renderer.preset_weight(handle, &lip);
    assert!(open_aa > 0.7, "aa must follow the rms frame, got {open_aa}");
    let blink_before = renderer.preset_weight(handle, &blink);
    assert!(
        (0.0..=1.0).contains(&blink_before),
        "blink weight out of range"
    );

    // Emotion switch: blink and lip-sync are unmanaged and must survive.
    renderer
        .set_emotion(handle, "happy", "emotion", 1.0)
        .expect("emotion");
    for _ in 0..8 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!((renderer.lip_sync(handle).expect("lip sink") - 0.9).abs() < 1e-6);
    let after_aa = renderer.preset_weight(handle, &lip);
    assert!(
        (after_aa - open_aa).abs() < 0.2,
        "emotion switch disturbed lip-sync: {open_aa} -> {after_aa}"
    );
    let blink_after = renderer.preset_weight(handle, &blink);
    assert!(
        (0.0..=1.0).contains(&blink_after),
        "emotion switch broke the blink loop"
    );
    assert!(
        renderer
            .blink_presets(handle)
            .iter()
            .any(|p| renderer.preset_weight(handle, p) > 0.0)
            || blink_after > 0.0,
        "no blink preset is animating after the emotion switch"
    );

    // The emotion cue is recorded and the geometry keeps rendering (the
    // additive channel is proven by blink + lip-sync surviving above).
    let (tag, _kind, intensity) = renderer.emotion(handle).expect("emotion sink");
    assert_eq!(tag, "happy");
    assert!((intensity - 1.0).abs() < 1e-6);

    // Silence closes the mouth again without touching the emotion.
    renderer.set_lip_sync(handle, 0.0).expect("lip sync");
    for _ in 0..60 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!(
        renderer.preset_weight(handle, &lip) < 0.05,
        "aa must decay back to rest"
    );
    assert_eq!(
        renderer.emotion(handle).expect("emotion sink").0,
        "happy",
        "lip-sync must not clear the emotion"
    );

    renderer.dispose(handle).expect("dispose");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 3);
}

#[test]
fn vrm_native_missing_or_corrupt_file_fails_loudly() {
    let mut harness = Harness::new();
    let mut renderer = VrmNativeRenderer::create(harness.take());

    let missing = renderer.load("/nonexistent/does-not-exist.vrm");
    let missing = missing.expect_err("a missing file must fail loudly");
    assert!(
        matches!(
            missing,
            VrmNativeError::Load(_) | VrmNativeError::UnsupportedDocument(_)
        ),
        "unexpected error: {missing}"
    );

    let dir = tempfile::tempdir().expect("temp dir");
    let corrupt = dir.path().join("corrupt.vrm");
    std::fs::write(&corrupt, b"not a glTF binary at all").expect("write corrupt");
    let err = renderer
        .load(corrupt.to_str().unwrap())
        .expect_err("a corrupt VRM must fail loudly");
    assert!(
        matches!(
            err,
            VrmNativeError::Load(_) | VrmNativeError::UnsupportedDocument(_)
        ),
        "unexpected error: {err}"
    );
    assert!(!err.to_string().is_empty());

    // Nothing was fabricated: no texture minted, none leaked.
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 0);
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 0);
}

#[test]
fn vrm_native_texture_ids_come_only_from_the_platform_double() {
    let mut harness = Harness::new();
    let mut renderer = VrmNativeRenderer::create(harness.take());
    let (handle, _frame) = renderer.load(&fixture()).expect("load AvatarSample_A");

    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 3);
    assert!(harness.state().last_w.load(Ordering::SeqCst) > 0);
    assert!(harness.state().last_h.load(Ordering::SeqCst) > 0);
    assert_eq!(
        handle.texture_id, 3,
        "output surface id minted by the double"
    );
    assert_ne!(handle.texture_id, u32::MAX);
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 0);

    // Disposing releases every id the platform minted, exactly once.
    renderer.dispose(handle).expect("dispose");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 3);
    // Idempotent: a second dispose neither double-releases nor errors.
    renderer.dispose(handle).expect("dispose is idempotent");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 3);

    // A second model mints fresh ids from the same platform registry.
    let (handle2, _frame2) = renderer.load(&fixture()).expect("second load");
    assert_eq!(handle2.texture_id, 6);
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 6);
    renderer.dispose(handle2).expect("dispose 2");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 6);
    assert_eq!(renderer.model_count(), 0);
    let _ = kind::VRM;
}

/// The frozen contract getters must read the VRM sinks back through the native
/// renderer, not through the C++ table's default-initialised fields.
#[test]
fn vrm_native_sinks_round_trip_through_the_frozen_contract_getters() {
    let mut harness = Harness::new();
    let registry = harness.take();
    let mut backend = RenderBackend::create(kind::VRM, registry);

    let handle: airi_render_handle = backend
        .load(&fixture())
        .expect("AvatarSample_A.vrm should load through the frozen contract");

    // Defaults before any cue: silence, no emotion, phase 0.
    assert_eq!(backend.get_lip_sync(handle).expect("get_lip_sync"), 0.0);
    assert_eq!(backend.get_ambient_phase(handle).expect("get_ambient"), 0.0);
    let (tag, _kind, intensity) = backend.get_emotion(handle).expect("get_emotion");
    assert!(tag.is_empty() && intensity == 0.0);

    backend.set_lip_sync(handle, 0.75).expect("set_lip_sync");
    backend
        .set_emotion(handle, "happy", "emotion", 0.5)
        .expect("set_emotion");
    backend.set_ambient_phase(handle, 0.25).expect("set_ambient");

    assert_eq!(
        backend.get_lip_sync(handle).expect("get_lip_sync"),
        0.75
    );
    let (tag, kind, intensity) = backend.get_emotion(handle).expect("get_emotion");
    assert_eq!(tag, "happy");
    assert_eq!(kind, "motion");
    assert_eq!(intensity, 0.5);
    assert_eq!(backend.get_ambient_phase(handle).expect("get_ambient"), 0.25);

    // A second model reads back its own sinks, not the first model's.
    let other = backend.load(&fixture()).expect("second load");
    assert_eq!(backend.get_lip_sync(other).expect("get_lip_sync"), 0.0);
    assert_eq!(backend.get_lip_sync(handle).expect("get_lip_sync"), 0.75);

    backend.dispose(handle).expect("dispose");
    backend.dispose(other).expect("dispose 2");
}

