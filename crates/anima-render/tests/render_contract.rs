// SPDX-License-Identifier: GPL-3.0-or-later
//! End-to-end test of the frozen render/texture contract (C ABI + Rust wrapper).
//!
//! Builds a synthetic spine bundle fully in memory, registers a platform
//! texture registry that mints/releases ids, loads through `airi_render_load`,
//! renders frames, and verifies dispose releases the texture — with no GPU and
//! no disk assets beyond the one bundle file the contract reads.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use anima_render::contract::{airi_render_handle, kind, RenderBackend, TextureRegistry};


const ATLAS: &str =
    "synthetic.png\nsize:32,32\nformat:RGBA8888\nfilter:Nearest,Nearest\nbody\nbounds:0,0,32,32\nmouth\nbounds:0,0,16,16\n";

const SKELETON_JSON: &str = r#"{
    "skeleton": { "hash": "synthetic", "spine": "4.2.18", "x": -16, "y": -16, "width": 32, "height": 32, "fps": 30, "images": "./" },
    "bones": [ { "name": "root" } ],
    "slots": [
      { "name": "body", "bone": "root", "attachment": "body" },
      { "name": "mouth", "bone": "root", "attachment": "mouth" }
    ],
    "skins": [ { "name": "default", "attachments": {
      "body": { "body": { "width": 32, "height": 32, "x": 0, "y": 0 } },
      "mouth": { "mouth": { "width": 16, "height": 16, "x": 0, "y": 0 } }
    } } ],
    "animations": { "idle": { "bones": { "root": { "rotate": [ { "time": 0, "value": 0 }, { "time": 1, "value": 10 } ] } } } }
}"#;

/// Platform texture registry state: mints monotonic ids, counts releases.
struct RegistryState {
    next: AtomicU32,
    released: AtomicU32,
}

unsafe extern "C" fn register(ctx: *mut c_void, _w: u32, _h: u32) -> u32 {
    let state = &*(ctx as *const RegistryState);
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let state = &*(ctx as *const RegistryState);
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
fn contract_loads_renders_and_disposes_releasing_texture() {
    let dir = tempfile::tempdir().expect("temp dir");
    let bundle = dir.path().join("model.bundle");
    std::fs::write(&bundle, encode_bundle()).expect("write bundle");

    let state = Box::into_raw(Box::new(RegistryState {
        next: AtomicU32::new(1),
        released: AtomicU32::new(0),
    })) as *mut c_void;
    let registry = TextureRegistry::new(register, release, state);

    let mut backend = RenderBackend::create(kind::SPINE, registry);

    let handle: airi_render_handle = backend
        .load(bundle.to_str().unwrap())
        .expect("synthetic spine bundle should load through the contract");
    assert_ne!(handle.id, 0);
    // One page minted one texture id.
    assert_ne!(handle.texture_id, u32::MAX, "expected a minted texture id");

    let pages = backend.pages(handle).expect("pages");
    assert_eq!(pages.len(), 1);
    assert_eq!(pages[0].name, "synthetic.png");

    let frame = backend.render(handle, 1.0 / 60.0).expect("render");
    assert!(!frame.geometry.vertices.is_empty(), "expected vertices");
    assert!(!frame.geometry.indices.is_empty());
    assert_eq!(frame.geometry.draws.len(), 2, "body + mouth slot");

    // The lip-sync weight must modulate the `mouth` slot's draw alpha, not
    // just land in a getter. The frozen load path has to wire the slot name
    // into the native Spine session for this to happen.
    backend.set_lip_sync(handle, 0.5).expect("lip sync");
    let spoken = backend.render(handle, 0.0).expect("spoken frame");
    let alphas: Vec<f32> = spoken.geometry.draws.iter().map(|d| d.alpha).collect();
    assert!(alphas.iter().any(|a| (*a - 0.5).abs() < 1e-5), "no mouth draw was modulated by lip sync: {alphas:?}");
    assert!(alphas.iter().any(|a| (*a - 1.0).abs() < 1e-5), "the body draw must stay opaque: {alphas:?}");
    backend
        .set_emotion(handle, "happy", "emotion", 0.8)
        .expect("emotion");
    backend.set_ambient_phase(handle, 0.25).expect("ambient");

    backend.dispose(handle).expect("dispose");
    // Idempotent: a second dispose is a no-op success.
    backend.dispose(handle).expect("dispose is idempotent");
    let raw = state as *mut RegistryState;
    let s = unsafe { &*raw };
    assert_eq!(
        s.released.load(Ordering::SeqCst),
        1,
        "texture released once"
    );

    drop(backend);
    unsafe { drop(Box::from_raw(raw)) };
}

#[test]
fn contract_rejects_a_backend_kind_without_a_native_renderer_loudly() {
    // Live2D still has no native backend behind the contract; VRM, Spine and
    // MMD do, and are covered by vrm_native_test / spine_native_test /
    // mmd_native_test / the test above. An MMD backend reached with a missing
    // file fails loudly through its own driver instead.
    for unsupported in [kind::LIVE2D] {
        let probe = Box::into_raw(Box::new(RegistryState {
            next: AtomicU32::new(1),
            released: AtomicU32::new(0),
        })) as *mut c_void;
        let registry = TextureRegistry::new(register, release, probe);
        let mut backend = RenderBackend::create(unsupported, registry);
        let err = backend.load("/nonexistent").unwrap_err().to_string();
        assert!(err.contains("no native backend"), "unexpected: {err}");
        drop(backend);
        unsafe { drop(Box::from_raw(probe as *mut RegistryState)) };
    }
}
