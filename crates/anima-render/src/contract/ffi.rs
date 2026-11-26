// SPDX-License-Identifier: GPL-3.0-or-later
//! Safe Rust wrapper over the frozen render/texture C ABI (`cpp/render_contract.*`).
//!
//! This is the in-process entry point the Flutter plugin binds against. It
//! owns the backend handle, mints no texture ids itself (the platform's
//! closures do), and copies frame data out each tick. The higher-level
//! [`RendererBackend`] trait is implemented on top of this by per-OS modules.

#![allow(missing_docs)]
use std::ffi::{c_char, c_void, CStr, CString};
use std::os::raw::c_int;
use std::ptr::NonNull;

use super::frame::{DrawCommand, FrameGeometry, RenderFrame, TextureFormat, TexturePayload, Vertex};

/// Opaque backend handle (one per model kind).
#[repr(C)]
pub struct airi_render_backend {
    _private: [u8; 0],
}

/// Opaque model handle: native id plus the platform texture id Dart holds.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct airi_render_handle {
    pub id: u64,
    pub texture_id: u32,
}

/// One uploaded texture page as the C ABI reports it (pixels may be null at
/// the contract level; the Spine phase fills real pixels).
#[derive(Clone)]
#[repr(C)]
pub struct airi_render_page {
    pub name: *const c_char,
    pub width: u32,
    pub height: u32,
    pub format: i32,
    pub premultiplied_alpha: i32,
    pub pixels: *const u8,
    pub pixels_len: usize,
}

/// One textured vertex in the C ABI layout.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct airi_render_vertex {
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub u: f32,
    pub v: f32,
}

/// One draw range in the C ABI layout.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct airi_render_draw {
    pub page: u32,
    pub blend: i32,
    pub alpha: f32,
    pub vertex_offset: u32,
    pub vertex_count: u32,
    pub index_offset: u32,
    pub index_count: u32,
}

pub type RegisterTexture = unsafe extern "C" fn(*mut c_void, u32, u32) -> u32;
pub type ReleaseTexture = unsafe extern "C" fn(*mut c_void, u32);

extern "C" {
    fn airi_render_create(
        kind: i32,
        register_texture: RegisterTexture,
        release_texture: ReleaseTexture,
        ctx: *mut c_void,
    ) -> *mut airi_render_backend;
    fn airi_render_destroy(backend: *mut airi_render_backend);
    fn airi_render_load(
        backend: *mut airi_render_backend,
        asset_path: *const c_char,
        out_handle: *mut airi_render_handle,
    ) -> i32;
    fn airi_render_last_error(backend: *mut airi_render_backend) -> *const c_char;
    fn airi_render_pages(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        out_pages: *mut airi_render_page,
        page_cap: usize,
        out_count: *mut usize,
    ) -> i32;
    fn airi_render_frame_counts(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        out_vertices: *mut usize,
        out_indices: *mut usize,
        out_draws: *mut usize,
    );
    fn airi_render_render(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        delta_seconds: f32,
        out_vertices: *mut airi_render_vertex,
        vertex_cap: usize,
        out_indices: *mut u32,
        index_cap: usize,
        out_draws: *mut airi_render_draw,
        draw_cap: usize,
    ) -> i32;
    fn airi_render_set_lip_sync(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        weight: f32,
    ) -> i32;
    fn airi_render_set_emotion(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        tag: *const c_char,
        kind: *const c_char,
        intensity: f32,
    ) -> i32;
    fn airi_render_set_ambient_phase(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        phase: f32,
    ) -> i32;
    fn airi_render_dispose(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
    ) -> i32;
    fn airi_render_get_lip_sync(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        out_weight: *mut f32,
    ) -> i32;
    fn airi_render_get_emotion(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        out_tag: *mut *const c_char,
        out_kind: *mut *const c_char,
        out_intensity: *mut f32,
    ) -> i32;
    fn airi_render_get_ambient_phase(
        backend: *mut airi_render_backend,
        handle: airi_render_handle,
        out_phase: *mut f32,
    ) -> i32;
}

