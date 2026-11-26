// SPDX-License-Identifier: GPL-3.0-or-later
//! Lip-sync conformance for the MMD vowel mixer.
//!
//! The Vue stage (`packages/stage-ui-mmd/src/composables/mmd/lip-sync.ts` and
//! `components/scenes/MMD.vue`) drives the mouth with the vowel morphs, writes
//! `mouthOpenSize * 0.7` into `vowelA`, and fails loudly when the model has no
//! vowel morphs. These tests pin the same contract on the native driver:
//!
//!   * the mouth-open weight lands on the `あ` slot, capped at 0.7,
//!   * the slot weight is clamped to `[0, 1]` and never touches the blink slot,
//!   * an emotion switch does not fade the lip-sync channel,
//!   * a model without vowel morphs is rejected loudly, and a one-shot
//!     `set_lip_sync` on such a model would be too (the renderer never gets
//!     one, because load fails).

use std::ffi::c_void;
use std::sync::atomic::{AtomicU32, Ordering};

use anima_render::contract::{airi_render_handle, TextureRegistry};
use anima_render::mmd_native::{MmdNativeError, MmdNativeRenderer, MorphSlot, VOWEL_SLOTS};

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
    w_index_signed(buf, 2, 0);
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
    w_index_signed(buf, 1, -1); // no texture
    w_index_signed(buf, 1, -1);
    w_u8(buf, anima_mmd::sphere_mode::NONE);
    w_u8(buf, 0);
    w_index_signed(buf, 1, -1);
    w_str(buf, ENC, "");
    w_u32(buf, 3);
}

fn w_vertex_morph(buf: &mut Vec<u8>, name: &str, global: &str) {
    w_str(buf, ENC, name);
    w_str(buf, ENC, global);
    w_u8(buf, 4);
    w_u8(buf, anima_mmd::morph_types::VERTEX);
    w_u32(buf, 1);
    w_index_unsigned(buf, 2, 0);
    for v in [0.5_f32, 0.0, 0.0] {
        w_f32(buf, v);
    }
}

/// A valid PMX carrying exactly the named morphs (no texture file needed).
fn build_pmx(morphs: &[(&str, &str)]) -> Vec<u8> {
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
    w_u32(&mut buf, morphs.len() as u32);
    for (name, global) in morphs {
        w_vertex_morph(&mut buf, name, global);
    }
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    w_u32(&mut buf, 0);
    buf
}

struct Harness {
    raw: *mut AtomicU32,
    registry: Option<TextureRegistry>,
}

unsafe extern "C" fn register(ctx: *mut c_void, _w: u32, _h: u32) -> u32 {
    let next = unsafe { &*(ctx as *const AtomicU32) };
    next.fetch_add(1, Ordering::SeqCst)
}

unsafe extern "C" fn release(ctx: *mut c_void, _id: u32) {
    let released = unsafe { &*(ctx as *const AtomicU32) };
    released.fetch_add(1, Ordering::SeqCst);
}

impl Harness {
    fn new() -> Self {
        let raw = Box::into_raw(Box::new(AtomicU32::new(1)));
        let registry = TextureRegistry::new(register, release, raw as *mut c_void);
        Self {
            raw,
            registry: Some(registry),
        }
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

fn load(dir: &std::path::Path, name: &str, morphs: &[(&str, &str)]) -> (MmdNativeRenderer, airi_render_handle) {
    let path = dir.join(name);
    std::fs::write(&path, build_pmx(morphs)).expect("write model");
    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    let handle = renderer
        .load(path.to_str().expect("utf-8"))
        .expect("model with vowels loads");
    // Leak the harness deliberately: the renderer owns the registry ctx.
    std::mem::forget(harness);
    (renderer, handle)
}

#[test]
fn mouth_open_lands_on_the_vowel_a_slot_capped_at_point_seven() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (mut renderer, handle) = load(dir.path(), "m.pmx", &[("あ", "a")]);

    assert_eq!(renderer.resolved_vowels(handle), vec![MorphSlot::VowelA]);
    assert_eq!(VOWEL_SLOTS.len(), 5);

    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
    assert!((renderer.lip_sync(handle).expect("read back") - 1.0).abs() < 1e-6);

    // A half-open mouth is half of the cap.
    renderer.set_lip_sync(handle, 0.5).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.35).abs() < 1e-6);

    // Out-of-range weights clamp instead of tearing the face.
    renderer.set_lip_sync(handle, 5.0).expect("lip sync");
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
    renderer.set_lip_sync(handle, -3.0).expect("lip sync");
    assert_eq!(renderer.slot_weight(handle, MorphSlot::VowelA), 0.0);
}

#[test]
fn lip_sync_never_touches_the_blink_slot() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (mut renderer, handle) = load(
        dir.path(),
        "m.pmx",
        &[("あ", "a"), ("まばたき", "blink")],
    );

    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    assert_eq!(renderer.slot_weight(handle, MorphSlot::Blink), 0.0);
    for _ in 0..20 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert_eq!(
        renderer.slot_weight(handle, MorphSlot::Blink),
        0.0,
        "the blink loop is a separate channel"
    );
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-6);
}

#[test]
fn an_emotion_switch_does_not_fade_the_lip_sync_channel() {
    let dir = tempfile::tempdir().expect("temp dir");
    let (mut renderer, handle) = load(
        dir.path(),
        "m.pmx",
        &[("あ", "a"), ("笑い", "smile"), ("怒り", "anger")],
    );

    renderer.set_lip_sync(handle, 1.0).expect("lip sync");
    renderer.set_emotion(handle, "happy", "emotion", 1.0).expect("emotion");
    for _ in 0..60 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-3);
    assert!(renderer.slot_weight(handle, MorphSlot::Smile) > 0.7);

    // A second, opposite emotion cross-fades the expression slots only.
    renderer.set_emotion(handle, "angry", "emotion", 1.0).expect("emotion 2");
    for _ in 0..60 {
        renderer.render(handle, 1.0 / 60.0).expect("render");
    }
    assert!(renderer.slot_weight(handle, MorphSlot::Anger) > 0.7);
    assert!(renderer.slot_weight(handle, MorphSlot::Smile) < 0.01);
    assert!((renderer.slot_weight(handle, MorphSlot::VowelA) - 0.7).abs() < 1e-3);
}

#[test]
fn a_model_without_vowel_morphs_is_rejected_loudly() {
    let dir = tempfile::tempdir().expect("temp dir");
    let path = dir.path().join("mute.pmx");
    std::fs::write(&path, build_pmx(&[("まばたき", "blink")])).expect("write model");

    let mut harness = Harness::new();
    let mut renderer = MmdNativeRenderer::create(harness.take());
    match renderer.load(path.to_str().expect("utf-8")) {
        Err(MmdNativeError::NoVowelMorphs(_)) => {}
        other => panic!("expected NoVowelMorphs, got {other:?}"),
    }
    // No texture was minted for a model that cannot lip-sync.
    let raw = harness.raw;
    let minted = unsafe { &*raw };
    assert_eq!(minted.load(Ordering::SeqCst), 1, "only the counter seed");
}