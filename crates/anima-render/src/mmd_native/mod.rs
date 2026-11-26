// SPDX-License-Identifier: GPL-3.0-or-later
//! The first MMD (PMX 2.0 + VMD) renderer behind the frozen render contract.
//!
//! This module is the per-format driver the platform binds to. It drives the
//! CPU side of the pipeline: [`anima_mmd::RestPoseEngine`] assembles the
//! rest-pose mesh, the MToon-ish material table and the interleaved skin
//! buffer; [`Pose`] applies VMD bone and morph tracks on top of it;
//! [`MorphMixer`] resolves the logical morph slots the Vue stage drives
//! (`あ/い/う/え/お`, `まばたき`, `笑い`, …) onto the document's own morph names;
//! and [`raster`] shades the posed triangles into an RGBA8 output page in the
//! frozen frame shape.
//!
//! Texture registration is the platform's: every texture id the renderer
//! reports comes from the platform's `register_texture` callback, and every id
//! is handed back to `release_texture` on dispose. The renderer never invents
//! an id. A missing or corrupt document fails loudly with a typed
//! [`MmdNativeError`] — never an empty frame and never a fabricated texture.
//!
//! Lip-sync is the vowel set and is an independent additive channel: setting
//! the mouth-open weight never disturbs the blink loop, and switching emotion
//! never zeroes either (the mixer only fades the expression slots and vowel
//! accents the previous emotion owned).
//!
//! A model with **no** resolvable vowel morph cannot move its mouth. That is
//! [`MmdNativeError::NoVowelMorphs`]: a loud failure, never a silently mute
//! model.
//!
//! # Deferred, deliberately
//!
//! Physics, IK evaluation, SDEF, sphere/toon texture ramps and the
//! outline/edge passes are out of scope for this renderer (the parser stores
//! IK data and never runs it; SDEF falls back to linear blend inside the
//! parser). Names are decoded from CP932 by the parser before matching. This is
//! not a full Vue-parity claim — see `docs/plan-flutter-native-model-rendering.md`.

pub mod raster;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};
use std::path::Path;

use anima_mmd::{
    MmdError, MmdModel, MmdMorph, MmdMorphOffset, RestPoseEngine, VmdMotion, VERTEX_STRIDE,
};

use crate::contract::backend::{BackendKind, RendererBackend};
use crate::contract::ffi::{airi_render_handle, RenderBackend, TextureRegistry, TextureRollback};
use crate::contract::frame::{
    BlendMode, DrawCommand, FrameGeometry, RenderFrame, TextureFormat, TexturePayload, Vertex,
};
use crate::mmd_native::raster::{Camera, Image, RasterTarget};

/// Edge length of the shaded output surface the platform presents.
pub const OUTPUT_SIZE: u32 = 512;

/// Frames per second a VMD is authored at.
const VMD_FPS: f32 = 30.0;

/// The Vue stage's default emotion cross-fade duration, in seconds.
const EMOTION_BLEND_SECONDS: f32 = 0.4;

/// The cap the Vue stage puts on the mouth-open morph weight.
const MOUTH_OPEN_CAP: f32 = 0.7;

// ---------------------------------------------------------------------------
// Logical morph slots
// ---------------------------------------------------------------------------

/// Logical morph slots AIRI drives, mirroring
/// `packages/stage-ui-mmd/src/constants/morphs.ts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum MorphSlot {
    /// Mouth vowel `あ`.
    VowelA,
    /// Mouth vowel `い`.
    VowelI,
    /// Mouth vowel `う`.
    VowelU,
    /// Mouth vowel `え`.
    VowelE,
    /// Mouth vowel `お`.
    VowelO,
    /// Both eyes closed.
    Blink,
    /// Left eye wink.
    BlinkLeft,
    /// Right eye wink.
    BlinkRight,
    /// Smile.
    Smile,
    /// Anger.
    Anger,
    /// Sadness.
    Sad,
    /// Surprise.
    Surprise,
    /// Troubled.
    Troubled,
    /// Serious.
    Serious,
}

impl MorphSlot {
    /// Every slot, in the order the Vue controller binds them.
    pub const ALL: [MorphSlot; 14] = [
        MorphSlot::VowelA,
        MorphSlot::VowelI,
        MorphSlot::VowelU,
        MorphSlot::VowelE,
        MorphSlot::VowelO,
        MorphSlot::Blink,
        MorphSlot::BlinkLeft,
        MorphSlot::BlinkRight,
        MorphSlot::Smile,
        MorphSlot::Anger,
        MorphSlot::Sad,
        MorphSlot::Surprise,
        MorphSlot::Troubled,
        MorphSlot::Serious,
    ];

    /// Ordered candidate morph names; the first candidate the document has
    /// wins. Japanese names come first because the overwhelming majority of
    /// MMD models ship them; the English fallbacks cover Western exports.
    pub fn candidates(self) -> &'static [&'static str] {
        match self {
            MorphSlot::VowelA => &["あ", "a", "A"],
            MorphSlot::VowelI => &["い", "i", "I"],
            MorphSlot::VowelU => &["う", "u", "U"],
            MorphSlot::VowelE => &["え", "e", "E"],
            MorphSlot::VowelO => &["お", "o", "O"],
            MorphSlot::Blink => &["まばたき", "blink", "Blink"],
            MorphSlot::BlinkLeft => &["ウィンク", "ウインク", "wink", "Wink"],
            MorphSlot::BlinkRight => {
                &["ウィンク右", "ウインク右", "ウィンク2", "wink_r", "Wink_R"]
            }
            MorphSlot::Smile => &["笑い", "にこり", "わらい", "smile", "Smile"],
            MorphSlot::Anger => &["怒り", "いかり", "anger", "Anger"],
            MorphSlot::Sad => &["悲しい", "悲しむ", "sad", "Sad"],
            MorphSlot::Surprise => &["驚き", "びっくり", "surprise", "Surprise"],
            MorphSlot::Troubled => &["困る", "こまる", "troubled", "Troubled"],
            MorphSlot::Serious => &["真面目", "じと目", "serious", "Serious"],
        }
    }

    /// True for the five mouth vowels.
    pub fn is_vowel(self) -> bool {
        matches!(
            self,
            MorphSlot::VowelA
                | MorphSlot::VowelI
                | MorphSlot::VowelU
                | MorphSlot::VowelE
                | MorphSlot::VowelO
        )
    }
}

/// The five vowel slots in mixer order (`あいうえお`).
pub const VOWEL_SLOTS: [MorphSlot; 5] = [
    MorphSlot::VowelA,
    MorphSlot::VowelI,
    MorphSlot::VowelU,
    MorphSlot::VowelE,
    MorphSlot::VowelO,
];

/// The expression slots an emotion cue owns.
const EXPRESSION_SLOTS: [MorphSlot; 6] = [
    MorphSlot::Smile,
    MorphSlot::Anger,
    MorphSlot::Sad,
    MorphSlot::Surprise,
    MorphSlot::Troubled,
    MorphSlot::Serious,
];

