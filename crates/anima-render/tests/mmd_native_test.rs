// SPDX-License-Identifier: GPL-3.0-or-later
//! Proves the MMD native renderer drives the frozen contract end to end:
//!
//!   * a synthetic PMX (built byte-by-byte, no committed binary) loads and
//!     produces non-empty geometry, a decoded base-colour page and a shaded
//!     output page,
//!   * the vowel lip-sync channel is independent and additive: setting it
//!     moves the `あ` morph while the blink loop keeps running, and switching
//!     emotion preserves both,
//!   * a model with no vowel morph fails loudly at load (never a mute model),
//!   * a missing / corrupt file fails loudly with a typed error — never an
//!     empty frame and never a fabricated texture,
//!   * texture registration and release happen exclusively through the
//!     injected recording platform double, and dispose is idempotent.

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use anima_render::contract::frame::TextureFormat;
use anima_render::contract::{airi_render_handle, TextureRegistry};
use anima_render::mmd_native::{MmdNativeError, MmdNativeRenderer, MorphSlot, OUTPUT_SIZE};

#[path = "../../anima-mmd/tests/common/mod.rs"]
mod common;
use common::*;

// --- Synthetic PMX fixtures (byte-by-byte; no binaries committed) ----------

const ENC: u8 = ENC_UTF8;

/// A BDEF1 vertex with a deterministic normal and uv.
fn w_vertex(buf: &mut Vec<u8>, x: f32, y: f32, z: f32, u: f32, v: f32) {
    w_f32(buf, x);
    w_f32(buf, y);
    w_f32(buf, z);
    w_f32(buf, 0.0);
    w_f32(buf, 1.0);
    w_f32(buf, 0.0);
    w_f32(buf, u);
    w_f32(buf, v);
    w_u8(buf, 0); // BDEF1
    w_index_signed(buf, 2, 0); // bone 0
    w_f32(buf, 1.0); // edge factor
}

fn w_bone(buf: &mut Vec<u8>, name: &str, name_global: &str, parent: i32, pos: [f32; 3]) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, name_global);
    for v in pos {
        w_f32(buf, v);
    }
    w_index_signed(buf, 2, parent);
    w_i32(buf, 0); // layer
    w_u16(
        buf,
        anima_mmd::bone_flags::ROTATABLE
            | anima_mmd::bone_flags::VISIBLE
            | anima_mmd::bone_flags::ENABLED,
    );
    for v in [0.0_f32, -1.0, 0.0] {
        w_f32(buf, v); // tail offset
    }
}

fn w_material(buf: &mut Vec<u8>, name: &str, texture: i32, vertex_count: u32) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, name);
    for v in [0.8_f32, 0.8, 0.8, 1.0] {
        w_f32(buf, v); // diffuse
    }
    for v in [0.0_f32, 0.0, 0.0] {
        w_f32(buf, v); // specular
    }
    w_f32(buf, 0.0); // specular strength
    for v in [0.2_f32, 0.2, 0.2] {
        w_f32(buf, v); // ambient (shade colour)
    }
    w_u8(buf, 0x10); // edge enabled
    for v in [0.0_f32, 0.0, 0.0, 1.0] {
        w_f32(buf, v); // edge colour
    }
    w_f32(buf, 1.0); // edge size
    w_index_signed(buf, 1, texture);
    w_index_signed(buf, 1, -1); // sphere: none
    w_u8(buf, anima_mmd::sphere_mode::NONE);
    w_u8(buf, 0); // toon mode: texture index
    w_index_signed(buf, 1, -1); // toon: none
    w_str(buf, ENC, "");
    w_u32(buf, vertex_count);
}

/// A vertex morph named `name` offsetting vertex 0 along +x.
fn w_vertex_morph(buf: &mut Vec<u8>, name: &str, global: &str) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, global);
    w_u8(buf, 4); // panel: other
    w_u8(buf, anima_mmd::morph_types::VERTEX);
    w_u32(buf, 1);
    w_index_unsigned(buf, 2, 0);
    for v in [0.5_f32, 0.0, 0.0] {
        w_f32(buf, v);
    }
}