fn cstring(value: &str) -> CString {
    CString::new(value.replace('\0', "")).unwrap_or_default()
}

fn cstr_to_string(ptr: *const c_char) -> String {
    if ptr.is_null() {
        return String::new();
    }
    unsafe { CStr::from_ptr(ptr) }.to_string_lossy().into_owned()
}

/// The platform texture registry the backend calls back into. The `ctx` is an
/// opaque pointer the platform owns; the callbacks mint/release texture ids.
pub struct TextureRegistry {
    register: RegisterTexture,
    release: ReleaseTexture,
    ctx: *mut c_void,
}

impl TextureRegistry {
    /// Build a registry from the platform's texture callbacks and opaque ctx.
    pub fn new(register: RegisterTexture, release: ReleaseTexture, ctx: *mut c_void) -> Self {
        TextureRegistry { register, release, ctx }
    }
}

// The callbacks are the platform's and are only invoked on the render thread
// that owns the backend; the registry is therefore Send (the ctx is the
// platform's to keep alive).
unsafe impl Send for TextureRegistry {}

/// Rolls back platform textures minted during a load that later fails. The
/// drivers move the ids into their model table only on success, so a `?`
/// between registration and that hand-off would otherwise leak them.
pub(crate) struct TextureRollback {
    ids: Vec<u32>,
    release: ReleaseTexture,
    ctx: *mut c_void,
}

impl TextureRollback {
    pub(crate) fn new(registry: &TextureRegistry) -> Self {
        Self { ids: Vec::new(), release: registry.release, ctx: registry.ctx }
    }

    pub(crate) fn track(&mut self, id: u32) {
        self.ids.push(id);
    }

    /// Hand the ids to the successfully installed model; no rollback now.
    pub(crate) fn commit(mut self) -> Vec<u32> {
        std::mem::take(&mut self.ids)
    }
}

impl Drop for TextureRollback {
    fn drop(&mut self) {
        for id in &self.ids {
            unsafe { (self.release)(self.ctx, *id) };
        }
    }
}

/// A live render backend bound to a platform texture registry.
pub struct RenderBackend {
    handle: NonNull<airi_render_backend>,
    _registry: TextureRegistry,
}

// The backend is confined to one render thread; moving it is fine as long as
// it is not used concurrently, which `&mut self` enforces.
unsafe impl Send for RenderBackend {}

impl RenderBackend {
    /// Create a backend for `kind` (`AIRI_RENDER_KIND_*`) with the platform's
    /// texture registry callbacks.
    pub fn create(kind: i32, registry: TextureRegistry) -> Self {
        let handle = unsafe {
            airi_render_create(
                kind,
                registry.register,
                registry.release,
                registry.ctx,
            )
        };
        RenderBackend {
            handle: NonNull::new(handle).expect("airi_render_create returned null"),
            _registry: registry,
        }
    }

    /// The platform callback registry, for rollback guards during load.
    pub(crate) fn registry(&self) -> &TextureRegistry {
        &self._registry
    }

    /// Mint a texture id for a `(width, height)` page through the platform's
    /// `register_texture` callback. The backend never invents an id.
    pub fn register_texture(&mut self, width: u32, height: u32) -> anyhow::Result<u32> {
        let id = unsafe { (self._registry.register)(self._registry.ctx, width, height) };
        if id == u32::MAX {
            anyhow::bail!("platform register_texture refused a {width}x{height} page");
        }
        Ok(id)
    }

    /// Release a texture id through the platform's `release_texture` callback.
    pub fn release_texture(&mut self, texture_id: u32) -> anyhow::Result<()> {
        unsafe { (self._registry.release)(self._registry.ctx, texture_id) };
        Ok(())
    }