/// The slot index of every slot, in [`MorphSlot::ALL`] order.
fn slot_index(slot: MorphSlot) -> usize {
    MorphSlot::ALL
        .iter()
        .position(|candidate| *candidate == slot)
        .expect("every slot is in ALL")
}

/// One emotion's target morph weights, mirroring `EMOTION_MORPHS` in
/// `packages/stage-ui-mmd/src/constants/morphs.ts`.
struct EmotionPreset {
    influences: &'static [(MorphSlot, f32)],
}

/// The emotion table, keyed by the shared AIRI emotion vocabulary
/// (`packages/stage-ui-mmd/src/constants/emotions.ts`).
fn emotion_preset(tag: &str) -> Option<EmotionPreset> {
    use MorphSlot::*;
    let preset = match tag {
        "happy" => EmotionPreset {
            influences: &[(Smile, 0.8)],
        },
        "sad" => EmotionPreset {
            influences: &[(Sad, 0.75), (Troubled, 0.3)],
        },
        "angry" => EmotionPreset {
            influences: &[(Anger, 0.8)],
        },
        "surprised" => EmotionPreset {
            influences: &[(Surprise, 0.8)],
        },
        "think" => EmotionPreset {
            influences: &[(Troubled, 0.5), (Serious, 0.4)],
        },
        "awkward" => EmotionPreset {
            influences: &[(Troubled, 0.6), (Smile, 0.2)],
        },
        "question" => EmotionPreset {
            influences: &[(Troubled, 0.4), (Surprise, 0.2)],
        },
        "curious" => EmotionPreset {
            influences: &[(Surprise, 0.35), (Smile, 0.25)],
        },
        "neutral" => EmotionPreset {
            influences: &[],
        },
        _ => return None,
    };
    Some(preset)
}

// ---------------------------------------------------------------------------
// Errors
// ---------------------------------------------------------------------------

/// Typed diagnostics for the MMD renderer.
///
/// Every variant is a loud failure: the renderer never returns an empty frame
/// or a fabricated texture id to paper over a missing document, an undecodable
/// one, or a model that physically cannot lip-sync.
#[derive(Debug)]
pub enum MmdNativeError {
    /// The file could not be read or parsed as PMX/VMD.
    Load(MmdError),
    /// The document is not a model this driver can drive (no geometry, no
    /// material data, an undecodable base colour, or an unknown emotion tag).
    UnsupportedDocument(String),
    /// The model has no morph matching any vowel candidate, so lip-sync cannot
    /// move its mouth. Reported instead of silently producing a mute model.
    NoVowelMorphs(String),
}

impl std::fmt::Display for MmdNativeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            MmdNativeError::Load(err) => write!(f, "mmd load failed: {err}"),
            MmdNativeError::UnsupportedDocument(message) => {
                write!(f, "unsupported mmd document: {message}")
            }
            MmdNativeError::NoVowelMorphs(model) => write!(
                f,
                "mmd model {model} has no vowel mouth morphs (あ/い/う/え/お); lip-sync cannot move the mouth"
            ),
        }
    }
}

impl std::error::Error for MmdNativeError {}

impl From<MmdError> for MmdNativeError {
    fn from(err: MmdError) -> Self {
        MmdNativeError::Load(err)
    }
}

// ---------------------------------------------------------------------------
// VMD sampling
// ---------------------------------------------------------------------------

/// One bone's animated local transform.
#[derive(Debug, Clone, Copy, PartialEq)]
struct BonePose {
    /// Local translation (as stored; MMD bone keys are model-space deltas).
    position: [f32; 3],
    /// Local rotation (x, y, z, w).
    rotation: [f32; 4],
}

/// The VMD channels sampled at one instant, resolved against the model.
#[derive(Debug, Clone, Default)]
struct Pose {
    /// Bone index → animated local transform.
    bones: HashMap<usize, BonePose>,
    /// Morph index → weight.
    morphs: HashMap<usize, f32>,
}

impl Pose {
    /// Sample every channel of `motion` at `time_seconds`, resolving names
    /// against `bones` (VMD name → PMX bone index) and `morphs` (VMD name →
    /// PMX morph index).
    fn sample(
        motion: &VmdMotion,
        time_seconds: f32,
        bones: &HashMap<String, usize>,
        morphs: &HashMap<String, usize>,
    ) -> Self {
        let frame = (time_seconds.max(0.0) * VMD_FPS).max(0.0);
        let mut pose = Pose::default();
        // VMD bone keys are grouped per bone in file order; walk runs of equal
        // raw names so a bone's keys are sampled against each other only.
        let mut index = 0usize;
        while index < motion.bones.len() {
            let name = &motion.bones[index].name_raw;
            let mut end = index + 1;
            while end < motion.bones.len() && &motion.bones[end].name_raw == name {
                end += 1;
            }
            let run = &motion.bones[index..end];
            let key = run[0].name.as_str();
            let bone = bones.get(key).copied();
            if let (Some(bone), Some(transform)) = (bone, sample_bone_run(run, frame)) {
                pose.bones.insert(bone, transform);
            }
            index = end;
        }
        // Morph keys are grouped per morph the same way.
        let mut index = 0usize;
        while index < motion.morphs.len() {
            let name = &motion.morphs[index].name_raw;
            let mut end = index + 1;
            while end < motion.morphs.len() && &motion.morphs[end].name_raw == name {
                end += 1;
            }
            let run = &motion.morphs[index..end];
            let key = run[0].name.as_str();
            let morph = morphs.get(key).copied();
            if let (Some(morph), Some(weight)) = (morph, sample_morph_run(run, frame)) {
                pose.morphs.insert(morph, weight.clamp(0.0, 1.0));
            }
            index = end;
        }
        pose
    }
}

/// Sample one bone's key run at `frame` (linear between keys, clamped outside
/// the keyed range; MMD's per-channel bezier handles are stored but not
/// evaluated).
fn sample_bone_run(run: &[anima_mmd::VmdBoneKey], frame: f32) -> Option<BonePose> {
    let first = run.first()?;
    let mut at = first;
    for key in run {
        if key.frame as f32 > frame {
            break;
        }
        at = key;
    }
    let next = run.iter().find(|key| key.frame as f32 > frame);
    let Some(next) = next else {
        return Some(BonePose {
            position: at.position,
            rotation: at.rotation,
        });
    };
    let span = (next.frame as f32 - at.frame as f32).max(1.0);
    let t = ((frame - at.frame as f32) / span).clamp(0.0, 1.0);
    let mut position = at.position;
    for c in 0..3 {
        position[c] += (next.position[c] - position[c]) * t;
    }
    Some(BonePose {
        position,
        rotation: slerp(at.rotation, next.rotation, t),
    })
}