/// Build a valid PMX with `morphs` (name, global) pairs, one texture, one
/// material and two bones.
fn build_pmx(morphs: &[(&str, &str)]) -> Vec<u8> {
    let mut buf = base_header(ENC, 0);
    w_names(&mut buf, ENC);

    // Four vertices forming one triangle plus an off-screen apex.
    w_u32(&mut buf, 4);
    w_vertex(&mut buf, -1.0, 0.0, 0.0, 0.0, 0.0);
    w_vertex(&mut buf, 1.0, 0.0, 0.0, 1.0, 0.0);
    w_vertex(&mut buf, 0.0, 2.0, 0.0, 0.5, 1.0);
    w_vertex(&mut buf, 0.0, -2.0, 0.0, 0.5, 0.0);

    w_u32(&mut buf, 3);
    for i in [0_u32, 1, 2] {
        w_index_unsigned(&mut buf, 2, i);
    }

    w_u32(&mut buf, 1);
    w_str(&mut buf, ENC, "body.png");

    w_u32(&mut buf, 1);
    w_material(&mut buf, "body", 0, 3);

    w_u32(&mut buf, 2);
    w_bone(&mut buf, "センター", "center", -1, [0.0, 0.0, 0.0]);
    w_bone(&mut buf, "足", "leg", 0, [0.0, -1.0, 0.0]);

    w_u32(&mut buf, morphs.len() as u32);
    for (name, global) in morphs {
        w_vertex_morph(&mut buf, name, global);
    }

    w_u32(&mut buf, 0); // display frames
    w_u32(&mut buf, 0); // rigid bodies
    w_u32(&mut buf, 0); // joints
    buf
}

/// A 2x2 opaque PNG (base colour) written next to the model.
fn write_body_png(dir: &std::path::Path) {
    let png = image::ImageBuffer::from_pixel(2u32, 2u32, image::Rgba([200u8, 120, 60, 255]));
    png.save(dir.join("body.png")).expect("write body.png");
}

/// Write `bytes` to a unique temp `.pmx` and return its path.
fn write_model(dir: &std::path::Path, name: &str, bytes: &[u8]) -> String {
    let path = dir.join(name);
    std::fs::write(&path, bytes).expect("write model");
    path.to_str().expect("utf-8 path").to_string()
}

/// Recording platform double: mints monotonic texture ids starting at 1.
struct RecordingRegistry {
    next: AtomicU32,
    registered: AtomicU32,
    released: AtomicU32,
}

impl RecordingRegistry {
    fn new() -> Self {
        Self {
            next: AtomicU32::new(1),
            registered: AtomicU32::new(0),
            released: AtomicU32::new(0),
        }
    }
}

unsafe extern "C" fn register(ctx: *mut c_void, _w: u32, _h: u32) -> u32 {
    let state = unsafe { &*(ctx as *const RecordingRegistry) };
    state.registered.fetch_add(1, Ordering::SeqCst);
    state.next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let state = unsafe { &*(ctx as *const RecordingRegistry) };
    state.released.fetch_add(1, Ordering::SeqCst);
}

struct Harness {
    raw: *mut RecordingRegistry,
    registry: Option<TextureRegistry>,
}

impl Harness {
    fn new() -> Self {
        let raw = Box::into_raw(Box::new(RecordingRegistry::new()));
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

#[test]
fn mmd_native_loads_synthetic_pmx_with_pages_and_geometry() {
    let dir = tempfile::tempdir().expect("temp dir");
    write_body_png(dir.path());
    let path = write_model(dir.path(), "model.pmx", &build_pmx(&[("あ", "a")]));

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer
        .load(&path)
        .expect("synthetic PMX should load through the MMD native driver");

    assert_ne!(handle.id, 0, "expected a native model id");
    assert_ne!(handle.texture_id, u32::MAX, "platform mints the output texture");
    // One base-colour page + the shaded output surface.
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 2);
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 0);

    let frame = renderer.render(handle, 0.0).expect("render frame 0");
    assert_eq!(frame.geometry.vertices.len(), 4);
    assert_eq!(frame.geometry.indices.len(), 3);
    assert_eq!(frame.geometry.draws.len(), 1);
    assert!(
        frame
            .geometry
            .vertices
            .iter()
            .all(|v| v.x.is_finite() && v.y.is_finite() && v.z.is_finite()),
        "non-finite vertex position"
    );

    // The vowel slot resolved; the English fallback candidate was not needed.
    assert_eq!(renderer.resolved_vowels(handle), vec![MorphSlot::VowelA]);

    let pages = renderer.pages(handle).expect("pages");
    assert_eq!(pages.len(), 2);
    assert_eq!(pages[0].format, TextureFormat::Rgba8);
    assert_eq!(
        pages[0].pixels.len(),
        pages[0].width as usize * pages[0].height as usize * 4
    );
    let output = pages.last().expect("output page");
    assert_eq!(output.width, OUTPUT_SIZE);
    assert_eq!(output.height, OUTPUT_SIZE);
    let opaque = output.pixels.chunks_exact(4).filter(|px| px[3] > 0).count();
    assert!(opaque > 100, "expected a shaded silhouette, got {opaque}");

