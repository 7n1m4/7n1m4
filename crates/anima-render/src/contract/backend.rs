// SPDX-License-Identifier: GPL-3.0-or-later
//! The backend seam every per-OS GPU backend implements.
//!
//! This trait is the in-process, renderer-agnostic surface the Flutter plugin
//! and the rest of the crate program against. The concrete implementation is
//! [`crate::contract::ffi::RenderBackend`] (over the frozen C ABI); per-OS
//! modules (Metal/Vulkan/EGL) sit beneath it and only touch the GPU. The
//! lifecycle mirrors the frozen Dart seam exactly:
//! `load -> (setLipSync | setEmotion | setAmbientPhase | render)* -> dispose`.
//!
//! `load` returns the opaque [`airi_render_handle`] whose `texture_id` is the
//! GPU/PlatformView texture the platform minted; Dart only ever sees that
//! integer. The platform owns and releases the texture id; the backend frees
//! the GPU resources it allocated for the handle on the matching `dispose`.

use super::ffi::airi_render_handle;
use super::frame::RenderFrame;

/// Which model format a backend renders.
///
/// The numeric values are the frozen wire `ModelKind` indices used by the Dart
/// side (`vrm == 0`, `spine == 1`, `mmd == 2`, `live2d == 3`); do not reorder.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BackendKind {
    /// glTF/VRM 3D.
    Vrm = 0,
    /// Spine 2D.
    Spine = 1,
    /// MMD (PMX/VMD) 3D.
    Mmd = 2,
    /// Live2D 2D (behind the Cubism licensing gate).
    Live2d = 3,
}

impl BackendKind {
    /// Decode a wire `ModelKind` index; unknown values are an error so a bad
    /// card fails loudly instead of rendering the wrong format.
    pub fn from_wire(value: i32) -> Option<Self> {
        match value {
            0 => Some(BackendKind::Vrm),
            1 => Some(BackendKind::Spine),
            2 => Some(BackendKind::Mmd),
            3 => Some(BackendKind::Live2d),
            _ => None,
        }
    }

    /// The frozen wire index for this kind.
    pub fn to_wire(self) -> i32 {
        self as i32
    }

    /// The method-channel suffix (`vrm`, `spine`, `mmd`, `live2d`).
    pub fn channel_name(self) -> &'static str {
        match self {
            BackendKind::Vrm => "vrm",
            BackendKind::Spine => "spine",
            BackendKind::Mmd => "mmd",
            BackendKind::Live2d => "live2d",
        }
    }
}

/// A per-OS GPU backend that renders one model kind.
///
/// Implementations live beneath this contract (one module per OS/Graphics API)
/// and are the only code that touches `wgpu`/`Metal`/Vulkan/EGL. The rest of
/// the crate and the Flutter plugin program against this trait only.
pub trait RendererBackend: Send {
    /// The model kind this backend renders.
    fn kind(&self) -> BackendKind;

    /// Load the self-contained model bundle at `asset_path` and return its
    /// handle plus the first fully-resolved frame.
    ///
    /// Must fail loudly (Err) rather than return a handle to an unloaded
    /// model. On success the model's pages are uploaded and the first frame is
    /// rendered into the texture.
    fn load(&mut self, asset_path: &str) -> anyhow::Result<(airi_render_handle, RenderFrame)>;

    /// Texture pages for a loaded model, in page-index order.
    fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<super::frame::TexturePayload>>;

    /// Advance by `delta_seconds` and return the fully-resolved geometry.
    fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame>;

    /// Set a continuous mouth-open weight in `[0, 1]`.
    fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()>;

    /// Apply one expression/motion cue by semantic tag.
    fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()>;

    /// Set a continuous idle/ambient motion phase in `[0, 1]`.
    fn set_ambient_phase(
        &mut self,
        handle: airi_render_handle,
        phase: f32,
    ) -> anyhow::Result<()>;

    /// Release all native resources for `handle` (and its texture). Idempotent.
    fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()>;
}