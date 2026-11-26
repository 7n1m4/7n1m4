// SPDX-License-Identifier: GPL-3.0-or-later
//! Proves the Spine 4.2 renderer drives all four frozen sinks through a
//! recording platform double, and that texture registration / release happen
//! exclusively through the platform-injected closures (never fabricated).
//!
//! The double records every `register_texture` / `release_texture` call and
//! every sink value; the test asserts:
//!   * load mints exactly one texture id via the injected closure,
//!   * lip sync, emotion and ambient phase round-trip through the C ABI
//!     getters (observable sinks),
//!   * the frame render produces real geometry (not an empty/fake frame),
//!   * dispose releases the texture through the injected closure,
//!   * a missing bundle fails loudly (typed error), never an empty render.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use anima_render::contract::ffi::{airi_render_handle, kind, TextureRegistry};
use anima_render::spine_native::{SpineNativeError, SpineNativeRenderer};

const ATLAS: &str =
    "synthetic.png\nsize:32,32\nformat:RGBA8888\nfilter:Nearest,Nearest\nbody\nbounds:0,0,32,32\n";

const SKELETON_JSON: &str = r#"{
    "skeleton": { "hash": "synthetic", "spine": "4.2.18", "x": -16, "y": -16, "width": 32, "height": 32, "fps": 30, "images": "./" },
    "bones": [ { "name": "root" } ],
    "slots": [ { "name": "body", "bone": "root", "attachment": "body" } ],
    "skins": [ { "name": "default", "attachments": { "body": { "body": { "width": 32, "height": 32, "x": 0, "y": 0 } } } } ],
    "animations": {
        "idle": { "bones": { "root": { "rotate": [ { "time": 0, "value": 0 }, { "time": 1, "value": 10 } ] } } },
        "happy": { "bones": { "root": { "rotate": [ { "time": 0, "value": 0 }, { "time": 0.5, "value": 20 } ] } } }
    }
}"#;

/// Recording platform double: mints monotonic texture ids, counts
/// registrations and releases, and records the last minted (width,height).
struct RecordingRegistry {
    next: AtomicU32,
    registered: AtomicU32,
    released: AtomicU32,
    last_w: AtomicU32,
    last_h: AtomicU32,
}

impl RecordingRegistry {
    fn new() -> Self {
        RecordingRegistry {
            next: AtomicU32::new(1),
            registered: AtomicU32::new(0),
            released: AtomicU32::new(0),
            last_w: AtomicU32::new(0),
            last_h: AtomicU32::new(0),
        }
    }
}

unsafe extern "C" fn register(ctx: *mut c_void, w: u32, h: u32) -> u32 {
    let state = &*(ctx as *const RecordingRegistry);
    state.last_w.store(w, Ordering::SeqCst);
    state.last_h.store(h, Ordering::SeqCst);
    state.registered.fetch_add(1, Ordering::SeqCst);
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let state = &*(ctx as *const RecordingRegistry);
    state.released.fetch_add(1, Ordering::SeqCst);
}

/// Encode the self-contained spine bundle the C ABI `load` decodes:
/// kind(1) | skel_is_binary(1) | skel_len(4 LE) | skel | atlas_len(4 LE) | atlas.
fn encode_bundle() -> Vec<u8> {
    let mut out = vec![kind::SPINE as u8, 0u8];
    out.extend_from_slice(&(SKELETON_JSON.len() as u32).to_le_bytes());
    out.extend_from_slice(SKELETON_JSON.as_bytes());
    out.extend_from_slice(&(ATLAS.len() as u32).to_le_bytes());
    out.extend_from_slice(ATLAS.as_bytes());
    out
}

