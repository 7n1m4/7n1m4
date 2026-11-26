// SPDX-License-Identifier: GPL-3.0-or-later
//! The first real VRM 0.x / 1.0 renderer behind the frozen render contract.
//!
//! This module is the per-format driver the platform binds to. It drives the
//! CPU-side [`crate::vrm::engine::Engine`] (skinning, morph blending, spring
//! bones, blink, gaze, lip-sync and additive expressions), shades the resolved
//! triangles with the document's MToon parameters into an RGBA8 output page,
//! and serves the result in the frozen frame shape.
//!
//! Texture registration is the platform's: every texture id the renderer
//! reports comes from the platform's `register_texture` callback, and every id
//! is handed back to `release_texture` on dispose. The renderer never invents
//! an id. A missing or corrupt document fails loudly with a typed
//! [`VrmNativeError`] — never an empty frame and never a fabricated texture.
//!
//! Lip-sync is the document's `aa` (or `a`) morph and is an independent
//! additive channel: setting it never disturbs the blink loop, and switching
//! emotion never zeroes either (the engine's expression layer only fades the
//! presets the previous emotion owned).
//!
//! The rasteriser is the self-contained MToon shading pass in
//! [`crate::vrm_native::raster`]; it has no GPU dependency, so the same code
//! runs in tests and in the per-OS plugin, which uploads the returned page as
//! the model's output texture.

pub mod raster;

use std::collections::HashMap;
use std::ffi::{c_char, c_void, CStr, CString};

use crate::contract::backend::{BackendKind, RendererBackend};
use crate::contract::ffi::{airi_render_handle, RenderBackend, TextureRegistry, TextureRollback};
use crate::contract::frame::{
    BlendMode, DrawCommand, FrameGeometry, RenderFrame, TextureFormat, TexturePayload, Vertex,
};
use crate::vrm::engine::Engine;
use crate::vrm::materials::MtoonParams;
use crate::vrm_native::raster::{Camera, Image, RasterTarget};

/// One MToon material, exported for the platform's shader.
#[derive(Debug, Clone, PartialEq)]
pub struct VrmMaterial {
    /// Base colour `[r, g, b, a]`.
    pub base_color: [f32; 4],
    /// Shade colour `[r, g, b, a]`.
    pub shade_color: [f32; 4],
    /// Toon ramp levels (0–1 entries).
    pub toon_shades: Vec<f32>,
    /// Emissive factor `[r, g, b]`.
    pub emissive: [f32; 3],
    /// Rim lighting mix.
    pub rim_mix: f32,
    /// Alpha cutoff (0 = opaque).
    pub alpha_cutoff: f32,
}

impl From<&MtoonParams> for VrmMaterial {
    fn from(p: &MtoonParams) -> Self {
        VrmMaterial {
            base_color: p.base_color,
            shade_color: p.shade_color,
            toon_shades: p.toon_shades.clone(),
            emissive: p.emissive,
            rim_mix: p.rim_mix,
            alpha_cutoff: p.alpha_cutoff,
        }
    }
}

/// Typed diagnostics for the VRM renderer.
///
/// Every variant is a loud failure: the renderer never returns an empty frame
/// or a fabricated texture id to paper over a missing runtime or a bad
/// document.
#[derive(Debug)]
pub enum VrmNativeError {
    /// The file could not be read or parsed as glTF/VRM.
    Load(anyhow::Error),
    /// The document is not a VRM this driver can drive (no geometry, no MToon
    /// material data, or an undecodable base colour).
    UnsupportedDocument(String),
}

impl std::fmt::Display for VrmNativeError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            VrmNativeError::Load(err) => write!(f, "vrm load failed: {err}"),
            VrmNativeError::UnsupportedDocument(message) => {
                write!(f, "unsupported vrm document: {message}")
            }
        }
    }
}

impl std::error::Error for VrmNativeError {}

impl From<anyhow::Error> for VrmNativeError {
    fn from(err: anyhow::Error) -> Self {
        VrmNativeError::Load(err)
    }
}