/// Spherical interpolation between two quaternions (x, y, z, w), with the
/// shortest-arc fix and a linear fallback for near-identical inputs.
fn slerp(a: [f32; 4], b: [f32; 4], t: f32) -> [f32; 4] {
    let dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
    let (a, b, dot) = if dot < 0.0 {
        (a, [-b[0], -b[1], -b[2], -b[3]], -dot)
    } else {
        (a, b, dot)
    };
    let dot = dot.clamp(0.0, 1.0);
    let (wa, wb) = if dot > 0.9995 {
        (1.0 - t, t)
    } else {
        let theta = dot.acos();
        let s = theta.sin();
        (((1.0 - t) * theta).sin() / s, (t * theta).sin() / s)
    };
    let mut out = [
        a[0] * wa + b[0] * wb,
        a[1] * wa + b[1] * wb,
        a[2] * wa + b[2] * wb,
        a[3] * wa + b[3] * wb,
    ];
    let len = (out[0] * out[0] + out[1] * out[1] + out[2] * out[2] + out[3] * out[3]).sqrt();
    if len > 1e-8 {
        for c in &mut out {
            *c /= len;
        }
    }
    out
}

/// Sample one morph's key run at `frame`.
fn sample_morph_run(run: &[anima_mmd::VmdMorphKey], frame: f32) -> Option<f32> {
    let first = run.first()?;
    let mut at = first;
    for key in run {
        if key.frame as f32 > frame {
            break;
        }
        at = key;
    }
    let next = run.iter().find(|key| key.frame as f32 > frame);
    let Some(next) = next else {
        return Some(at.weight);
    };
    let span = (next.frame as f32 - at.frame as f32).max(1.0);
    let t = ((frame - at.frame as f32) / span).clamp(0.0, 1.0);
    Some(at.weight + (next.weight - at.weight) * t)
}

// ---------------------------------------------------------------------------
// Morph mixer
// ---------------------------------------------------------------------------

/// The logical-slot view over a document's morph table.
///
/// Resolution mirrors `createMorphController` in
/// `packages/stage-ui-mmd/src/composables/mmd/morph.ts`: a slot binds to the
/// first candidate name the document actually has, and a slot the document
/// cannot satisfy stays unbound (never a fabricated morph).
#[derive(Debug, Clone, Default)]
pub struct MorphMixer {
    /// Logical slot → morph index.
    bound: HashMap<MorphSlot, usize>,
    /// Every morph name the document exposes (local and global spellings).
    available: Vec<String>,
}

impl MorphMixer {
    /// Bind every slot the document can satisfy.
    pub fn resolve(document: &MmdModel) -> Self {
        let mut available = Vec::with_capacity(document.morphs.len() * 2);
        for morph in &document.morphs {
            available.push(morph.name.clone());
            if !morph.name_global.is_empty() && morph.name_global != morph.name {
                available.push(morph.name_global.clone());
            }
        }
        let lookup = |name: &str| {
            document
                .morphs
                .iter()
                .position(|morph| morph.name == name || morph.name_global == name)
        };
        let mut bound = HashMap::new();
        for slot in MorphSlot::ALL {
            if let Some(index) = slot.candidates().iter().find_map(|name| lookup(name)) {
                bound.insert(slot, index);
            }
        }
        MorphMixer { bound, available }
    }

    /// The morph index bound to `slot`, if any.
    pub fn slot(&self, slot: MorphSlot) -> Option<usize> {
        self.bound.get(&slot).copied()
    }

    /// The slots the document resolved, in [`MorphSlot::ALL`] order.
    pub fn resolved_slots(&self) -> Vec<MorphSlot> {
        MorphSlot::ALL
            .into_iter()
            .filter(|slot| self.bound.contains_key(slot))
            .collect()
    }

    /// The resolved vowel slots, in mixer order.
    pub fn resolved_vowels(&self) -> Vec<MorphSlot> {
        VOWEL_SLOTS
            .into_iter()
            .filter(|slot| self.bound.contains_key(slot))
            .collect()
    }

    /// Every morph name the document exposes.
    pub fn available(&self) -> &[String] {
        &self.available
    }

    /// The logical slot a morph is bound to, if any.
    fn slot_of(&self, morph: usize) -> Option<MorphSlot> {
        self.bound
            .iter()
            .find(|(_, index)| **index == morph)
            .map(|(slot, _)| *slot)
    }
}

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

/// One live MMD model.
pub(crate) struct Model {
    /// Rest-pose engine: interleaved vertices, primitives and materials.
    rest: RestPoseEngine,
    /// The parsed document (bones, morphs) the VMD tracks resolve against.
    document: MmdModel,
    /// Logical-slot view over the document's morphs.
    mixer: MorphMixer,
    /// Decoded base-colour pages, one per distinct resolved texture.
    pages: Vec<Image>,
    /// Material index → page index.
    page_by_material: HashMap<u32, u32>,
    /// One platform texture id per decoded page, then the output surface's.
    texture_ids: Vec<u32>,
    /// Shaded RGBA8 output page (rebuilt every frame).
    output: Image,
    camera: Camera,
    /// VMD bone name → PMX bone index.
    bone_by_name: HashMap<String, usize>,
    /// VMD morph name → PMX morph index.
    morph_by_name: HashMap<String, usize>,
    /// The motion bound to this model, if any.
    motion: Option<VmdMotion>,
    /// VMD channels sampled at `time_seconds`.
    pose: Pose,
    /// Current VMD time in seconds.
    time_seconds: f32,
    /// Smoothed logical-slot weights (the mixer's output).
    weights: [f32; 14],
    /// Mouth-open weight the platform last applied (the lip-sync sink).
    lip_sync_sink: f32,
    /// Last applied emotion cue.
    emotion: (String, String, f32),
    /// Slot weights the current emotion cross-fade started from.
    emotion_from: [f32; 14],
    /// Slot weights the current emotion cross-fades to.
    emotion_to: [f32; 14],
    /// Cross-fade progress in `0..=1` (1 = settled).
    emotion_progress: f32,
    /// Continuous idle/ambient phase.
    ambient_phase: f32,
    /// Resolved vertex positions for the current pose (reused every frame).
    positions: Vec<[f32; 3]>,
    /// The interleaved rest buffer's uv0, indexed by vertex.
    uv0: Vec<[f32; 2]>,
    /// Scratch for the skinned result (reused every frame).
    skinned: Vec<[f32; 3]>,
}

impl Model {
    /// Advance the clock, the VMD tracks, the emotion cross-fade and the
    /// mouth-open channel, then re-shade.
    fn tick(&mut self, delta_seconds: f32) {
        let dt = delta_seconds.max(0.0);
        self.time_seconds += dt;
        if let Some(motion) = &self.motion {
            self.pose = Pose::sample(motion, self.time_seconds, &self.bone_by_name, &self.morph_by_name);
        }
        self.advance_emotion(dt);
        self.reassert_lip_sync();
        self.resolve_positions();
        self.shade();
    }