    fn last_error(&self) -> String {
        cstr_to_string(unsafe { airi_render_last_error(self.handle.as_ptr()) })
    }

    /// Load the self-contained spine bundle at `asset_path`.
    pub fn load(&mut self, asset_path: &str) -> anyhow::Result<airi_render_handle> {
        let cpath = cstring(asset_path);
        let mut out = airi_render_handle { id: 0, texture_id: 0 };
        let rc = unsafe { airi_render_load(self.handle.as_ptr(), cpath.as_ptr(), &mut out) };
        if rc != 0 {
            anyhow::bail!("airi_render_load failed: {}", self.last_error());
        }
        Ok(out)
    }

    /// Texture pages for a loaded model (name/format/pma; pixels may be null).
    pub fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<TexturePayload>> {
        let mut count = 0usize;
        unsafe { airi_render_pages(self.handle.as_ptr(), handle, std::ptr::null_mut(), 0, &mut count) };
        let mut raw: Vec<airi_render_page> = vec![
            airi_render_page {
                name: std::ptr::null(),
                width: 0,
                height: 0,
                format: 0,
                premultiplied_alpha: 0,
                pixels: std::ptr::null(),
                pixels_len: 0,
            };
            count
        ];
        let rc = unsafe {
            airi_render_pages(
                self.handle.as_ptr(),
                handle,
                raw.as_mut_ptr(),
                count,
                &mut count,
            )
        };
        if rc != 0 {
            anyhow::bail!("airi_render_pages failed: {}", self.last_error());
        }
        let mut pages = Vec::with_capacity(count);
        for page in raw {
            let pixels = if page.pixels.is_null() || page.pixels_len == 0 {
                Vec::new()
            } else {
                unsafe { std::slice::from_raw_parts(page.pixels, page.pixels_len) }.to_vec()
            };
            pages.push(TexturePayload {
                name: cstr_to_string(page.name),
                width: page.width,
                height: page.height,
                format: match page.format {
                    0 => TextureFormat::Rgba8,
                    _ => TextureFormat::Rgba8,
                },
                premultiplied_alpha: page.premultiplied_alpha != 0,
                pixels,
            });
        }
        Ok(pages)
    }

    /// Advance and render one frame, returning the fully-resolved geometry.
    pub fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame> {
        let (mut nv, mut ni, mut nd) = (0usize, 0usize, 0usize);
        unsafe {
            airi_render_frame_counts(
                self.handle.as_ptr(),
                handle,
                &mut nv,
                &mut ni,
                &mut nd,
            );
        }
        let mut vertices = vec![airi_render_vertex::default(); nv];
        let mut indices = vec![0u32; ni];
        let mut draws = vec![airi_render_draw::default(); nd];
        let rc = unsafe {
            airi_render_render(
                self.handle.as_ptr(),
                handle,
                delta_seconds,
                vertices.as_mut_ptr(),
                nv,
                indices.as_mut_ptr(),
                ni,
                draws.as_mut_ptr(),
                nd,
            )
        };
        if rc != 0 {
            anyhow::bail!("airi_render_render failed: {}", self.last_error());
        }
        Ok(RenderFrame {
            pages: Vec::new(),
            geometry: FrameGeometry {
                vertices: vertices
                    .into_iter()
                    .map(|v| Vertex {
                        x: v.x,
                        y: v.y,
                        z: v.z,
                        u: v.u,
                        v: v.v,
                    })
                    .collect(),
                indices,
                draws: draws
                    .into_iter()
                    .map(|d| DrawCommand {
                        page: d.page,
                        blend: super::frame::BlendMode::from_wire(d.blend),
                        alpha: d.alpha,
                        vertex_offset: d.vertex_offset,
                        vertex_count: d.vertex_count,
                        index_offset: d.index_offset,
                        index_count: d.index_count,
                    })
                    .collect(),
            },
        })
    }