/// Edge length of the shaded output surface the platform presents.
pub const OUTPUT_SIZE: u32 = 512;

/// One live VRM model.
struct Model {
    engine: Engine,
    /// Decoded base-colour pages, one per distinct source image.
    pages: Vec<Image>,
    /// Material index → page index (materials share source images).
    page_by_material: HashMap<u32, u32>,
    /// One platform texture id per decoded page (`pages.len()` entries), then
    /// the shaded output surface's id.
    texture_ids: Vec<u32>,
    /// Shaded RGBA8 output page (rebuilt every frame).
    output: Image,
    camera: Camera,
    /// Last applied sinks, read back by the getters.
    lip_sync_sink: f32,
    emotion: (String, String, f32),
    ambient_phase: f32,
}

/// The VRM renderer: the frozen backend plus the models it drives.
///
/// It is `Send` (the backend is confined to one render thread) and not
/// `Sync`; the platform drives it from a single thread.
pub struct VrmNativeRenderer {
    backend: RenderBackend,
    models: Vec<Option<Model>>,
}

// The backend is Send; the renderer owns it and adds no shared state.
unsafe impl Send for VrmNativeRenderer {}

impl Drop for VrmNativeRenderer {
    fn drop(&mut self) {
        // Explicit dispose() takes the model out of its slot, so only
        // still-live models remain here. Backend destruction is the last
        // chance to hand their texture ids back to the platform.
        for model in self.models.iter_mut().flatten() {
            for id in model.texture_ids.drain(..) {
                let _ = self.backend.release_texture(id);
            }
        }
    }
}

impl VrmNativeRenderer {
    /// Create a renderer bound to the platform's texture registry.
    ///
    /// `registry` carries the platform's `register_texture` /
    /// `release_texture` closures and opaque ctx; the renderer never
    /// fabricates a texture id.
    pub fn create(registry: TextureRegistry) -> Self {
        VrmNativeRenderer {
            backend: RenderBackend::create(crate::contract::kind::VRM, registry),
            models: Vec::new(),
        }
    }

    /// The model kind this renderer serves.
    pub fn kind(&self) -> BackendKind {
        BackendKind::Vrm
    }

    /// Resolve a handle to its slot.
    ///
    /// Ids are 1-based indices into `models`, so the slot is `id - 1`. The C++
    /// side allocates ids from the same counter for every kind, so a handle is
    /// only valid while its slot is occupied.
    fn slot(&self, handle: airi_render_handle) -> anyhow::Result<usize> {
        (handle.id as usize)
            .checked_sub(1)
            .filter(|index| *index < self.models.len())
            .ok_or_else(|| anyhow::anyhow!("vrm: unknown handle {}", handle.id))
    }

    fn model(&self, handle: airi_render_handle) -> anyhow::Result<&Model> {
        let index = self.slot(handle)?;
        self.models[index]
            .as_ref()
            .ok_or_else(|| anyhow::anyhow!("vrm: handle {} is disposed", handle.id))
    }

    fn model_mut(&mut self, handle: airi_render_handle) -> anyhow::Result<&mut Model> {
        let index = self.slot(handle)?;
        self.models[index]
            .as_mut()
            .ok_or_else(|| anyhow::anyhow!("vrm: handle {} is disposed", handle.id))
    }