    /// Cross-fade the emotion-owned slots toward their targets.
    fn advance_emotion(&mut self, dt: f32) {
        if self.emotion_progress >= 1.0 {
            return;
        }
        self.emotion_progress = (self.emotion_progress + dt / EMOTION_BLEND_SECONDS).min(1.0);
        let t = ease_in_out_cubic(self.emotion_progress);
        for slot in EXPRESSION_SLOTS {
            let index = slot_index(slot);
            self.weights[index] =
                self.emotion_from[index] + (self.emotion_to[index] - self.emotion_from[index]) * t;
        }
        for slot in VOWEL_SLOTS {
            let index = slot_index(slot);
            self.weights[index] =
                self.emotion_from[index] + (self.emotion_to[index] - self.emotion_from[index]) * t;
        }
    }

    /// Re-assert the mouth-open weight after the emotion cross-fade.
    ///
    /// Lip-sync is an independent additive channel: an emotion cross-fade must
    /// never fade it out, so the `あ` slot is restored to the live sink value
    /// (capped) every tick.
    fn reassert_lip_sync(&mut self) {
        let index = slot_index(MorphSlot::VowelA);
        self.weights[index] = self.weights[index].max(self.lip_sync_sink * MOUTH_OPEN_CAP);
    }

    /// The effective weight of a morph: the logical-slot weight when AIRI owns
    /// the morph, otherwise the VMD track weight.
    fn morph_weight(&self, index: usize) -> f32 {
        if let Some(slot) = self.mixer.slot_of(index) {
            return self.weights[slot_index(slot)];
        }
        self.pose
            .morphs
            .get(&index)
            .copied()
            .unwrap_or(0.0)
            .clamp(0.0, 1.0)
    }

    /// Recompute the posed vertex positions: rest → bone skinning → vertex
    /// morphs (group morphs are expanded recursively).
    fn resolve_positions(&mut self) {
        let vertex_count = self.document.vertices.len();
        self.positions.clear();
        self.positions
            .extend(self.document.vertices.iter().map(|vertex| vertex.position));
        self.positions.resize(vertex_count, [0.0, 0.0, 0.0]);
        self.apply_bone_transforms();
        self.apply_morphs(0);
    }

    /// Apply the VMD bone transforms to every vertex whose skin references an
    /// animated bone (linear blend skinning over the rest pose).
    fn apply_bone_transforms(&mut self) {
        if self.pose.bones.is_empty() {
            return;
        }
        let bones = &self.document.bones;
        let source = self.rest.vertex_bytes();
        self.skinned.clear();
        self.skinned.resize(self.positions.len(), [0.0, 0.0, 0.0]);
        for vertex_index in 0..self.positions.len() {
            let rest = self.positions[vertex_index];
            let (joints, weights) = skin(source, vertex_index);
            let mut position = [0.0f32; 3];
            for slot in 0..4 {
                let weight = weights[slot];
                if weight == 0.0 {
                    continue;
                }
                let joint = joints[slot] as usize;
                let posed = match (bones.get(joint), self.pose.bones.get(&joint)) {
                    (Some(bone), Some(pose)) => transform_point(rest, bone.position, pose),
                    _ => rest,
                };
                position[0] += posed[0] * weight;
                position[1] += posed[1] * weight;
                position[2] += posed[2] * weight;
            }
            self.skinned[vertex_index] = position;
        }
        self.positions = self.skinned.clone();
    }

    /// Apply vertex morphs at the current weights, expanding group morphs.
    fn apply_morphs(&mut self, depth: usize) {
        if depth > 8 {
            return; // defensive: a cyclic group morph must not recurse forever
        }
        for (index, morph) in self.document.morphs.clone().into_iter().enumerate() {
            let morph = &morph;
            let weight = self.morph_weight(index);
            if weight == 0.0 {
                continue;
            }
            match morph.morph_type {
                anima_mmd::morph_types::VERTEX => {
                    for offset in &morph.offsets {
                        let MmdMorphOffset::Vertex {
                            vertex_index,
                            offset: delta,
                        } = offset
                        else {
                            continue;
                        };
                        let Some(position) = self.positions.get_mut(*vertex_index as usize) else {
                            continue;
                        };
                        position[0] += delta[0] * weight;
                        position[1] += delta[1] * weight;
                        position[2] += delta[2] * weight;
                    }
                }
                anima_mmd::morph_types::GROUP => {
                    for offset in &morph.offsets {
                        let MmdMorphOffset::Group {
                            morph_index,
                            weight: member_weight,
                        } = offset
                        else {
                            continue;
                        };
                        if *morph_index < 0 {
                            continue;
                        }
                        let member = *morph_index as usize;
                        let Some(target) = self.document.morphs.get(member).cloned() else {
                            continue;
                        };
                        // A group's own weight already scales every member. A
                        // member can be a logical slot (e.g. `あ`), but it is
                        // being driven *through* the group here: reading its
                        // slot weight would suppress the group entirely.
                        self.apply_group_member(&target, member_weight * weight, depth + 1);
                    }
                }
                _ => {}
            }
        }
    }

    /// Apply one group member's morph with an already-multiplied weight.
    fn apply_group_member(&mut self, morph: &MmdMorph, weight: f32, depth: usize) {
        if weight == 0.0 {
            return;
        }
        match morph.morph_type {
            anima_mmd::morph_types::VERTEX => {
                for offset in &morph.offsets {
                    let MmdMorphOffset::Vertex {
                        vertex_index,
                        offset: delta,
                    } = offset
                    else {
                        continue;
                    };
                    let Some(position) = self.positions.get_mut(*vertex_index as usize) else {
                        continue;
                    };
                    position[0] += delta[0] * weight;
                    position[1] += delta[1] * weight;
                    position[2] += delta[2] * weight;
                }
            }
            anima_mmd::morph_types::GROUP => {
                if depth > 8 {
                    return;
                }
                for offset in &morph.offsets {
                    let MmdMorphOffset::Group {
                        morph_index,
                        weight: member_weight,
                    } = offset
                    else {
                        continue;
                    };
                    if *morph_index < 0 {
                        continue;
                    }
                    let member = *morph_index as usize;
                    let Some(target) = self.document.morphs.get(member).cloned() else {
                        continue;
                    };
                    // Nested groups propagate the incoming (already scaled)
                    // weight; the member index is an address, not a factor.
                    self.apply_group_member(&target, member_weight * weight, depth + 1);
                }
            }
            _ => {}
        }
    }

    /// Shade the posed triangles with the document's material table.
    fn shade(&mut self) {
        let mut min_x = f32::MAX;
        let mut min_y = f32::MAX;
        let mut max_x = f32::MIN;
        let mut max_y = f32::MIN;
        for position in &self.positions {
            min_x = min_x.min(position[0]);
            max_x = max_x.max(position[0]);
            min_y = min_y.min(position[1]);
            max_y = max_y.max(position[1]);
        }
        if min_x == f32::MAX {
            return;
        }
        let height = (max_y - min_y).max(0.001);
        self.camera = Camera {
            center: [(min_x + max_x) * 0.5, (min_y + max_y) * 0.5],
            scale: self.output.height as f32 / height,
        };
        let mut target = RasterTarget::new(self.output.width, self.output.height);
        raster::rasterize(self, &mut target, &self.camera);
        self.output = target.into_image();
    }