    renderer.dispose(handle).expect("dispose");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 2);
    renderer.dispose(handle).expect("dispose is idempotent");
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 2);
}

#[test]
fn mmd_native_lip_sync_is_independent_and_survives_emotion_switch() {
    let dir = tempfile::tempdir().expect("temp dir");
    write_body_png(dir.path());
    // `あ` (vowel), `まばたき` (blink) and `笑い` (smile): the mixer must keep
    // blink running while the mouth moves, and an emotion switch must not zero
    // either channel.
    let path = write_model(
        dir.path(),
        "model.pmx",
        &build_pmx(&[("あ", "a"), ("まばたき", "blink"), ("笑い", "smile")]),
    );

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer.load(&path).expect("load");

    // Lip-sync moves the `あ` slot and only the `あ` slot.
    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
    assert_eq!(renderer.slot_weight(handle, MorphSlot::Blink), 0.0);
    assert!((renderer.lip_sync(handle).expect("read back") - 1.0).abs() < 1e-6);

    // A blink cue is a separate channel: it does not disturb the mouth.
    renderer.set_emotion(handle, "happy", "emotion", 1.0).expect("emotion");
    for _ in 0..10 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!(
        (renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-3,
        "an emotion switch must not fade the independent lip-sync channel"
    );

    // Switching emotion cross-fades the expression slots additively.
    renderer.set_emotion(handle, "sad", "emotion", 1.0).expect("emotion 2");
    for _ in 0..30 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!(renderer.slot_weight(handle, MorphSlot::Sad) > 0.7);
    assert!(renderer.slot_weight(handle, MorphSlot::Smile) < 0.01);
    // The mouth channel is untouched by the second switch (sad owns no vowel).
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-3);

    // An unknown tag is a loud failure, not a silent no-op.
    let err = renderer
        .set_emotion(handle, "not-an-emotion", "emotion", 1.0)
        .expect_err("unknown emotion must fail");
    assert!(err.to_string().contains("unknown emotion tag"), "{err}");

    renderer.dispose(handle).expect("dispose");
}

/// A group morph addresses its member by PMX index. That index is an address,
/// not a multiplier: a member at index 3 with weight 0.5 must contribute
/// exactly half of the member's vertex offset, not 1.5x the offset.
#[test]
fn mmd_group_morph_uses_member_weights_without_index_multiplication() {
    let dir = tempfile::tempdir().expect("temp dir");
    write_body_png(dir.path());
    let mut pmx = base_header(ENC, 0);
    w_names(&mut pmx, ENC);
    w_u32(&mut pmx, 4);
    w_vertex(&mut pmx, -1.0, 0.0, 0.0, 0.0, 0.0);
    w_vertex(&mut pmx, 1.0, 0.0, 0.0, 1.0, 0.0);
    w_vertex(&mut pmx, 0.0, 2.0, 0.0, 0.5, 1.0);
    w_vertex(&mut pmx, 0.0, -2.0, 0.0, 0.5, 0.0);
    w_u32(&mut pmx, 3);
    for i in [0_u32, 1, 2] { w_index_unsigned(&mut pmx, 2, i); }
    w_u32(&mut pmx, 1);
    w_str(&mut pmx, ENC, "body.png");
    w_u32(&mut pmx, 1);
    w_material(&mut pmx, "body", 0, 3);
    w_u32(&mut pmx, 2);
    w_bone(&mut pmx, "センター", "center", -1, [0.0, 0.0, 0.0]);
    w_bone(&mut pmx, "足", "leg", 0, [0.0, -1.0, 0.0]);
    // Three decoy morphs, then the vowel morph at index 3.
    w_u32(&mut pmx, 5);
    for i in 0..3 { w_vertex_morph(&mut pmx, &format!("blink{i}"), &format!("blink{i}")); }
    w_vertex_morph(&mut pmx, "あ", "a");
    // Group morph: member index 3 (the vowel), member weight 0.5.
    w_str(&mut pmx, ENC, "group");
    w_str(&mut pmx, ENC, "group");
    pmx.push(4); // panel: other
    pmx.push(anima_mmd::morph_types::GROUP);
    w_u32(&mut pmx, 1);
    w_index_signed(&mut pmx, 1, 3);
    w_f32(&mut pmx, 0.5);
    w_u32(&mut pmx, 0); // display frames
    w_u32(&mut pmx, 0); // rigid bodies
    w_u32(&mut pmx, 0); // joints
    let path = write_model(dir.path(), "group.pmx", &pmx);

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer.load(&path).expect("group model loads");
    assert_eq!(renderer.resolved_vowels(handle), vec![MorphSlot::VowelA]);

    // The group is a plain morph (not a logical slot), so only a VMD track
    // can weight it. Bind a minimal motion keying `group` at 0.5.
    let mut vmd_bytes = Vec::new();
    vmd_bytes.extend_from_slice(b"Vocaloid Motion Data 0002\0\0\0\0\0");
    vmd_bytes.extend_from_slice(&[0u8; 20]); // model name
    vmd_bytes.extend_from_slice(&0_u32.to_le_bytes()); // bone keys
    vmd_bytes.extend_from_slice(&1_u32.to_le_bytes()); // morph keys
    let mut morph_name = [0u8; 15];
    morph_name[..5].copy_from_slice(b"group");
    vmd_bytes.extend_from_slice(&morph_name);
    vmd_bytes.extend_from_slice(&0_u32.to_le_bytes()); // frame
    vmd_bytes.extend_from_slice(&0.5_f32.to_le_bytes()); // weight
    for _ in 0..3 { vmd_bytes.extend_from_slice(&0_u32.to_le_bytes()); }
    let vmd_path = dir.path().join("group.vmd");
    std::fs::write(&vmd_path, &vmd_bytes).expect("write VMD");
    let vmd = anima_mmd::VmdMotion::from_path(&vmd_path).expect("synthetic VMD parses");
    renderer.set_motion(handle, vmd).expect("bind group motion");
    let frame = renderer.render(handle, 0.0).expect("frame");
    // The vowel's vertex morph offsets vertex 0 by +0.5 x. The group's own
    // 0.5 VMD weight and the member's 0.5 weight combine to +0.125; scaling
    // by the member index (3) would yield +0.375 instead.
    let x = frame.geometry.vertices[0].x;
    assert!((x - (-1.0 + 0.125)).abs() < 1e-4, "group morph moved vertex 0 to x={x}, expected -0.875");

    renderer.dispose(handle).expect("dispose");
}

