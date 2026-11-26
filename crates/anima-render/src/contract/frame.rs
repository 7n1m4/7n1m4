// SPDX-License-Identifier: GPL-3.0-or-later
//! The renderer-agnostic frame shape every backend produces.
//!
//! A frame is the complete, fully-resolved geometry for one render tick: the
//! platform uploads [`RenderFrame::pages`] as GPU textures once, then draws
//! [`RenderFrame::geometry`] every tick with the draw commands in
//! [`FrameGeometry::draws`]. Nothing here knows about a specific model format.

/// Texture pixel layout of a [`TexturePayload`].
#[repr(u8)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum TextureFormat {
    /// 8-bit RGBA, row-major, 4 bytes per pixel.
    #[default]
    Rgba8 = 0,
}

/// One texture page uploaded to the GPU once per model load.
///
/// The bytes are the fully-decoded image (PNG/JPEG already decoded by the
/// backend); the platform never sees the encoded container.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TexturePayload {
    /// Stable name used by draw commands' page lookup (e.g. the atlas image
    /// name). Unique within one [`RenderFrame`].
    pub name: String,
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
    /// Pixel format.
    pub format: TextureFormat,
    /// Whether texels are stored premultiplied by alpha.
    pub premultiplied_alpha: bool,
    /// Row-major pixel bytes, `width * height * bytes_per_pixel` long.
    pub pixels: Vec<u8>,
}

impl TexturePayload {
    /// Bytes per pixel for this payload's format.
    pub fn bytes_per_pixel(&self) -> usize {
        match self.format {
            TextureFormat::Rgba8 => 4,
        }
    }
}

/// How a draw command composites with the framebuffer.
///
/// The numeric values are the frozen wire values (`blend_mode` in the spine
/// shell and the native contract); do not reorder.
#[repr(i32)]
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BlendMode {
    /// Source-over (`GL_SRC_ALPHA`, `GL_ONE_MINUS_SRC_ALPHA`).
    #[default]
    Normal = 0,
    /// Additive (`GL_SRC_ALPHA`, `GL_ONE`).
    Additive = 1,
    /// Multiply (`GL_DST_COLOR`, `GL_ONE_MINUS_SRC_ALPHA`).
    Multiply = 2,
    /// Screen (`GL_ONE`, `GL_ONE_MINUS_SRC_COLOR`).
    Screen = 3,
}

impl BlendMode {
    /// Decode a wire `blend_mode` integer; unknown values fall back to
    /// [`BlendMode::Normal`] so a malformed frame degrades instead of
    /// corrupting the pipeline.
    pub fn from_wire(value: i32) -> Self {
        match value {
            1 => BlendMode::Additive,
            2 => BlendMode::Multiply,
            3 => BlendMode::Screen,
            _ => BlendMode::Normal,
        }
    }

    /// The frozen wire integer for this blend mode.
    pub fn to_wire(self) -> i32 {
        self as i32
    }
}

/// One textured vertex. Positions are in the model's world space (y-up for 2D
/// spine scenes, meters for 3D glTF/VRM scenes); `uv` is normalized `[0,1]`
/// into the draw's page.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Vertex {
    /// World-space x.
    pub x: f32,
    /// World-space y.
    pub y: f32,
    /// World-space z (0.0 for flat 2D scenes).
    pub z: f32,
    /// Normalized u into the page.
    pub u: f32,
    /// Normalized v into the page.
    pub v: f32,
}

/// One draw range. Vertex and index offsets/counts index into
/// [`FrameGeometry::vertices`] / [`FrameGeometry::indices`]; `page` indexes
/// into [`RenderFrame::pages`].
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct DrawCommand {
    /// Index into [`RenderFrame::pages`].
    pub page: u32,
    /// Compositing mode.
    pub blend: BlendMode,
    /// Slot/attachment alpha already multiplied in.
    pub alpha: f32,
    /// Start offset into the vertex buffer.
    pub vertex_offset: u32,
    /// Number of vertices.
    pub vertex_count: u32,
    /// Start offset into the index buffer.
    pub index_offset: u32,
    /// Number of indices.
    pub index_count: u32,
}

/// The flat geometry buffers for one frame, in the layout the platform's
/// `drawElements` pass consumes directly.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct FrameGeometry {
    /// Vertices in world space.
    pub vertices: Vec<Vertex>,
    /// Triangle indices into `vertices`.
    pub indices: Vec<u32>,
    /// Draw ranges in slot draw order.
    pub draws: Vec<DrawCommand>,
}

/// One fully-resolved render frame.
///
/// `pages` are uploaded once at load; `geometry` is re-uploaded every tick.
/// A frame with no draws is valid (an empty/hidden model) and the platform
/// simply presents the cleared texture.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RenderFrame {
    /// Texture pages for this model, in page-index order.
    pub pages: Vec<TexturePayload>,
    /// The posed geometry for this tick.
    pub geometry: FrameGeometry,
}