    /// The frozen-contract frame for the current output page.
    fn frame(&self) -> RenderFrame {
        let mut vertices = Vec::with_capacity(self.positions.len());
        let mut indices = Vec::new();
        let mut draws = Vec::new();
        // The shaded output page is the last page; every primitive draws into
        // it, splitting the shared vertex buffer by its own index range.
        let page = self.pages.len() as u32;
        let count = self.positions.len() as u32;
        for (position, uv) in self.positions.iter().zip(self.uv0.iter()) {
            vertices.push(Vertex {
                x: position[0],
                y: position[1],
                z: position[2],
                u: uv[0],
                v: uv[1],
            });
        }
        let mut vertex_offset = 0u32;
        for index in 0..self.rest.primitive_count() {
            let Some(index_bytes) = self.rest.index_bytes(index) else {
                continue;
            };
            let index_offset = indices.len() as u32;
            for chunk in index_bytes.chunks_exact(4) {
                indices.push(u32::from_le_bytes([
                    chunk[0], chunk[1], chunk[2], chunk[3],
                ]));
            }
            if indices.len() as u32 > index_offset {
                draws.push(DrawCommand {
                    page,
                    blend: BlendMode::Normal,
                    alpha: 1.0,
                    vertex_offset,
                    vertex_count: count,
                    index_offset,
                    index_count: indices.len() as u32 - index_offset,
                });
            }
            vertex_offset += count;
        }
        RenderFrame {
            pages: Vec::new(),
            geometry: FrameGeometry {
                vertices,
                indices,
                draws,
            },
        }
    }
}

/// The four skin joints/weights of a vertex, read from the rest engine's
/// interleaved buffer.
fn skin(source: &[u8], vertex_index: usize) -> ([u32; 4], [f32; 4]) {
    let offset = vertex_index * VERTEX_STRIDE + 32;
    let mut joints = [0u32; 4];
    let mut weights = [0.0f32; 4];
    for slot in 0..4 {
        let at = offset + slot * 4;
        joints[slot] =
            u32::from_le_bytes([source[at], source[at + 1], source[at + 2], source[at + 3]]);
        let at = offset + 16 + slot * 4;
        weights[slot] =
            f32::from_le_bytes([source[at], source[at + 1], source[at + 2], source[at + 3]]);
    }
    (joints, weights)
}

/// Rotate `point` about `bone_position` by `pose.rotation`, then offset by the
/// bone's rest position and animated translation.
fn transform_point(point: [f32; 3], bone_position: [f32; 3], pose: &BonePose) -> [f32; 3] {
    let local = [
        point[0] - bone_position[0],
        point[1] - bone_position[1],
        point[2] - bone_position[2],
    ];
    let [x, y, z, w] = pose.rotation;
    let (px, py, pz) = (local[0], local[1], local[2]);
    let tx = 2.0 * (y * pz - z * py);
    let ty = 2.0 * (z * px - x * pz);
    let tz = 2.0 * (x * py - y * px);
    let rotated = [
        px + w * tx + (y * tz - z * ty),
        py + w * ty + (z * tx - x * tz),
        pz + w * tz + (x * ty - y * tx),
    ];
    [
        rotated[0] + bone_position[0] + pose.position[0],
        rotated[1] + bone_position[1] + pose.position[1],
        rotated[2] + bone_position[2] + pose.position[2],
    ]
}

/// Ease-in-out cubic, matching the Vue emote cross-fade.
fn ease_in_out_cubic(t: f32) -> f32 {
    if t < 0.5 {
        4.0 * t * t * t
    } else {
        1.0 - (-2.0 * t + 2.0).powi(3) / 2.0
    }
}

/// Decode one texture blob into RGBA8 pixels.
fn decode_texture(bytes: &[u8]) -> Option<Image> {
    let decoded = image::load_from_memory(bytes).ok()?.to_rgba8();
    Some(Image::new(decoded.width(), decoded.height()).with_pixels(decoded.into_raw()))
}

// ---------------------------------------------------------------------------
// Renderer
// ---------------------------------------------------------------------------

/// The MMD renderer: the frozen backend plus the models it drives.
///
/// It is `Send` (the backend is confined to one render thread) and not `Sync`;
/// the platform drives it from a single thread.
pub struct MmdNativeRenderer {
    backend: RenderBackend,
    models: Vec<Option<Model>>,
}

// The backend is Send; the renderer owns it and adds no shared state.
unsafe impl Send for MmdNativeRenderer {}

impl Drop for MmdNativeRenderer {
    fn drop(&mut self) {
        // Idempotent with dispose(): disposed models have been taken out of
        // their slots already, so no id is released twice.
        for model in self.models.iter_mut().flatten() {
            for id in model.texture_ids.drain(..) {
                let _ = self.backend.release_texture(id);
            }
        }
    }
}

impl MmdNativeRenderer {
    /// Create a renderer bound to the platform's texture registry.
    ///
    /// `registry` carries the platform's `register_texture` /
    /// `release_texture` closures and opaque ctx; the renderer never
    /// fabricates a texture id.
    pub fn create(registry: TextureRegistry) -> Self {
        MmdNativeRenderer {
            backend: RenderBackend::create(crate::contract::kind::MMD, registry),
            models: Vec::new(),
        }
    }

    /// The model kind this renderer serves.
    pub fn kind(&self) -> BackendKind {
        BackendKind::Mmd
    }

    /// Resolve a handle to its slot.
    fn slot(&self, handle: airi_render_handle) -> anyhow::Result<usize> {
        (handle.id as usize)
            .checked_sub(1)
            .filter(|index| *index < self.models.len())
            .ok_or_else(|| anyhow::anyhow!("mmd: unknown handle {}", handle.id))
    }

