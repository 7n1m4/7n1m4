// SPDX-License-Identifier: GPL-3.0-or-later
//! Deterministic, no-GPU proof of MMD playback at known timestamps.
//!
//! A synthetic PMX (built byte-by-byte, no committed binaries) carries a
//! centre bone at the origin plus vertex morphs named `センター` (bone track),
//! `頂点変形` (vertex morph track) and `あ` (the vowel lip-sync slot). A
//! synthetic VMD keys the centre bone's translation at frames 0/30/60 and the
//! `頂点変形` morph at frames 0/30, so `frame / 30` sampling is pinned exactly:
//!
//!   * t=0 → rest pose (identity translation, morph weight 0),
//!   * t=1/30 → the frame-30 key (translation `[0,0,1]`, morph weight 1),
//!   * t=1 → the frame-60 key (translation `[0,0,2]`),
//!   * t=2 → clamped past the last key (no extrapolation),
//!   * lip-sync at t=1 overrides the VMD `あ` track (AIRI owns the slot).

use anima_render::mmd_native::{MmdNativeRenderer, MorphSlot};

#[path = "../../anima-mmd/tests/common/mod.rs"]
mod common;
use common::*;

const ENC: u8 = ENC_UTF8;

fn w_vertex(buf: &mut Vec<u8>, x: f32, y: f32, z: f32) {
    w_f32(buf, x);
    w_f32(buf, y);
    w_f32(buf, z);
    w_f32(buf, 0.0);
    w_f32(buf, 1.0);
    w_f32(buf, 0.0);
    w_f32(buf, 0.0);
    w_f32(buf, 0.0);
    w_u8(buf, 0); // BDEF1
    w_index_signed(buf, 2, 0); // bone 0 (centre)
    w_f32(buf, 1.0);
}

fn w_bone(buf: &mut Vec<u8>, name: &str, parent: i32, pos: [f32; 3]) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, name);
    for v in pos {
        w_f32(buf, v);
    }
    w_index_signed(buf, 2, parent);
    w_i32(buf, 0);
    w_u16(buf, anima_mmd::bone_flags::ROTATABLE | anima_mmd::bone_flags::ENABLED);
    for v in [0.0_f32, -1.0, 0.0] {
        w_f32(buf, v);
    }
}

fn w_material(buf: &mut Vec<u8>) {
    w_str(buf, ENC, "body");
    w_str(buf, ENC, "body");
    for v in [0.8_f32, 0.8, 0.8, 1.0] {
        w_f32(buf, v);
    }
    for v in [0.0_f32, 0.0, 0.0] {
        w_f32(buf, v);
    }
    w_f32(buf, 0.0);
    for v in [0.2_f32, 0.2, 0.2] {
        w_f32(buf, v);
    }
    w_u8(buf, 0x10);
    for v in [0.0_f32, 0.0, 0.0, 1.0] {
        w_f32(buf, v);
    }
    w_f32(buf, 1.0);
    w_index_signed(buf, 1, -1);
    w_index_signed(buf, 1, -1);
    w_u8(buf, anima_mmd::sphere_mode::NONE);
    w_u8(buf, 0);
    w_index_signed(buf, 1, -1);
    w_str(buf, ENC, "");
    w_u32(buf, 3);
}

fn w_str_raw(buf: &mut Vec<u8>, raw: &[u8]) {
    w_i32(buf, raw.len() as i32);
    buf.extend_from_slice(raw);
}

fn w_vertex_morph(buf: &mut Vec<u8>, name: &str, global: &str, delta: [f32; 3]) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, global);
    w_u8(buf, 4);
    w_u8(buf, anima_mmd::morph_types::VERTEX);
    w_u32(buf, 1);
    w_index_unsigned(buf, 2, 0);
    for v in delta {
        w_f32(buf, v);
    }
}

/// PMX with a centre bone at the origin, a triangle skinned to it, and three
/// morphs: a bone-track marker, a vertex morph and the `あ` vowel slot.
fn build_pmx() -> Vec<u8> {
    let mut buf = base_header(ENC, 0);
    w_names(&mut buf, ENC);
    w_u32(&mut buf, 3);
    w_vertex(&mut buf, -1.0, 0.0, 0.0);
    w_vertex(&mut buf, 1.0, 0.0, 0.0);
    w_vertex(&mut buf, 0.0, 2.0, 0.0);
    w_u32(&mut buf, 3);
    for i in [0_u32, 1, 2] {
        w_index_unsigned(&mut buf, 2, i);
    }
    w_u32(&mut buf, 0); // no textures
    w_u32(&mut buf, 1);
    w_material(&mut buf);
    w_u32(&mut buf, 1);
    w_bone(&mut buf, "センター", -1, [0.0, 0.0, 0.0]);
    w_u32(&mut buf, 3);
    w_vertex_morph(&mut buf, "センター", "centre", [0.0, 0.0, 0.0]);
    w_vertex_morph(&mut buf, "頂点変形", "vertex-deform", [1.0, 0.0, 0.0]);
    w_vertex_morph(&mut buf, "あ", "a", [0.0, 1.0, 0.0]);
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    buf
}

