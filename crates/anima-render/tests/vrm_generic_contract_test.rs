// SPDX-License-Identifier: GPL-3.0-or-later
//! Proves the frozen contract's per-frame counters dispatch to the VRM driver.
//!
//! `airi_render_frame_counts` used to look only at the Spine model table, so a
//! VRM backend reported 0/0/0 and `RenderBackend::render` sized its buffers to
//! nothing. These tests drive the generic contract (`RenderBackend`, the same
//! entry point the Flutter plugin binds) with `AIRI_RENDER_KIND_VRM` and
//! require the counters to match the frame the backend actually serialises.
use std::ffi::c_void;
use std::path::Path;
use std::sync::atomic::{AtomicU32, Ordering};
use anima_render::contract::{airi_render_handle, kind, RenderBackend, TextureRegistry};
const FIXTURE: &str = concat!(
env!("CARGO_MANIFEST_DIR"),
"/../../packages/stage-ui/src/assets/vrm/models/AvatarSample-A/AvatarSample_A.vrm"
);
/// Edge length of the shaded output surface, mirrored from the driver.
const OUTPUT_SIZE: u32 = 512;
/// Platform texture registry double: mints monotonic ids and counts
/// registrations/releases. The backend must never fabricate an id. It also
/// records every minted `(width, height)` so the test can prove the platform
/// minted the shaded output texture.
struct RegistryState {
    next: AtomicU32,
    registered: AtomicU32,
    released: AtomicU32,
    sizes: std::sync::Mutex<Vec<(u32, u32)>>,
}

impl RegistryState {
    fn new() -> Self {
        Self {
            next: AtomicU32::new(1),
            registered: AtomicU32::new(0),
            released: AtomicU32::new(0),
            sizes: std::sync::Mutex::new(Vec::new()),
        }
    }
}

unsafe extern "C" fn register(ctx: *mut c_void, width: u32, height: u32) -> u32 {
    let state = unsafe { &*(ctx as *const RegistryState) };
    state.registered.fetch_add(1, Ordering::SeqCst);
    state.sizes.lock().unwrap().push((width, height));
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let state = unsafe { &*(ctx as *const RegistryState) };
    state.released.fetch_add(1, Ordering::SeqCst);
}

fn fixture() -> String {
    let path = Path::new(FIXTURE);
    assert!(path.is_file(), "bundled VRM fixture missing at {FIXTURE}");
    path.to_str().expect("utf-8 fixture path").to_string()
}