    fn model(&self, handle: airi_render_handle) -> anyhow::Result<&Model> {
        let index = self.slot(handle)?;
        self.models[index]
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("mmd: handle {} is disposed", handle.id))
    }

    fn model_mut(&mut self, handle: airi_render_handle) -> anyhow::Result<&mut Model> {
        let index = self.slot(handle)?;
        self.models[index]
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("mmd: handle {} is disposed", handle.id))
    }

    /// Load a `.pmx` and return its handle.
    ///
    /// Fails loudly with [`MmdNativeError::NoVowelMorphs`] when the model has
    /// no vowel morph (lip-sync would be a lie), and with
    /// [`MmdNativeError::UnsupportedDocument`] when it has no renderable
    /// geometry or no material data — never an empty render and never a
    /// fabricated texture.
    pub fn load(&mut self, asset_path: &str) -> Result<airi_render_handle, MmdNativeError> {
        let rest = RestPoseEngine::from_path(asset_path)?;
        let document = anima_mmd::MmdModel::from_path(asset_path)?;
        if document.vertices.is_empty() || document.faces.is_empty() {
            return Err(MmdNativeError::UnsupportedDocument(format!(
                "{asset_path} has no renderable geometry"
            )));
        }
        if rest.materials().is_empty() {
            return Err(MmdNativeError::UnsupportedDocument(format!(
                "{asset_path} has no material data"
            )));
        }
        let mixer = MorphMixer::resolve(&document);
        if mixer.resolved_vowels().is_empty() {
            return Err(MmdNativeError::NoVowelMorphs(
                document.name.clone(),
            ));
        }

        // Decode each material's base colour once and let the platform mint a
        // texture id for it. Materials that resolve to the same file share a
        // page; a material whose texture is missing is untextured, not fatal
        // (the parser counts the failure and the shading falls back to the
        // flat base colour).
        let mut rollback = TextureRollback::new(self.backend.registry());
        let mut pages: Vec<Image> = Vec::new();
        let mut page_by_material: HashMap<u32, u32> = HashMap::new();
        let mut page_by_source: HashMap<String, u32> = HashMap::new();
        for (index, material) in rest.materials().iter().enumerate() {
            let Some(texture) = &material.texture else {
                continue;
            };
            let source = format!("{}:{}", texture.bytes.len(), texture.extension);
            let page = match page_by_source.get(&source) {
                Some(page) => *page,
                None => {
                    let image = decode_texture(&texture.bytes).ok_or_else(|| {
                        MmdNativeError::UnsupportedDocument(format!(
                            "{asset_path} material {index} base colour is not decodable"
                        ))
                    })?;
                    let texture_id = self.backend.register_texture(image.width, image.height).map_err(|err| MmdNativeError::UnsupportedDocument(format!("{asset_path}: platform refused a texture: {err}")))?;
                    rollback.track(texture_id);
                    page_by_source.insert(source, pages.len() as u32);
                    pages.push(image);
                    (pages.len() - 1) as u32
                }
            };
            page_by_material.insert(index as u32, page);
        }

        // The output surface is the model's own texture, minted by the
        // platform, never an id this driver invents.
        let output_texture_id = self.backend.register_texture(OUTPUT_SIZE, OUTPUT_SIZE).map_err(|err| MmdNativeError::UnsupportedDocument(format!("{asset_path}: platform refused the output surface: {err}")))?;
        rollback.track(output_texture_id);

        let bone_by_name = document
            .bones
            .iter()
            .enumerate()
            .map(|(index, bone)| (bone.name.clone(), index))
            .collect();
        let morph_by_name = document
            .morphs
            .iter()
            .enumerate()
            .map(|(index, morph)| (morph.name.clone(), index))
            .collect();
        let uv0 = document
            .vertices
            .iter()
            .map(|vertex| vertex.uv)
            .collect();

        let mut model = Model {
            rest,
            document,
            mixer,
            pages,
            page_by_material,
            texture_ids: rollback.commit(),
            output: Image::new(OUTPUT_SIZE, OUTPUT_SIZE),
            camera: Camera::default(),
            bone_by_name,
            morph_by_name,
            motion: None,
            pose: Pose::default(),
            time_seconds: 0.0,
            weights: [0.0; 14],
            lip_sync_sink: 0.0,
            emotion: (String::new(), String::new(), 0.0),
            emotion_from: [0.0; 14],
            emotion_to: [0.0; 14],
            emotion_progress: 1.0,
            ambient_phase: 0.0,
            positions: Vec::new(),
            uv0,
            skinned: Vec::new(),
        };
        model.tick(0.0);
        let handle = airi_render_handle {
            id: self.models.len() as u64 + 1,
            texture_id: output_texture_id,
        };
        self.models.push(Some(model));
        Ok(handle)
    }

    /// Texture pages for a loaded model: the decoded base colours, then the
    /// shaded output surface the platform presents.
    pub fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<TexturePayload>> {
        let model = self.model(handle)?;
        let mut pages = Vec::with_capacity(model.pages.len() + 1);
        for (index, image) in model.pages.iter().enumerate() {
            pages.push(TexturePayload {
                name: format!("mmd-page-{index}"),
                width: image.width,
                height: image.height,
                format: TextureFormat::Rgba8,
                premultiplied_alpha: false,
                pixels: image.pixels.clone(),
            });
        }
        pages.push(TexturePayload {
            name: "mmd-output".to_string(),
            width: model.output.width,
            height: model.output.height,
            format: TextureFormat::Rgba8,
            premultiplied_alpha: false,
            pixels: model.output.pixels.clone(),
        });
        Ok(pages)
    }

    /// Geometry for the next frame without advancing time or re-shading.
    ///
    /// The frozen ABI's frame-count call uses this so sizing a frame does not
    /// silently render it a second time.
    pub fn frame_geometry(&self, handle: airi_render_handle) -> anyhow::Result<FrameGeometry> {
        Ok(self.model(handle)?.frame().geometry)
    }

    /// Advance by `delta_seconds` and return the resolved frame.
    pub fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame> {
        let model = self.model_mut(handle)?;
        model.tick(delta_seconds);
        Ok(model.frame())
    }

    /// Set the continuous mouth-open weight in `[0, 1]` (the `あ` channel).
    ///
    /// Fails loudly when the model has no vowel morph rather than silently
    /// doing nothing.
    pub fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        if model.mixer.resolved_vowels().is_empty() {
            anyhow::bail!(
                "mmd: model has no vowel mouth morphs (あ/い/う/え/お); lip-sync cannot move the mouth"
            );
        }
        model.lip_sync_sink = weight.clamp(0.0, 1.0);
        let index = slot_index(MorphSlot::VowelA);
        model.weights[index] = model.lip_sync_sink * MOUTH_OPEN_CAP;
        Ok(())
    }

    /// Apply one expression/motion cue by semantic tag.
    ///
    /// Unknown tags fail loudly; the cue is additive in the sense that only the
    /// slots the previous emotion owned are faded, so blink and lip-sync keep
    /// running.
    pub fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        let preset = emotion_preset(tag).ok_or_else(|| {
            anyhow::anyhow!("mmd: unknown emotion tag {tag:?} (the model has no such morph set)")
        })?;
        let normalized = intensity.clamp(0.0, 1.0);
        model.emotion_from = model.weights;
        model.emotion_to = model.weights;
        for slot in EXPRESSION_SLOTS {
            model.emotion_to[slot_index(slot)] = 0.0;
        }
        for slot in VOWEL_SLOTS {
            model.emotion_to[slot_index(slot)] = 0.0;
        }
        for (slot, value) in preset.influences {
            model.emotion_to[slot_index(*slot)] = value * normalized;
        }
        model.emotion_progress = 0.0;
        model.emotion = (tag.to_string(), kind.to_string(), normalized);
        Ok(())
    }

    /// Bind a parsed VMD motion to a loaded model.
    ///
    /// The motion's bone and morph channels are sampled at `frame / 30` on
    /// every tick; AIRI-owned morph slots keep their logical weights, so a VMD
    /// morph that shares a name with a vowel/blink slot does not fight the
    /// mixer.
    pub fn set_motion(
        &mut self,
        handle: airi_render_handle,
        motion: VmdMotion,
    ) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        model.motion = Some(motion);
        model.time_seconds = 0.0;
        model.pose = Pose::default();
        model.tick(0.0);
        Ok(())
    }

    /// Drop the bound motion (the model returns to its rest pose + mixer).
    pub fn clear_motion(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        model.motion = None;
        model.pose = Pose::default();
        model.tick(0.0);
        Ok(())
    }

    /// The VMD time in seconds (diagnostics).
    pub fn motion_time(&self, handle: airi_render_handle) -> anyhow::Result<f32> {
        Ok(self.model(handle)?.time_seconds)
    }

    /// Set a continuous idle/ambient motion phase in `[0, 1]`.
    pub fn set_ambient_phase(
        &mut self,
        handle: airi_render_handle,
        phase: f32,
    ) -> anyhow::Result<()> {
        self.model_mut(handle)?.ambient_phase = phase.clamp(0.0, 1.0);
        Ok(())
    }

    /// Read back the current mouth-open weight (observable lip-sync sink).
    pub fn lip_sync(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        Ok(self.model(handle)?.lip_sync_sink)
    }

    /// Read back the current emotion cue (observable emotion sink).
    pub fn emotion(&mut self, handle: airi_render_handle) -> anyhow::Result<(String, String, f32)> {
        Ok(self.model(handle)?.emotion.clone())
    }

    /// Read back the current ambient phase (observable ambient sink).
    pub fn ambient_phase(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        Ok(self.model(handle)?.ambient_phase)
    }

    /// The logical slots the document resolved (diagnostics / settings UI).
    pub fn resolved_slots(&self, handle: airi_render_handle) -> Vec<MorphSlot> {
        self.model(handle)
            .map(|model| model.mixer.resolved_slots())
            .unwrap_or_default()
    }

    /// The resolved vowel slots, in mixer order.
    pub fn resolved_vowels(&self, handle: airi_render_handle) -> Vec<MorphSlot> {
        self.model(handle)
            .map(|model| model.mixer.resolved_vowels())
            .unwrap_or_default()
    }

    /// Every morph name the document exposes.
    pub fn available_morphs(&self, handle: airi_render_handle) -> Vec<String> {
        self.model(handle)
            .map(|model| model.mixer.available().to_vec())
            .unwrap_or_default()
    }

    /// The current weight of a logical slot, as the mixer applied it.
    pub fn slot_weight(&self, handle: airi_render_handle, slot: MorphSlot) -> f32 {
        self.model(handle)
            .map(|model| model.weights[slot_index(slot)])
            .unwrap_or(0.0)
    }

    /// The document's material names, index-aligned with the primitives.
    pub fn material_names(&self, handle: airi_render_handle) -> Vec<String> {
        self.model(handle)
            .map(|model| {
                model
                    .rest
                    .materials()
                    .iter()
                    .map(|material| material.name.clone())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// How many models are live (diagnostics).
    pub fn model_count(&self) -> usize {
        self.models.iter().filter(|model| model.is_some()).count()
    }

    /// Release all native resources for `handle` (and its textures). Idempotent.
    pub fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        let Some(index) = (handle.id as usize)
            .checked_sub(1)
            .filter(|index| *index < self.models.len())
        else {
            return Ok(()); // idempotent
        };
        if let Some(model) = self.models[index].take() {
            for id in model.texture_ids {
                self.backend.release_texture(id)?;
            }
        }
        Ok(())
    }
}

impl RendererBackend for MmdNativeRenderer {
    fn kind(&self) -> BackendKind {
        BackendKind::Mmd
    }

    fn load(&mut self, asset_path: &str) -> anyhow::Result<(airi_render_handle, RenderFrame)> {
        let handle = self.load(asset_path)?;
        let frame = self.render(handle, 0.0)?;
        Ok((handle, frame))
    }

    fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<TexturePayload>> {
        self.pages(handle)
    }

    fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame> {
        self.render(handle, delta_seconds)
    }

    fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()> {
        self.set_lip_sync(handle, weight)
    }

    fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()> {
        self.set_emotion(handle, tag, kind, intensity)
    }

    fn set_ambient_phase(&mut self, handle: airi_render_handle, phase: f32) -> anyhow::Result<()> {
        self.set_ambient_phase(handle, phase)
    }

    fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        self.dispose(handle)
    }
}