    /// Set a continuous mouth-open weight in `[0, 1]`.
    pub fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()> {
        let rc = unsafe { airi_render_set_lip_sync(self.handle.as_ptr(), handle, weight) };
        self.check(rc, "airi_render_set_lip_sync")
    }

    /// Apply one expression/motion cue by semantic tag.
    pub fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()> {
        let ctag = cstring(tag);
        let ckind = cstring(kind);
        let rc = unsafe {
            airi_render_set_emotion(
                self.handle.as_ptr(),
                handle,
                ctag.as_ptr(),
                ckind.as_ptr(),
                intensity,
            )
        };
        self.check(rc, "airi_render_set_emotion")
    }

    /// Set a continuous idle/ambient motion phase in `[0, 1]`.
    pub fn set_ambient_phase(
        &mut self,
        handle: airi_render_handle,
        phase: f32,
    ) -> anyhow::Result<()> {
        let rc = unsafe { airi_render_set_ambient_phase(self.handle.as_ptr(), handle, phase) };
        self.check(rc, "airi_render_set_ambient_phase")
    }

    /// Release all native resources for `handle` (and its textures). Idempotent.
    pub fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        let rc = unsafe { airi_render_dispose(self.handle.as_ptr(), handle) };
        self.check(rc, "airi_render_dispose")
    }

    /// Read back the current mouth-open weight.
    pub fn get_lip_sync(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        let mut out = 0f32;
        let rc = unsafe { airi_render_get_lip_sync(self.handle.as_ptr(), handle, &mut out) };
        self.check(rc, "airi_render_get_lip_sync")?;
        Ok(out)
    }

    /// Read back the current emotion (tag, kind, intensity).
    pub fn get_emotion(&mut self, handle: airi_render_handle) -> anyhow::Result<(String, String, f32)> {
        let mut tag: *const c_char = std::ptr::null();
        let mut kind: *const c_char = std::ptr::null();
        let mut intensity = 0f32;
        let rc = unsafe {
            airi_render_get_emotion(
                self.handle.as_ptr(),
                handle,
                &mut tag,
                &mut kind,
                &mut intensity,
            )
        };
        self.check(rc, "airi_render_get_emotion")?;
        Ok((cstr_to_string(tag), cstr_to_string(kind), intensity))
    }

    /// Read back the current ambient phase.
    pub fn get_ambient_phase(&mut self, handle: airi_render_handle) -> anyhow::Result<f32> {
        let mut out = 0f32;
        let rc = unsafe { airi_render_get_ambient_phase(self.handle.as_ptr(), handle, &mut out) };
        self.check(rc, "airi_render_get_ambient_phase")?;
        Ok(out)
    }

    fn check(&self, rc: c_int, what: &str) -> anyhow::Result<()> {
        if rc != 0 {
            anyhow::bail!("{what} failed: {}", self.last_error());
        }
        Ok(())
    }
}

impl Drop for RenderBackend {
    fn drop(&mut self) {
        unsafe { airi_render_destroy(self.handle.as_ptr()) }
    }
}

use super::backend::{BackendKind, RendererBackend};

impl RendererBackend for RenderBackend {
    fn kind(&self) -> BackendKind {
        BackendKind::Spine
    }

    fn load(&mut self, path: &str) -> anyhow::Result<(airi_render_handle, RenderFrame)> {
        let handle = self.load(path)?;
        let frame = self.render(handle, 0.0)?;
        Ok((handle, frame))
    }

    fn render(&mut self, handle: airi_render_handle, delta_seconds: f32) -> anyhow::Result<RenderFrame> {
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

    fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<TexturePayload>> {
        self.pages(handle)
    }
}

/// The frozen kind wire indices, mirrored from `BackendKind`.
pub mod kind {
    pub const VRM: i32 = 0;
    pub const SPINE: i32 = 1;
    pub const MMD: i32 = 2;
    pub const LIVE2D: i32 = 3;
}