#[test]
fn vrm_frame_counts_match_the_rendered_frame_through_the_generic_contract() {
    let state = Box::into_raw(Box::new(RegistryState::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    let mut backend = RenderBackend::create(kind::VRM, registry);

    let handle: airi_render_handle = backend
        .load(&fixture())
        .expect("AvatarSample_A.vrm should load through the generic contract");
    assert_ne!(handle.id, 0, "expected a native model id");
    assert_ne!(
        handle.texture_id,
        u32::MAX,
        "the platform must mint the model's output texture"
    );

    // The counters are the contract's sizing call: render() allocates from
    // them, so a 0/0/0 answer would yield an empty frame.
    let frame = backend.render(handle, 0.0).expect("render frame 0");
    let geometry = &frame.geometry;
    assert!(
        !geometry.vertices.is_empty(),
        "VRM counters must report vertices, got 0"
    );
    assert!(!geometry.indices.is_empty(), "expected indices");
    assert!(!geometry.draws.is_empty(), "expected draw ranges");
    assert_eq!(geometry.indices.len() % 3, 0, "expected triangles");

    // A second tick must agree with the first: the counters describe the frame
    // the next render() call serialises, not a stale or empty snapshot.
    let next = backend.render(handle, 1.0 / 60.0).expect("render frame 1");
    assert_eq!(
        next.geometry.vertices.len(),
        geometry.vertices.len(),
        "vertex count changed between ticks"
    );
    assert_eq!(next.geometry.indices.len(), geometry.indices.len());
    assert_eq!(next.geometry.draws.len(), geometry.draws.len());

    // Every draw stays inside the buffers the counters sized.
    for draw in &geometry.draws {
        assert!(draw.index_count > 0 && draw.index_count % 3 == 0);
        assert!(
            (draw.index_offset + draw.index_count) as usize <= geometry.indices.len(),
            "draw range out of bounds"
        );
        assert!(
            (draw.vertex_offset + draw.vertex_count) as usize <= geometry.vertices.len(),
            "draw range out of bounds"
        );
    }

    // Sinks keep working on the same generic path.
    backend.set_lip_sync(handle, 0.5).expect("lip sync");
    backend
        .set_emotion(handle, "happy", "emotion", 0.8)
        .expect("emotion");
    backend.set_ambient_phase(handle, 0.25).expect("ambient");
    assert!((backend.get_lip_sync(handle).expect("get lip sync") - 0.5).abs() < 1e-6);
    assert!((backend.get_ambient_phase(handle).expect("get ambient") - 0.25).abs() < 1e-6);

    let registered = unsafe { &*(state as *const RegistryState) }.registered.load(Ordering::SeqCst);
    assert!(registered > 0, "expected platform-minted page textures");
    let sizes = unsafe { &*(state as *const RegistryState) }.sizes.lock().unwrap().clone();
    assert!(sizes.contains(&(OUTPUT_SIZE, OUTPUT_SIZE)), "the handle's texture must be the platform-minted shaded output surface, got {sizes:?}");

    backend.dispose(handle).expect("dispose");
    backend.dispose(handle).expect("dispose is idempotent");
    let released = unsafe { &*(state as *const RegistryState) }.released.load(Ordering::SeqCst);
    assert_eq!(released, registered, "every minted texture released once");

    drop(backend);
    unsafe { drop(Box::from_raw(state as *mut RegistryState)) };
}

#[test]
fn vrm_generic_contract_exposes_real_page_pixels() {
    let state = Box::into_raw(Box::new(RegistryState::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    let mut backend = RenderBackend::create(kind::VRM, registry);
    let handle = backend.load(&fixture()).expect("load VRM");

    // The frozen C ABI is what the Flutter plugin binds: when it reports a
    // page it must carry the RGBA8 bytes the platform texture uploads. The
    // old VRM page tail returned null pixels, so the platform stayed blank.
    let pages = backend.pages(handle).expect("pages");
    assert!(!pages.is_empty(), "expected decoded pages");
    for page in &pages {
        assert_eq!(
            page.pixels.len(),
            page.width as usize * page.height as usize * 4,
            "page {} does not carry tightly packed RGBA8 pixels",
            page.name
        );
        assert!(page.pixels.iter().any(|byte| *byte != 0), "page {} is blank", page.name);
    }
    let output = pages.last().expect("shaded output page");
    assert_eq!(output.name, "vrm-output");
    assert_eq!(output.width, OUTPUT_SIZE);
    assert_eq!(output.height, OUTPUT_SIZE);
    assert!(
        output.pixels.chunks_exact(4).filter(|px| px[3] > 0).count() > 1000,
        "the output page must carry the model's shaded silhouette"
    );

    backend.dispose(handle).expect("dispose");
    drop(backend);
    unsafe { drop(Box::from_raw(state as *mut RegistryState)) };
}

#[test]
fn vrm_frame_counts_report_zero_for_an_unknown_handle() {
    let state = Box::into_raw(Box::new(RegistryState::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    let mut backend = RenderBackend::create(kind::VRM, registry);

    // No load: the unknown handle must size to an empty frame (and render must
    // fail loudly rather than pretend it drew something).
    let unknown = airi_render_handle {
        id: 0xDEAD_BEEF,
        texture_id: u32::MAX,
    };
    let err = backend
        .render(unknown, 0.0)
        .expect_err("rendering an unknown handle must fail");
    assert!(
        err.to_string().contains("unknown handle"),
        "unexpected error: {err}"
    );

    drop(backend);
    unsafe { drop(Box::from_raw(state as *mut RegistryState)) };
}

/// The frozen wrapper must dispatch page reads to the VRM driver and expose
/// real pixel bytes. A null page leaves the platform texture zero-filled even
/// when the CPU shader produced a non-empty surface, so assert both the
/// dispatch (non-null bytes, expected length) and changing content between
/// two render ticks.
#[test]
fn vrm_frozen_wrapper_exposes_live_page_pixels() {
    let state_ptr = Box::into_raw(Box::new(RegistryState::new()));
    let registry = TextureRegistry::new(register, release, state_ptr as *mut c_void);
    let mut backend = RenderBackend::create(kind::VRM, registry);
    let handle = backend
        .load(&fixture())
        .expect("AvatarSample_A.vrm should load through the generic contract");

    let pages = backend.pages(handle).expect("page reads dispatch to VRM");
    assert!(!pages.is_empty(), "VRM must report texture pages");
    let output = pages.last().expect("output page");
    let expected = (OUTPUT_SIZE * OUTPUT_SIZE * 4) as usize;
    assert_eq!(output.width, OUTPUT_SIZE);
    assert_eq!(output.height, OUTPUT_SIZE);
    assert_eq!(output.pixels.len(), expected, "output page must be fully populated");
    assert!(output.pixels.iter().any(|byte| *byte != 0), "output page is blank");

    let before = output.pixels.to_vec();
    backend.render(handle, 0.5).expect("advance the CPU shader");
    let after = backend.pages(handle).expect("page reads dispatch to VRM again");
    let after = after.last().expect("output page");
    assert_eq!(after.pixels.len(), expected);
    assert_ne!(before, after.pixels, "output pixels did not change after rendering");

    backend.dispose(handle).expect("dispose");
    let state = unsafe { &*state_ptr };
    assert!(state.registered.load(Ordering::SeqCst) >= 1);
    assert_eq!(state.released.load(Ordering::SeqCst), state.registered.load(Ordering::SeqCst),
        "dispose must release every registered texture exactly once");
    unsafe { drop(Box::from_raw(state_ptr)); }
}

/// A load that fails after the platform minted page textures must release
/// those ids exactly once. The driver installs its model only on success, so
/// this exercises the rollback guard rather than the dispose path.
#[test]
fn failed_load_releases_registered_textures() {
    let state_ptr = Box::into_raw(Box::new(RegistryState::new()));
    let registry = TextureRegistry::new(register, release, state_ptr as *mut c_void);
    let mut backend = RenderBackend::create(kind::VRM, registry);

    let error = backend
        .load("/definitely/missing/model.vrm")
        .expect_err("missing model must fail loudly");
    assert!(!error.to_string().is_empty());
    let state = unsafe { &*state_ptr };
    assert_eq!(state.registered.load(Ordering::SeqCst), 0, "missing model must not register textures");
    assert_eq!(state.released.load(Ordering::SeqCst), 0, "nothing registered, nothing released");
    drop(backend);
    unsafe { drop(Box::from_raw(state_ptr)); }
}