// ---------------------------------------------------------------------------
// C ABI for the MMD backend in `cpp/mmd_backend.cpp`.
//
// The frozen `render_contract.h` dispatch reaches the MMD driver through these
// `anima_mmd_*` entry points; the C++ side owns the `airi_render_backend`
// table and mints no texture id of its own. Each function maps 1:1 onto an
// `MmdNativeRenderer` method, so the C ABI stays a thin, checked shell.
// ---------------------------------------------------------------------------

/// The renderer instance the C ABI drives (one per backend).
///
/// The C++ side holds it as an opaque `void *`; every entry point takes it back
/// as the first argument.
pub struct MmdCInstance {
    renderer: MmdNativeRenderer,
    /// Last error message, NUL-terminated.
    error: Vec<u8>,
    /// Storage for the emotion tag handed back through the C ABI.
    emotion_tag: CString,
}

/// The frozen error codes the C ABI reports.
const MMD_OK: i32 = 0;
const MMD_ERR: i32 = 1;

/// Build a renderer from the platform's texture registry.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_create(
    register: Option<unsafe extern "C" fn(*mut c_void, u32, u32) -> u32>,
    release: Option<unsafe extern "C" fn(*mut c_void, u32)>,
    ctx: *mut c_void,
    out_renderer: *mut *mut MmdCInstance,
) -> i32 {
    if out_renderer.is_null() {
        return MMD_ERR;
    }
    let Some(register) = register else {
        return MMD_ERR;
    };
    unsafe extern "C" fn noop_release(_: *mut c_void, _: u32) {}
    let release: unsafe extern "C" fn(*mut c_void, u32) = release.unwrap_or(noop_release);
    let registry = TextureRegistry::new(register, release, ctx);
    let instance = Box::new(MmdCInstance {
        renderer: MmdNativeRenderer::create(registry),
        error: b"\0".to_vec(),
        emotion_tag: CString::new("").expect("empty"),
    });
    *out_renderer = Box::into_raw(instance);
    MMD_OK
}

/// Destroy a renderer created by [`anima_mmd_create`].
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_destroy(renderer: *mut MmdCInstance) {
    if !renderer.is_null() {
        drop(Box::from_raw(renderer));
    }
}