    /// Load a `.vrm` and return its handle plus the first resolved frame.
    ///
    /// Fails loudly with [`VrmNativeError::UnsupportedDocument`] when the
    /// document has no renderable geometry or no MToon material data, and with
    /// [`VrmNativeError::Load`] when the file is missing or malformed — never
    /// an empty render and never a fabricated texture.
    pub fn load(
        &mut self,
        asset_path: &str,
    ) -> Result<(airi_render_handle, RenderFrame), VrmNativeError> {
        let engine = Engine::load(asset_path)?;
        if engine.primitive_count() == 0 {
            return Err(VrmNativeError::UnsupportedDocument(format!(
                "{asset_path} has no renderable primitives"
            )));
        }
        if engine.material_params().is_empty() {
            return Err(VrmNativeError::UnsupportedDocument(format!(
                "{asset_path} has no MToon material data"
            )));
        }

        // Decode each material's base colour once and let the platform mint a
        // texture id for it. Materials that share a source image share a page.
        let mut rollback = TextureRollback::new(self.backend.registry());
        let mut pages: Vec<Image> = Vec::new();
        let mut page_by_material: HashMap<u32, u32> = HashMap::new();
        let mut page_by_source: HashMap<String, u32> = HashMap::new();
        for material in 0..engine.material_count() {
            let Some(texture) = engine.material_texture(material as u32) else {
                continue;
            };
            // Materials that reference the same encoded image share a page.
            let source = format!(
                "{}:{}:{}",
                texture.mime,
                texture.bytes.len(),
                texture.extension
            );
            let page = match page_by_source.get(&source) {
                Some(page) => *page,
                None => {
                    let image = decode_texture(texture).ok_or_else(|| {
                        VrmNativeError::UnsupportedDocument(format!(
                            "{asset_path} material {material} base colour is not decodable"
                        ))
                    })?;
                    let texture_id = self.backend.register_texture(image.width, image.height)?;
                    rollback.track(texture_id);
                    page_by_source.insert(source, pages.len() as u32);
                    pages.push(image);
                    (pages.len() - 1) as u32
                }
            };
            page_by_material.insert(material as u32, page);
        }
        if pages.is_empty() {
            return Err(VrmNativeError::UnsupportedDocument(format!(
                "{asset_path} has no decoded base-colour texture"
            )));
        }

        // The output surface is the model's own texture, minted by the
        // platform, never an id this driver invents.
        let output_texture_id = self.backend.register_texture(OUTPUT_SIZE, OUTPUT_SIZE)?;
        rollback.track(output_texture_id);
        let mut model = Model {
            engine,
            pages,
            page_by_material,
            texture_ids: rollback.commit(),
            output: Image::new(OUTPUT_SIZE, OUTPUT_SIZE),
            camera: Camera::default(),
            lip_sync_sink: 0.0,
            emotion: (String::new(), String::new(), 0.0),
            ambient_phase: 0.0,
        };
        model.tick(0.0);
        let frame = model.frame();
        let handle = airi_render_handle {
            id: self.models.len() as u64 + 1,
            texture_id: output_texture_id,
        };
        self.models.push(Some(model));
        Ok((handle, frame))
    }

    /// Texture pages for a loaded model: the decoded base colours, then the
    /// shaded output surface the platform presents.
    pub fn pages(&mut self, handle: airi_render_handle) -> anyhow::Result<Vec<TexturePayload>> {
        let model = self.model(handle)?;
        let mut pages = Vec::with_capacity(model.pages.len() + 1);
        for (index, image) in model.pages.iter().enumerate() {
            pages.push(TexturePayload {
                name: format!("vrm-page-{index}"),
                width: image.width,
                height: image.height,
                format: TextureFormat::Rgba8,
                premultiplied_alpha: false,
                pixels: image.pixels.clone(),
            });
        }
        pages.push(TexturePayload {
            name: "vrm-output".to_string(),
            width: model.output.width,
            height: model.output.height,
            format: TextureFormat::Rgba8,
            premultiplied_alpha: false,
            pixels: model.output.pixels.clone(),
        });
        Ok(pages)
    }

    /// Advance by `delta_seconds` and return the resolved frame (with the
    /// freshly shaded output page).
    pub fn render(
        &mut self,
        handle: airi_render_handle,
        delta_seconds: f32,
    ) -> anyhow::Result<RenderFrame> {
        let model = self.model_mut(handle)?;
        model.tick(delta_seconds);
        Ok(model.frame())
    }

    /// Geometry for the next frame without advancing time or re-shading.
    ///
    /// The frozen ABI's frame-count call uses this so sizing a frame does not
    /// silently render it a second time.
    pub fn frame_geometry(&self, handle: airi_render_handle) -> anyhow::Result<FrameGeometry> {
        Ok(self.model(handle)?.frame().geometry)
    }