/// PMX variant whose `あ` morph name is CP932 bytes under a UTF-8 flag —
/// the mislabeled-Japanese-export case from airi-96gt.
fn build_cp932_pmx() -> Vec<u8> {
    let mut buf = base_header(ENC, 0);
    w_names(&mut buf, ENC);
    w_u32(&mut buf, 3);
    w_vertex(&mut buf, -1.0, 0.0, 0.0);
    w_vertex(&mut buf, 1.0, 0.0, 0.0);
    w_vertex(&mut buf, 0.0, 2.0, 0.0);
    w_u32(&mut buf, 3);
    for i in [0_u32, 1, 2] {
        w_index_unsigned(&mut buf, 2, i);
    }
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 1);
    w_material(&mut buf);
    w_u32(&mut buf, 1);
    w_bone(&mut buf, "センター", -1, [0.0, 0.0, 0.0]);
    w_u32(&mut buf, 1);
    // `あ` in CP932; parser must decode before MorphMixer candidate matching.
    w_str_raw(&mut buf, &[0x82, 0xa0]);
    w_str(&mut buf, ENC, "a");
    w_u8(&mut buf, 4);
    w_u8(&mut buf, anima_mmd::morph_types::VERTEX);
    w_u32(&mut buf, 1);
    w_index_unsigned(&mut buf, 2, 0);
    for v in [0.0_f32, 1.0, 0.0] {
        w_f32(&mut buf, v);
    }
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    buf
}

fn w_bone_key(buf: &mut Vec<u8>, name: &str, frame: u32, pos: [f32; 3], rot: [f32; 4]) {
    w_fixed(buf, name, 15);
    w_u32(buf, frame);
    for v in pos {
        w_f32(buf, v);
    }
    for v in rot {
        w_f32(buf, v);
    }
    for i in 0..64 {
        buf.push(i as u8);
    }
}

fn w_morph_key(buf: &mut Vec<u8>, name: &str, frame: u32, weight: f32) {
    w_fixed(buf, name, 15);
    w_u32(buf, frame);
    w_f32(buf, weight);
}

/// VMD: centre-bone translation keyed at frames 0/30/60, `頂点変形` weighted
/// at frames 0/30, and a decoy `あ` track AIRI must override.
fn build_vmd() -> Vec<u8> {
    let mut buf = Vec::new();
    buf.extend_from_slice(b"Vocaloid Motion Data 0002\0\0\0\0\0");
    w_fixed(&mut buf, "synthetic", 20);

    let mut bones = Vec::new();
    w_bone_key(&mut bones, "センター", 0, [0.0, 0.0, 0.0], [0.0, 0.0, 0.0, 1.0]);
    w_bone_key(&mut bones, "センター", 30, [0.0, 0.0, 1.0], [0.0, 0.0, 0.0, 1.0]);
    w_bone_key(&mut bones, "センター", 60, [0.0, 0.0, 2.0], [0.0, 0.0, 0.0, 1.0]);
    w_u32(&mut buf, 3);
    buf.extend_from_slice(&bones);

    let mut morphs = Vec::new();
    w_morph_key(&mut morphs, "頂点変形", 0, 0.0);
    w_morph_key(&mut morphs, "頂点変形", 30, 1.0);
    w_morph_key(&mut morphs, "あ", 0, 1.0);
    w_u32(&mut buf, 3);
    buf.extend_from_slice(&morphs);

    w_u32(&mut buf, 0); // cameras
    w_u32(&mut buf, 0); // lights
    w_u32(&mut buf, 0); // shadows
    buf
}

/// Minimal platform double: mints monotonic ids, counts releases.
struct Harness {
    next: &'static std::sync::atomic::AtomicU32,
    registry: Option<anima_render::contract::TextureRegistry>,
}

unsafe extern "C" fn register(ctx: *mut std::ffi::c_void, _w: u32, _h: u32) -> u32 {
    let state = unsafe { &*(ctx as *const Harness) };
    state.next.fetch_add(1, std::sync::atomic::Ordering::SeqCst)
}

unsafe extern "C" fn release(_ctx: *mut std::ffi::c_void, _id: u32) {}