#[test]
fn spine_native_drives_all_four_sinks_through_recording_double() {
    let dir = tempfile::tempdir().expect("temp dir");
    let bundle = dir.path().join("model.bundle");
    std::fs::write(&bundle, encode_bundle()).expect("write bundle");

    let state = Box::into_raw(Box::new(RecordingRegistry::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    let mut renderer = SpineNativeRenderer::create(registry);

    // --- load: texture id comes from the injected closure, never fabricated.
    let (handle, first_frame): (airi_render_handle, _) = renderer
        .load(bundle.to_str().unwrap())
        .expect("synthetic spine bundle should load through the spine renderer");
    assert_ne!(handle.id, 0);
    assert_ne!(handle.texture_id, u32::MAX, "expected a minted texture id");
    let s = unsafe { &*(state as *const RecordingRegistry) };
    assert_eq!(
        s.registered.load(Ordering::SeqCst),
        1,
        "exactly one page registered through the injected closure"
    );
    assert_ne!(
        s.last_w.load(Ordering::SeqCst),
        0,
        "register closure received a real width"
    );
    // First frame is real geometry, not an empty/fake frame.
    assert!(
        !first_frame.geometry.vertices.is_empty(),
        "expected vertices"
    );
    assert_eq!(first_frame.geometry.draws.len(), 1);

    // --- sink 1: lip sync round-trips through the C ABI getter.
    renderer.set_lip_sync(handle, 0.5).expect("lip sync");
    assert!((renderer.lip_sync(handle).expect("read lip sync") - 0.5).abs() < 1e-6);

    // --- sink 2: emotion round-trips (tag, kind, intensity).
    renderer
        .set_emotion(handle, "happy", "emotion", 0.8)
        .expect("emotion");
    let (tag, ekind, intensity) = renderer.emotion(handle).expect("read emotion");
    assert_eq!(tag, "happy");
    assert_eq!(ekind, "emotion");
    assert!((intensity - 0.8).abs() < 1e-6);

    // --- sink 3: ambient phase round-trips.
    renderer.set_ambient_phase(handle, 0.25).expect("ambient");
    assert!((renderer.ambient_phase(handle).expect("read ambient") - 0.25).abs() < 1e-6);

    // --- sink 4: frame render produces advancing geometry.
    let frame = renderer.render(handle, 1.0 / 60.0).expect("render");
    assert!(!frame.geometry.vertices.is_empty());
    assert!(!frame.geometry.indices.is_empty());

    // --- dispose releases the texture through the injected closure (once).
    renderer.dispose(handle).expect("dispose");
    renderer.dispose(handle).expect("dispose is idempotent");
    assert_eq!(
        s.released.load(Ordering::SeqCst),
        1,
        "texture released exactly once through the injected closure"
    );

    drop(renderer);
    unsafe { drop(Box::from_raw(state as *mut RecordingRegistry)) };
}

#[test]
fn spine_native_missing_bundle_fails_loudly_not_empty() {
    let state = Box::into_raw(Box::new(RecordingRegistry::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    let mut renderer = SpineNativeRenderer::create(registry);

    let err = renderer.load("/nonexistent/model.bundle").unwrap_err();
    match err {
        SpineNativeError::Load(_) => {}
        other => panic!("expected a loud Load error, got {other:?}"),
    }
    let message = err.to_string();
    assert!(
        message.contains("spine load failed"),
        "unexpected error: {message}"
    );

    drop(renderer);
    unsafe { drop(Box::from_raw(state as *mut RecordingRegistry)) };
}

#[test]
fn spine_native_rejects_a_non_spine_kind_as_missing_runtime() {
    // A Live2D-kind backend has no native spine backend; the renderer surfaces
    // that as a typed MissingRuntime rather than an empty frame. (VRM and MMD
    // now have native backends of their own — see vrm_native_test /
    // mmd_native_test.)
    let state = Box::into_raw(Box::new(RecordingRegistry::new())) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);
    // Build a renderer whose backend is the wrong kind (Live2D): the spine
    // contract rejects it as "no native backend", which the renderer surfaces
    // as a typed MissingRuntime rather than an empty frame.
    let backend = anima_render::contract::ffi::RenderBackend::create(kind::LIVE2D, registry);
    let mut renderer = SpineNativeRenderer::create_with_backend(backend);
    let err = renderer.load("/nonexistent").unwrap_err();
    match err {
        SpineNativeError::MissingRuntime(_) => {}
        other => panic!("expected MissingRuntime, got {other:?}"),
    }
    drop(renderer);
    unsafe { drop(Box::from_raw(state as *mut RecordingRegistry)) };
}
