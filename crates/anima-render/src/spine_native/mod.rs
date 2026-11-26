// SPDX-License-Identifier: GPL-3.0-or-later
//! The first real Spine 4.2 renderer behind the frozen render contract.
//!
//! This module is the per-format driver the platform binds to the
//! [`RendererBackend`] trait. It composes the existing session / draw
//! collection logic ([`crate::spine::SpineSession`]) with the frozen C ABI
//! ([`crate::contract::ffi::RenderBackend`]) and the animation-name
//! conventions ([`crate::spine::animation`]); it does not reimplement
//! skeleton parsing, posing or draw collection.
//!
//! Texture registration is the platform's: the backend is created with the
//! platform's [`TextureRegistry`] and never mints a texture id itself. A
//! missing runtime fails loudly at load — [`SpineNativeRenderer::load`]
//! returns a typed [`SpineNativeError::MissingRuntime`] rather than an empty
//! frame.
//!
//! The four sinks the frozen contract exposes — lip sync, emotion, ambient
//! phase and the frame render — are all observable: the first three are read
//! back through the C ABI getters, and the frame is the resolved geometry.

use crate::contract::backend::{BackendKind, RendererBackend};
use crate::contract::ffi::{airi_render_handle, RenderBackend, TextureRegistry};
use crate::contract::frame::RenderFrame;
use crate::spine::animation::{resolve_animation, EMOTION_TRACK, IDLE_TRACK};

/// Typed diagnostics for the Spine renderer.
///
/// Every variant is a loud failure: the renderer never returns an empty frame
/// or a fabricated texture id to paper over a missing runtime or a bad bundle.
#[derive(Debug)]
pub enum SpineNativeError {
    /// The vendored spine-cpp runtime for the selected line is not compiled
    /// in (the crate was built without the `spine` feature / C toolchain).
    MissingRuntime(&'static str),

    /// The bundle could not be loaded through the frozen contract.
    Load(anyhow::Error),
}

impl std::fmt::Display for SpineNativeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SpineNativeError::MissingRuntime(msg) => {
                write!(f, "spine runtime is not available: {msg}")
            }
            SpineNativeError::Load(err) => write!(f, "spine load failed: {err}"),
        }
    }
}

impl std::error::Error for SpineNativeError {}

impl From<anyhow::Error> for SpineNativeError {
    fn from(err: anyhow::Error) -> Self {
        SpineNativeError::Load(err)
    }
}

/// The Spine 4.2 renderer: a thin, format-specific driver over the frozen
/// [`RenderBackend`] and the vendored spine-cpp session.
///
/// It is `Send` (the backend is confined to one render thread) and not
/// `Sync`; the platform drives it from a single thread.
pub struct SpineNativeRenderer {
    pub(crate) backend: RenderBackend,
}

// The backend is Send; the renderer owns it and adds no shared state.
unsafe impl Send for SpineNativeRenderer {}

impl SpineNativeRenderer {
    /// Create a renderer bound to the platform's texture registry.
    ///
    /// `registry` carries the platform's `register_texture` / `release_texture`
    /// closures and opaque ctx; the renderer never fabricates a texture id.
    pub fn create(registry: TextureRegistry) -> Self {
        SpineNativeRenderer {
            backend: RenderBackend::create(crate::contract::kind::SPINE, registry),
        }
    }

    /// Wrap an already-built backend. The platform uses this to inject a
    /// backend of a specific kind (e.g. for diagnostics); the spine renderer
    /// still only ever drives the spine contract.
    pub fn create_with_backend(backend: RenderBackend) -> Self {
        SpineNativeRenderer { backend }
    }

    /// The model kind this renderer serves.
    pub fn kind(&self) -> BackendKind {
        BackendKind::Spine
    }

    /// Load a self-contained spine bundle and return its handle plus the first
    /// resolved frame.
    ///
    /// Fails loudly with [`SpineNativeError::MissingRuntime`] when the spine
    /// runtime is not compiled in, and with [`SpineNativeError::Load`] when the
    /// bundle is missing or malformed — never an empty render.
    pub fn load(&mut self, asset_path: &str) -> Result<(airi_render_handle, RenderFrame), SpineNativeError> {
        let handle = self.backend.load(asset_path).map_err(|err| {
            let message = err.to_string();
            if message.contains("no native backend") {
                SpineNativeError::MissingRuntime(
                    "the vendored spine-cpp line was not compiled into this crate",
                )
            } else {
                SpineNativeError::Load(err)
            }
        })?;
        let frame = self.backend.render(handle, 0.0).map_err(SpineNativeError::Load)?;
        Ok((handle, frame))
    }

    /// Texture pages for a loaded model, in page-index order.
    pub fn pages(
        &mut self,
        handle: airi_render_handle,
    ) -> anyhow::Result<Vec<crate::contract::frame::TexturePayload>> {
        self.backend.pages(handle)
    }

    /// Advance by `delta_seconds` and return the fully-resolved geometry.
    pub fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame> {
        self.backend.render(handle, delta_seconds)
    }

    /// Set the continuous mouth-open weight in `[0, 1]`.
    pub fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()> {
        self.backend.set_lip_sync(handle, weight)
    }

    /// Apply one expression/motion cue by semantic tag.
    pub fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()> {
        self.backend.set_emotion(handle, tag, kind, intensity)
    }

    /// Set a continuous idle/ambient motion phase in `[0, 1]`.
    pub fn set_ambient_phase(&mut self, handle: airi_render_handle, phase: f32) -> anyhow::Result<()> {
        self.backend.set_ambient_phase(handle, phase)
    }

    /// Read back the current mouth-open weight (observable lip-sync sink).
    pub fn lip_sync(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        self.backend.get_lip_sync(handle)
    }

    /// Read back the current emotion cue (observable emotion sink).
    pub fn emotion(&mut self, handle: airi_render_handle) -> anyhow::Result<(String, String, f32)> {
        self.backend.get_emotion(handle)
    }

    /// Read back the current ambient phase (observable ambient sink).
    pub fn ambient_phase(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        self.backend.get_ambient_phase(handle)
    }

    /// Release all native resources for `handle` (and its textures). Idempotent.
    pub fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        self.backend.dispose(handle)
    }
}

impl RendererBackend for SpineNativeRenderer {
    fn kind(&self) -> BackendKind {
        BackendKind::Spine
    }

    fn load(&mut self, asset_path: &str) -> anyhow::Result<(airi_render_handle, RenderFrame)> {
        let (handle, frame) = self.load(asset_path)?;
        Ok((handle, frame))
    }

    fn pages(
        &mut self,
        handle: airi_render_handle,
    ) -> anyhow::Result<Vec<crate::contract::frame::TexturePayload>> {
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

/// Resolve the idle animation name for a skeleton, mirroring the Vue
/// `setIdle` fallback chain. Exposed so the platform can pick the ambient
/// loop without re-deriving the convention.
pub fn idle_animation(available: &[String]) -> Option<String> {
    crate::spine::animation::resolve_idle(available, "idle")
}

/// Resolve an emotion animation name against the available set, mirroring the
/// Vue emotion-track resolution. Exposed for the platform's ACT mapping.
pub fn emotion_animation(available: &[String], tag: &str) -> Option<String> {
    resolve_animation(available, tag)
}

/// The track the renderer layers one-shot emotion animations over.
pub const EMOTION_ANIMATION_TRACK: usize = EMOTION_TRACK;
/// The track the renderer keeps the persistent idle loop on.
pub const IDLE_ANIMATION_TRACK: usize = IDLE_TRACK;