#[test]
fn mmd_native_rejects_a_model_without_vowel_morphs_loudly() {
    let dir = tempfile::tempdir().expect("temp dir");
    write_body_png(dir.path());
    // Only a blink morph: lip-sync cannot move a mouth that has no vowel.
    let path = write_model(dir.path(), "mute.pmx", &build_pmx(&[("まばたき", "blink")]));

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    match renderer.load(&path) {
        Err(MmdNativeError::NoVowelMorphs(model)) => {
            assert!(model.contains("テストモデル"), "unexpected model name {model}");
        }
        other => panic!("expected a loud NoVowelMorphs, got {other:?}"),
    }
    // Nothing was minted: the failure happened before any texture existed.
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 0);
}

#[test]
fn mmd_native_missing_and_corrupt_files_fail_loudly() {
    let dir = tempfile::tempdir().expect("temp dir");
    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());

    let missing = dir.path().join("nope.pmx");
    match renderer.load(missing.to_str().expect("utf-8")) {
        Err(MmdNativeError::Load(_)) => {}
        other => panic!("expected a loud Load error, got {other:?}"),
    }

    let corrupt = write_model(dir.path(), "corrupt.pmx", b"not a pmx at all");
    match renderer.load(&corrupt) {
        Err(MmdNativeError::Load(_)) => {}
        other => panic!("expected a loud Load error, got {other:?}"),
    }
    assert_eq!(harness.state().registered.load(Ordering::SeqCst), 0);
}

#[test]
fn mmd_native_unknown_handle_and_dispose_are_safe() {
    let dir = tempfile::tempdir().expect("temp dir");
    write_body_png(dir.path());
    let path = write_model(dir.path(), "model.pmx", &build_pmx(&[("あ", "a")]));

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer.load(&path).expect("load");

    let bogus = airi_render_handle { id: 9999, texture_id: 0 };
    assert!(renderer.render(bogus, 0.0).is_err());
    assert!(renderer.set_lip_sync(bogus, 0.5).is_err());
    assert!(renderer.pages(bogus).is_err());

    renderer.dispose(handle).expect("dispose");
    renderer.dispose(handle).expect("dispose idempotent");
    assert_eq!(renderer.model_count(), 0);
    assert_eq!(harness.state().released.load(Ordering::SeqCst), 2);
}