    /// Set the continuous mouth-open weight in `[0, 1]` (the `aa` channel).
    pub fn set_lip_sync(&mut self, handle: airi_render_handle, weight: f32) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        model.lip_sync_sink = weight.clamp(0.0, 1.0);
        model.engine.set_lip_sync(model.lip_sync_sink);
        Ok(())
    }

    /// Apply one expression/motion cue by semantic tag.
    ///
    /// The cue is additive: the engine fades only the presets the previous
    /// emotion owned, so blink and lip-sync keep running.
    pub fn set_emotion(
        &mut self,
        handle: airi_render_handle,
        tag: &str,
        kind: &str,
        intensity: f32,
    ) -> anyhow::Result<()> {
        let model = self.model_mut(handle)?;
        model.engine.set_expression_weight(tag, intensity);
        model.emotion = (tag.to_string(), kind.to_string(), intensity.clamp(0.0, 1.0));
        Ok(())
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

    /// The document's mouth preset (`aa`, else `a`), if it has one.
    pub fn lip_preset(&self, handle: airi_render_handle) -> Option<String> {
        self.model(handle).ok()?.engine.view_lip_preset()
    }

    /// The document's blink presets.
    pub fn blink_presets(&self, handle: airi_render_handle) -> Vec<String> {
        self.model(handle)
            .map(|m| m.engine.view_blink_presets())
            .unwrap_or_default()
    }

    /// The current weight of one preset, as the engine applied it this tick.
    pub fn preset_weight(&self, handle: airi_render_handle, preset: &str) -> f32 {
        self.model(handle)
            .map(|m| m.engine.view_preset_weight(preset))
            .unwrap_or(0.0)
    }

    /// Normalized emotion names the document defines.
    pub fn available_expressions(&self, handle: airi_render_handle) -> Vec<String> {
        self.model(handle)
            .map(|m| m.engine.available_expressions())
            .unwrap_or_default()
    }

    /// MToon parameters, index-aligned with the document's materials.
    pub fn materials(&self, handle: airi_render_handle) -> Vec<VrmMaterial> {
        self.model(handle)
            .map(|m| {
                m.engine
                    .view_materials()
                    .iter()
                    .map(VrmMaterial::from)
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Number of spring-bone chains the engine simulates.
    pub fn spring_bone_count(&self, handle: airi_render_handle) -> usize {
        self.model(handle)
            .map(|m| m.engine.view_spring_bone_count())
            .unwrap_or(0)
    }

    /// How many models are live (diagnostics).
    pub fn model_count(&self) -> usize {
        self.models.iter().filter(|m| m.is_some()).count()
    }

    /// Release all native resources for `handle` (and its textures). Idempotent.
    pub fn dispose(&mut self, handle: airi_render_handle) -> anyhow::Result<()> {
        let Some(index) = (handle.id as usize)
            .checked_sub(1)
            .filter(|i| *i < self.models.len())
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

impl RendererBackend for VrmNativeRenderer {
    fn kind(&self) -> BackendKind {
        BackendKind::Vrm
    }

    fn load(&mut self, asset_path: &str) -> anyhow::Result<(airi_render_handle, RenderFrame)> {
        let (handle, frame) = self.load(asset_path)?;
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

impl Model {
    /// Advance the engine, the spring bones and the MToon raster.
    fn tick(&mut self, delta_seconds: f32) {
        self.engine.tick(delta_seconds * 1000.0);
        self.shade();
    }

    /// Shade the resolved triangles with the document's MToon parameters.
    fn shade(&mut self) {
        let mut min_x = f32::MAX;
        let mut min_y = f32::MAX;
        let mut max_x = f32::MIN;
        let mut max_y = f32::MIN;
        for index in 0..self.engine.primitive_count() {
            let Some(vertices) = self.engine.vertex_floats(index) else {
                continue;
            };
            for v in vertices.chunks_exact(16) {
                min_x = min_x.min(v[0]);
                max_x = max_x.max(v[0]);
                min_y = min_y.min(v[1]);
                max_y = max_y.max(v[1]);
            }
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
        raster::rasterize(
            &mut target,
            &self.engine,
            &self.pages,
            &self.page_by_material,
            &self.camera,
        );
        self.output = target.into_image();
    }

    /// The frozen-contract frame for the current output page.
    fn frame(&self) -> RenderFrame {
        let mut vertices = Vec::new();
        let mut indices = Vec::new();
        let mut draws = Vec::new();
        // The shaded output page is the last page; one draw range covers the
        // whole mesh into it.
        let page = self.pages.len() as u32;
        let mut vertex_offset = 0u32;
        for index in 0..self.engine.primitive_count() {
            let Some(verts) = self.engine.vertex_floats(index) else {
                continue;
            };
            let count = (verts.len() / 16) as u32;
            for v in verts.chunks_exact(16) {
                vertices.push(Vertex {
                    x: v[0],
                    y: v[1],
                    z: v[2],
                    u: v[6],
                    v: v[7],
                });
            }
            let index_offset = indices.len() as u32;
            if let Some(indices_src) = self.engine.index_bytes(index) {
                for chunk in indices_src.chunks_exact(4) {
                    indices.push(u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]));
                }
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

/// Decode one base-colour texture into RGBA8 pixels.
fn decode_texture(texture: &crate::vrm::engine::MaterialTexture) -> Option<Image> {
    let decoded = image::load_from_memory(&texture.bytes).ok()?.to_rgba8();
    Some(Image::new(decoded.width(), decoded.height()).with_pixels(decoded.into_raw()))
}
// ---------------------------------------------------------------------------
// C ABI for the VRM backend in `cpp/vrm_backend.cpp`.
//
// The frozen `render_contract.h` dispatch reaches the VRM driver through these
// `anima_vrm_*` entry points; the C++ side owns the `airi_render_backend` table
// and mints no texture id of its own. Each function maps 1:1 onto a
// `VrmNativeRenderer` method, so the C ABI stays a thin, checked shell.
// ---------------------------------------------------------------------------

/// The renderer instance the C ABI drives (one per backend).
///
/// The C++ side holds it as an opaque `void *`; every entry point takes it back
/// as the first argument.
pub struct VrmCInstance {
    renderer: VrmNativeRenderer,
    /// Last error message, NUL-terminated.
    error: Vec<u8>,
    /// Storage for the emotion tag handed back through the C ABI.
    emotion_tag: CString,
}

/// The frozen error codes the C ABI reports.
const VRM_OK: i32 = 0;
const VRM_ERR: i32 = 1;

/// Build a renderer from the platform's texture registry.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_create(
    register: Option<unsafe extern "C" fn(*mut c_void, u32, u32) -> u32>,
    release: Option<unsafe extern "C" fn(*mut c_void, u32)>,
    ctx: *mut c_void,
    out_renderer: *mut *mut VrmCInstance,
) -> i32 {
    if out_renderer.is_null() {
        return VRM_ERR;
    }
    let Some(register) = register else {
        return VRM_ERR;
    };
    unsafe extern "C" fn noop_release(_: *mut c_void, _: u32) {}
    let release: unsafe extern "C" fn(*mut c_void, u32) = release.unwrap_or(noop_release);
    let registry = TextureRegistry::new(register, release, ctx);
    let instance = Box::new(VrmCInstance {
        renderer: VrmNativeRenderer::create(registry),
        error: b"\0".to_vec(),
        emotion_tag: CString::new("").expect("empty"),
    });
    *out_renderer = Box::into_raw(instance);
    VRM_OK
}

/// Destroy a renderer created by [`anima_vrm_create`].
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_destroy(renderer: *mut VrmCInstance) {
    if !renderer.is_null() {
        drop(Box::from_raw(renderer));
    }
}

/// Load a `.vrm`, returning its handle and first frame.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_load(
    renderer: *mut VrmCInstance,
    asset_path: *const c_char,
    out_id: *mut u64,
    out_texture_id: *mut u32,
) -> i32 {
    if renderer.is_null() || asset_path.is_null() || out_id.is_null() {
        return VRM_ERR;
    }
    let path = CStr::from_ptr(asset_path).to_string_lossy();
    match (*renderer).renderer.load(&path) {
        Ok((handle, _frame)) => {
            *out_id = handle.id;
            if !out_texture_id.is_null() {
                *out_texture_id = handle.texture_id;
            }
            VRM_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Number of texture pages the platform must upload for a model.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_page_count(
    renderer: *mut VrmCInstance,
    id: u64,
    out_count: *mut usize,
) -> i32 {
    if renderer.is_null() || out_count.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.pages(handle) {
        Ok(pages) => {
            *out_count = pages.len();
            VRM_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Copy one page's pixels into the caller's buffer.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_page(
    renderer: *mut VrmCInstance,
    id: u64,
    index: usize,
    out_width: *mut u32,
    out_height: *mut u32,
    out_pixels: *mut u8,
    pixel_cap: usize,
) -> i32 {
    if renderer.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    let pages = match (*renderer).renderer.pages(handle) {
        Ok(pages) => pages,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return VRM_ERR;
        }
    };
    let Some(page) = pages.get(index) else {
        return VRM_ERR;
    };
    if page.pixels.len() > pixel_cap {
        // A zero cap is the caller's size query (it wants width/height and the
        // byte length); only a real, too-small buffer is an error.
        if pixel_cap != 0 {
            return VRM_ERR;
        }
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
    VRM_OK
}

/// Write the resolved frame into the frozen vertex/index/draw buffers.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_render(
    renderer: *mut VrmCInstance,
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
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    let frame = match (*renderer).renderer.render(handle, delta_seconds) {
        Ok(frame) => frame,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return VRM_ERR;
        }
    };
    let geometry = &frame.geometry;
    if geometry.vertices.len() > vertex_cap
        || geometry.indices.len() > index_cap
        || geometry.draws.len() > draw_cap
    {
        return VRM_ERR;
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
    VRM_OK
}

/// Resolved counts for the next frame.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_frame_counts(
    renderer: *mut VrmCInstance,
    id: u64,
    out_vertices: *mut usize,
    out_indices: *mut usize,
    out_draws: *mut usize,
) -> i32 {
    if renderer.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    // The counters must describe the next render without shading a frame:
    // the platform calls this before every `anima_vrm_render`, so rendering
    // here doubled the per-frame CPU cost.
    let frame = match (*renderer).renderer.frame_geometry(handle) {
        Ok(frame) => frame,
        Err(err) => {
            store_error(renderer, &err.to_string());
            return VRM_ERR;
        }
    };
    if !out_vertices.is_null() {
        *out_vertices = frame.vertices.len();
    }
    if !out_indices.is_null() {
        *out_indices = frame.indices.len();
    }
    if !out_draws.is_null() {
        *out_draws = frame.draws.len();
    }
    VRM_OK
}

/// Continuous mouth-open weight (the `aa`/`a` channel).
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_set_lip_sync(
    renderer: *mut VrmCInstance,
    id: u64,
    weight: f32,
) -> i32 {
    if renderer.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.set_lip_sync(handle, weight) {
        Ok(()) => VRM_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Additive emotion cue by semantic tag.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_set_emotion(
    renderer: *mut VrmCInstance,
    id: u64,
    tag: *const c_char,
    intensity: f32,
) -> i32 {
    if renderer.is_null() || tag.is_null() {
        return VRM_ERR;
    }
    let tag = CStr::from_ptr(tag).to_string_lossy();
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer)
        .renderer
        .set_emotion(handle, &tag, "motion", intensity)
    {
        Ok(()) => VRM_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Continuous idle/ambient phase.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_set_ambient_phase(
    renderer: *mut VrmCInstance,
    id: u64,
    phase: f32,
) -> i32 {
    if renderer.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.set_ambient_phase(handle, phase) {
        Ok(()) => VRM_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Release a model and its platform textures. Idempotent.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_dispose(renderer: *mut VrmCInstance, id: u64) -> i32 {
    if renderer.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.dispose(handle) {
        Ok(()) => VRM_OK,
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Read back the mouth-open weight the model last applied.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_get_lip_sync(
    renderer: *mut VrmCInstance,
    id: u64,
    out_weight: *mut f32,
) -> i32 {
    if renderer.is_null() || out_weight.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.lip_sync(handle) {
        Ok(weight) => {
            *out_weight = weight;
            VRM_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Read back the current emotion cue (tag, kind, intensity).
///
/// `out_kind` is always `"motion"`: the frozen ABI carries the cue kind, while
/// the renderer keys the additive channel by semantic tag.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_get_emotion(
    renderer: *mut VrmCInstance,
    id: u64,
    out_tag: *mut *const c_char,
    out_intensity: *mut f32,
) -> i32 {
    if renderer.is_null() || out_tag.is_null() {
        return VRM_ERR;
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
            VRM_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Read back the current ambient phase.
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_get_ambient_phase(
    renderer: *mut VrmCInstance,
    id: u64,
    out_phase: *mut f32,
) -> i32 {
    if renderer.is_null() || out_phase.is_null() {
        return VRM_ERR;
    }
    let handle = airi_render_handle { id, texture_id: 0 };
    match (*renderer).renderer.ambient_phase(handle) {
        Ok(phase) => {
            *out_phase = phase;
            VRM_OK
        }
        Err(err) => {
            store_error(renderer, &err.to_string());
            VRM_ERR
        }
    }
}

/// Last error message (NUL-terminated, owned by the instance).
#[no_mangle]
pub unsafe extern "C" fn anima_vrm_last_error(renderer: *mut VrmCInstance) -> *const c_char {
    if renderer.is_null() {
        return b"vrm: null instance ".as_ptr() as *const c_char;
    }
    let error = &mut (*renderer).error;
    if error.is_empty() {
        error.push(b'0');
    }
    error.as_ptr() as *const c_char
}

/// Record `message` as the instance's last error.
unsafe fn store_error(renderer: *mut VrmCInstance, message: &str) {
    if renderer.is_null() {
        return;
    }
    let error = &mut (*renderer).error;
    error.clear();
    error.extend_from_slice(message.as_bytes());
    error.push(b'\0');
}

// ---------------------------------------------------------------------------
// Engine read-only views.
//
// `crate::vrm::engine` keeps its work buffers, morph tables and controllers
// private. These read-only views go through the engine's own public accessors,
// so the engine remains the single owner of skinning, morph blending and spring
// bones; nothing here mutates or caches engine state.
// ---------------------------------------------------------------------------
mod access {
    use crate::vrm::engine::Engine;

    /// Read-only views over the engine's resolved state.
    pub(super) trait EngineView {
        /// MToon parameters, index-aligned with the document's materials.
        fn view_materials(&self) -> &[crate::vrm::materials::MtoonParams];
        /// The document-spelled mouth preset (`aa` / `a`).
        fn view_lip_preset(&self) -> Option<String>;
        /// The document-spelled blink presets.
        fn view_blink_presets(&self) -> Vec<String>;
        /// The weight the engine applied to `preset` on the last tick.
        fn view_preset_weight(&self, preset: &str) -> f32;
        /// Number of simulated spring-bone chains.
        fn view_spring_bone_count(&self) -> usize;
    }

    impl EngineView for Engine {
        fn view_materials(&self) -> &[crate::vrm::materials::MtoonParams] {
            self.material_params()
        }

        fn view_lip_preset(&self) -> Option<String> {
            self.lip_raw().first().cloned()
        }

        fn view_blink_presets(&self) -> Vec<String> {
            self.blink_raw().to_vec()
        }

        fn view_preset_weight(&self, preset: &str) -> f32 {
            self.expression_weight(preset)
        }

        fn view_spring_bone_count(&self) -> usize {
            self.spring_bone_chain_count()
        }
    }
}
use access::EngineView;