impl Harness {
    fn new() -> Self {
        let raw = Box::into_raw(Box::new(Self {
            next: Box::leak(Box::new(std::sync::atomic::AtomicU32::new(1))),
            registry: None,
        }));
        let registry = anima_render::contract::TextureRegistry::new(
            register,
            release,
            raw as *mut std::ffi::c_void,
        );
        unsafe { (*raw).registry = Some(registry) };
        let next = unsafe { (*raw).next };
        let registry = unsafe { (*raw).registry.take() }.expect("registry present");
        Self {
            next,
            registry: Some(registry),
        }
    }

    fn take(&mut self) -> anima_render::contract::TextureRegistry {
        self.registry.take().expect("registry taken once")
    }
}

fn load(
    dir: &std::path::Path,
) -> (MmdNativeRenderer, anima_render::contract::airi_render_handle) {
    let pmx = dir.join("model.pmx");
    std::fs::write(&pmx, build_pmx()).expect("write pmx");
    let vmd = dir.join("motion.vmd");
    std::fs::write(&vmd, build_vmd()).expect("write vmd");

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer
        .load(pmx.to_str().expect("utf-8"))
        .expect("synthetic PMX loads");
    let motion = anima_mmd::VmdMotion::from_path(&vmd).expect("synthetic VMD parses");
    renderer.set_motion(handle, motion).expect("bind motion");
    std::mem::forget(harness);
    (renderer, handle)
}

/// Vertex 0's position at `time_seconds`, reached by 1/30 s ticks from t=0.
/// The 0-dt read does not advance the clock.
fn vertex0_at(renderer: &mut MmdNativeRenderer, handle: anima_render::contract::airi_render_handle, time_seconds: f32) -> [f32; 3] {
    let target = (time_seconds * 30.0).round() as u32;
    let now = (renderer.motion_time(handle).expect("time") * 30.0).round() as u32;
    for _ in now..target {
        renderer.render(handle, 1.0 / 30.0).expect("render");
    }
    let frame = renderer.render(handle, 0.0).expect("frame");
    let v = frame.geometry.vertices[0];
    [v.x, v.y, v.z]
}

#[test]
fn vmd_bone_and_morph_keys_sample_at_known_timestamps() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (mut renderer, handle) = load(dir.path());

    // t=0 (frame 0): rest translation, zero morph weight.
    assert_eq!(renderer.motion_time(handle).expect("time"), 0.0);
    assert_eq!(vertex0_at(&mut renderer, handle, 0.0), [-1.0, 0.0, 0.0]);

    // t=1.0 (frame 30): translation +1 z, morph weight 1 (+1 x on vertex 0).
    let at30 = vertex0_at(&mut renderer, handle, 1.0);
    assert!((at30[0] - 0.0).abs() < 1e-5, "x = rest -1 + morph +1, got {at30:?}");
    assert!((at30[2] - 1.0).abs() < 1e-5, "z = rest 0 + bone +1, got {at30:?}");
    assert!((renderer.motion_time(handle).expect("time") - 1.0).abs() < 1e-5);

    // t=2.0 (frame 60): translation +2 z.
    let at60 = vertex0_at(&mut renderer, handle, 2.0);
    assert!((at60[2] - 2.0).abs() < 1e-5, "z = bone +2, got {at60:?}");
    assert!((renderer.motion_time(handle).expect("time") - 2.0).abs() < 1e-5);

    // Past the last key clamps (no extrapolation); the clock keeps running.
    let past = vertex0_at(&mut renderer, handle, 3.0);
    assert!((past[2] - 2.0).abs() < 1e-5, "clamped z, got {past:?}");
    assert!((renderer.motion_time(handle).expect("time") - 3.0).abs() < 1e-5);
}

#[test]
fn cp932_japanese_morph_name_resolves_vowel_slot() {
    let dir = tempfile::tempdir().expect("temp dir");
    let pmx = dir.path().join("model.pmx");
    std::fs::write(&pmx, build_cp932_pmx()).expect("write pmx");
    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer.load(pmx.to_str().expect("utf-8")).expect("CP932-model loads");
    assert_eq!(renderer.resolved_vowels(handle), vec![MorphSlot::VowelA]);
    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
    std::mem::forget(harness);
}

#[test]
fn lip_sync_overrides_the_vmd_vowel_track() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (mut renderer, handle) = load(dir.path());

    // The VMD `あ` track is 1.0 at frame 0, but AIRI owns the slot: with no
    // mouth-open weight the vowel sits at 0.
    assert_eq!(renderer.slot_weight(handle, MorphSlot::VowelA), 0.0);

    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
    let frame = renderer.render(handle, 0.0).expect("frame");
    let v = frame.geometry.vertices[0];
    // The `あ` morph offsets vertex 0 by +1 y at weight 0.7.
    assert!((v.y - 0.7).abs() < 1e-5, "y = vowel 0.7, got {v:?}");
}