/// Load a `.pmx`, returning its handle and output texture id.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_load(
    renderer: *mut MmdCInstance,
    asset_path: *const c_char,
    out_id: *mut u64,
    out_texture_id: *mut u32,
) -> i32 {
    if renderer.is_null() || asset_path.is_null() || out_id.is_null() {
        return MMD_ERR;
    }
    let path = CStr::from_ptr(asset_path).to_string_lossy();
    match (*renderer).renderer.load(&path) {
        Ok(handle) => {
            *out_id = handle.id;
            if !out_texture_id.is_null() {
                *out_texture_id = handle.texture_id;
            }
            MMD_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Number of texture pages the platform must upload for a model.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_page_count(
    renderer: *mut MmdCInstance,
    id: u64,
    out_count: *mut usize,
) -> i32 {
    if renderer.is_null() || out_count.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.pages(handle) {
        Ok(pages) => {
            *out_count = pages.len();
            MMD_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Copy one page's pixels into the caller's buffer.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_page(
    renderer: *mut MmdCInstance,
    id: u64,
    index: usize,
    out_width: *mut u32,
    out_height: *mut u32,
    out_pixels: *mut u8,
    pixel_cap: usize,
) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    let pages = match (*renderer).renderer.pages(handle) {
        Ok(pages) => pages,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return MMD_ERR;
        }
    };
    let Some(page) = pages.get(index) else {
        return MMD_ERR;
    };
    if page.pixels.len() > pixel_cap && pixel_cap != 0 {
        // A zero cap is the caller's size query (it wants width/height); only a
        // real, too-small buffer is an error.
        return MMD_ERR;
    }
    if !out_width.is_null() {
        *out_width = page.width;
    }
    if !out_height.is_null() {
        *out_height = page.height;
    }
    if !out_pixels.is_null() {
        std::ptr::copy_nonoverlapping(page.pixels.as_ptr(), out_pixels, page.pixels.len());
    }
    MMD_OK
}

/// Write the resolved frame into the frozen vertex/index/draw buffers.
#[no_mangle]
#[allow(clippy::too_many_arguments)]
pub unsafe extern "C" fn anima_mmd_render(
    renderer: *mut MmdCInstance,
    id: u64,
    delta_seconds: f32,
    out_vertices: *mut Vertex,
    vertex_cap: usize,
    out_indices: *mut u32,
    index_cap: usize,
    out_draws: *mut DrawCommand,
    draw_cap: usize,
) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    let frame = match (*renderer).renderer.render(handle, delta_seconds) {
        Ok(frame) => frame,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return MMD_ERR;
        }
    };
    let geometry = &frame.geometry;
    if geometry.vertices.len() > vertex_cap
        || geometry.indices.len() > index_cap
        || geometry.draws.len() > draw_cap
    {
        return MMD_ERR;
    }
    if !out_vertices.is_null() {
        std::ptr::copy_nonoverlapping(
            geometry.vertices.as_ptr(),
            out_vertices,
            geometry.vertices.len(),
        );
    }
    if !out_indices.is_null() {
        std::ptr::copy_nonoverlapping(
            geometry.indices.as_ptr(),
            out_indices,
            geometry.indices.len(),
        );
    }
    if !out_draws.is_null() {
        std::ptr::copy_nonoverlapping(geometry.draws.as_ptr(), out_draws, geometry.draws.len());
    }
    MMD_OK
}

/// Resolved counts for the next frame.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_frame_counts(
    renderer: *mut MmdCInstance,
    id: u64,
    out_vertices: *mut usize,
    out_indices: *mut usize,
    out_draws: *mut usize,
) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    let geometry = match (*renderer).renderer.frame_geometry(handle) {
        Ok(geometry) => geometry,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return MMD_ERR;
        }
    };
    if !out_vertices.is_null() {
        *out_vertices = geometry.vertices.len();
    }
    if !out_indices.is_null() {
        *out_indices = geometry.indices.len();
    }
    if !out_draws.is_null() {
        *out_draws = geometry.draws.len();
    }
    MMD_OK
}

/// Continuous mouth-open weight (the `あ` channel).
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_set_lip_sync(
    renderer: *mut MmdCInstance,
    id: u64,
    weight: f32,
) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.set_lip_sync(handle, weight) {
        Ok(()) => MMD_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Additive emotion cue by semantic tag.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_set_emotion(
    renderer: *mut MmdCInstance,
    id: u64,
    tag: *const c_char,
    intensity: f32,
) -> i32 {
    if renderer.is_null() || tag.is_null() {
        return MMD_ERR;
    }
    let tag = CStr::from_ptr(tag).to_string_lossy();
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer)
        .renderer
        .set_emotion(handle, &tag, "motion", intensity)
    {
        Ok(()) => MMD_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Continuous idle/ambient phase.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_set_ambient_phase(
    renderer: *mut MmdCInstance,
    id: u64,
    phase: f32,
) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.set_ambient_phase(handle, phase) {
        Ok(()) => MMD_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Release a model and its platform textures. Idempotent.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_dispose(renderer: *mut MmdCInstance, id: u64) -> i32 {
    if renderer.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.dispose(handle) {
        Ok(()) => MMD_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Read back the mouth-open weight the model last applied.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_get_lip_sync(
    renderer: *mut MmdCInstance,
    id: u64,
    out_weight: *mut f32,
) -> i32 {
    if renderer.is_null() || out_weight.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.lip_sync(handle) {
        Ok(weight) => {
            *out_weight = weight;
            MMD_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Read back the current emotion cue (tag, kind, intensity).
///
/// `out_kind` is always `"motion"`: the frozen ABI carries the cue kind, while
/// the renderer keys the additive channel by semantic tag.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_get_emotion(
    renderer: *mut MmdCInstance,
    id: u64,
    out_tag: *mut *const c_char,
    out_intensity: *mut f32,
) -> i32 {
    if renderer.is_null() || out_tag.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.emotion(handle) {
        Ok((tag, _kind, intensity)) => {
            let tag = CString::new(tag).unwrap_or_default();
            (*renderer).emotion_tag = tag;
            *out_tag = (*renderer).emotion_tag.as_ptr();
            if !out_intensity.is_null() {
                *out_intensity = intensity;
            }
            MMD_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Read back the current ambient phase.
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_get_ambient_phase(
    renderer: *mut MmdCInstance,
    id: u64,
    out_phase: *mut f32,
) -> i32 {
    if renderer.is_null() || out_phase.is_null() {
        return MMD_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.ambient_phase(handle) {
        Ok(phase) => {
            *out_phase = phase;
            MMD_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            MMD_ERR
        }
    }
}

/// Last error message (NUL-terminated, owned by the instance).
#[no_mangle]
pub unsafe extern "C" fn anima_mmd_last_error(renderer: *mut MmdCInstance) -> *const c_char {
    if renderer.is_null() {
        return b"mmd: null instance".as_ptr() as *const c_char;
    }
    let error = &mut (*renderer).error;
    if error.is_empty() {
        error.push(b'0');
    }
    error.as_ptr() as *const c_char
}

/// Record `message` as the instance's last error.
unsafe fn store_error(renderer: *mut MmdCInstance, message: &str) {
    if renderer.is_null() {
        return;
    }
    let error = &mut (*renderer).error;
    error.clear();
    error.extend_from_slice(message.as_bytes());
    error.push(b'\0');
}

/// The path a `.pmx` resolves its textures against (kept for the C++ shell's
/// diagnostics; the parser already resolves relative to the model).
#[must_use]
pub fn model_dir(asset_path: &str) -> &Path {
    Path::new(asset_path)
        .parent()
        .unwrap_or_else(|| Path::new("."))
}