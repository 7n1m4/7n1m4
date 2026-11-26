// SPDX-License-Identifier: GPL-3.0-or-later
//! Self-contained MMD toon rasteriser for the native MMD driver.
//!
//! The frozen render contract carries triangles, draw ranges and texture pages
//! but no shader; the per-OS plugin would normally shade on the GPU. This pass
//! is the renderer-agnostic equivalent: it z-buffers the posed triangles and
//! shades each fragment with the PMX material's base/shade colours through a
//! two-step toon ramp (the fallback MMD itself uses when no `toonNN.bmp` is
//! bundled), producing the RGBA8 page the platform uploads as the model's
//! output texture. It has no GPU dependency, so the same code runs in tests
//! and in the plugin.
//!
//! What it is not: MMD's outline pass, sphere maps, edge hulls and the
//! built-in toon ramps are out of scope (the parser stores the references and
//! this pass ignores them).

use super::Model;

/// A tightly packed RGBA8 image.
pub struct Image {
    /// Image width in pixels.
    pub width: u32,
    /// Image height in pixels.
    pub height: u32,
    /// Tightly packed RGBA8 pixel data.
    pub pixels: Vec<u8>,
}

impl Image {
    /// A zero-filled RGBA8 image of the given size.
    pub fn new(width: u32, height: u32) -> Self {
        Self { width, height, pixels: vec![0u8; (width * height * 4) as usize] }
    }
    /// Replace the pixels, asserting the buffer is tightly packed RGBA8.
    pub fn with_pixels(mut self, pixels: Vec<u8>) -> Self {
        assert_eq!(pixels.len(), self.width as usize * self.height as usize * 4, "image pixels must be tightly packed RGBA8");
        self.pixels = pixels;
        self
    }
}

/// Camera projection parameters.
pub struct Camera {
    /// Center of projection in normalized device coordinates.
    pub center: [f32; 2],
    /// Scale factor applied to the projection.
    pub scale: f32,
}

impl Default for Camera {
    fn default() -> Self {
        Self { center: [0.0, 0.0], scale: 1.0 }
    }
}

/// A rasterization target with color and depth buffers.
pub struct RasterTarget {
    /// Target width in pixels.
    pub width: u32,
    /// Target height in pixels.
    pub height: u32,
    /// RGBA8 color buffer.
    pub pixels: Vec<u8>,
    /// Per-pixel depth buffer.
    pub depth: Vec<f32>,
}

impl RasterTarget {
    /// A cleared target (transparent black, depth = +inf).
    pub fn new(width: u32, height: u32) -> Self {
        Self {
            width,
            height,
            pixels: vec![0u8; (width * height * 4) as usize],
            depth: vec![f32::INFINITY; (width * height) as usize],
        }
    }
    /// Reset the colour and depth buffers.
    pub fn clear(&mut self) {
        self.pixels.fill(0);
        self.depth.fill(f32::INFINITY);
    }
    /// Convert into the plain RGBA8 image the platform uploads.
    pub fn into_image(self) -> Image {
        Image { width: self.width, height: self.height, pixels: self.pixels }
    }
}

/// Two-step toon ramp threshold: below `0.5` N·L the fragment is shaded,
/// above it the fragment is lit.
const TOON_STEP: f32 = 0.5;

/// Shade every primitive of `model` into `target`.
pub(crate) fn rasterize(model: &Model, target: &mut RasterTarget, camera: &Camera) {
    target.clear();
    for primitive in 0..model.rest.primitive_count() {
        let Some(index_bytes) = model.rest.index_bytes(primitive) else {
            continue;
        };
        let material_index = model.rest.primitive_material(primitive).unwrap_or(-1);
        let material = if material_index >= 0 {
            model.rest.materials().get(material_index as usize)
        } else {
            None
        };
        let page = if material_index >= 0 {
            model.page_by_material.get(&(material_index as u32)).copied()
        } else {
            None
        };
        rasterize_primitive(
            target,
            &model.positions,
            &model.document.vertices,
            index_bytes,
            page,
            model,
            material,
            camera,
        );
    }
}

/// Rasterise one primitive's triangle list.
#[allow(clippy::too_many_arguments)]
fn rasterize_primitive(
    target: &mut RasterTarget,
    positions: &[[f32; 3]],
    vertices: &[anima_mmd::MmdVertex],
    indices: &[u8],
    page: Option<u32>,
    model: &Model,
    material: Option<&anima_mmd::RestPoseMaterial>,
    camera: &Camera,
) {
    let vertex_count = positions.len();
    let index_count = indices.len() / 4;
    let index = |i: usize| -> u32 {
        u32::from_le_bytes([
            indices[i * 4],
            indices[i * 4 + 1],
            indices[i * 4 + 2],
            indices[i * 4 + 3],
        ])
    };
    // Project every vertex once: screen x/y and view depth.
    let mut sx = vec![0.0f32; vertex_count];
    let mut sy = vec![0.0f32; vertex_count];
    for v in 0..vertex_count {
        let p = positions[v];
        sx[v] = (p[0] - camera.center[0]) * camera.scale + target.width as f32 * 0.5;
        sy[v] = target.height as f32 * 0.5 - (p[1] - camera.center[1]) * camera.scale;
    }

    for t in 0..index_count / 3 {
        let (i0, i1, i2) = (
            index(t * 3) as usize,
            index(t * 3 + 1) as usize,
            index(t * 3 + 2) as usize,
        );
        if i0 >= vertex_count || i1 >= vertex_count || i2 >= vertex_count {
            continue;
        }
        let (x0, y0) = (sx[i0], sy[i0]);
        let (x1, y1) = (sx[i1], sy[i1]);
        let (x2, y2) = (sx[i2], sy[i2]);
        let area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
        if area.abs() < 1e-9 {
            continue; // degenerate on screen
        }
        let min_x = x0.min(x1).min(x2).max(0.0).floor() as i64;
        let max_x = x0.max(x1).max(x2).min(target.width as f32 - 1.0).ceil() as i64;
        let min_y = y0.min(y1).min(y2).max(0.0).floor() as i64;
        let max_y = y0.max(y1).max(y2).min(target.height as f32 - 1.0).ceil() as i64;
        if min_x > max_x || min_y > max_y {
            continue;
        }

        let (a0, a1, a2) = (attr(vertices, i0), attr(vertices, i1), attr(vertices, i2));

        for y in min_y..=max_y {
            for x in min_x..=max_x {
                let px = x as f32 + 0.5;
                let py = y as f32 + 0.5;
                let w0 = ((x1 - px) * (y2 - py) - (x2 - px) * (y1 - py)) / area;
                let w1 = ((x2 - px) * (y0 - py) - (x0 - px) * (y2 - py)) / area;
                let w2 = 1.0 - w0 - w1;
                if w0 < 0.0 || w1 < 0.0 || w2 < 0.0 {
                    continue;
                }
                let z = positions[i0][2] * w0 + positions[i1][2] * w1 + positions[i2][2] * w2;
                let offset = (y as usize * target.width as usize + x as usize) * 4;
                if z >= target.depth[y as usize * target.width as usize + x as usize] {
                    continue;
                }
                let sample = Sample {
                    u: a0.u * w0 + a1.u * w1 + a2.u * w2,
                    v: a0.v * w0 + a1.v * w1 + a2.v * w2,
                    normal: [
                        a0.normal[0] * w0 + a1.normal[0] * w1 + a2.normal[0] * w2,
                        a0.normal[1] * w0 + a1.normal[1] * w1 + a2.normal[1] * w2,
                        a0.normal[2] * w0 + a1.normal[2] * w1 + a2.normal[2] * w2,
                    ],
                    depth: z,
                };
                let base = material
                    .map(|m| sample_base_color(m.clone(), page, &model.pages, &sample))
                    .unwrap_or([1.0, 1.0, 1.0, 1.0]);
                let shaded = shade_fragment(material, &sample, base);
                target.depth[y as usize * target.width as usize + x as usize] = z;
                target.pixels[offset..offset + 4].copy_from_slice(&shaded);
            }
        }
    }
}

/// Interpolated per-fragment attributes.
#[derive(Debug, Clone, Copy)]
pub struct Sample {
    /// Texture u.
    pub u: f32,
    /// Texture v.
    pub v: f32,
    /// Interpolated world normal.
    pub normal: [f32; 3],
    /// View depth (z).
    pub depth: f32,
}

/// The interpolated attributes at one vertex.
fn attr(vertices: &[anima_mmd::MmdVertex], v: usize) -> Sample {
    Sample {
        u: vertices[v].uv[0],
        v: vertices[v].uv[1],
        normal: vertices[v].normal,
        depth: 0.0,
    }
}

/// Sample the base colour: the material's base-colour texture when the fragment
/// has a page, else the flat base colour factor.
fn sample_base_color(
    material: anima_mmd::RestPoseMaterial,
    page: Option<u32>,
    pages: &[Image],
    sample: &Sample,
) -> [f32; 4] {
    if let Some(page) = page {
        if let Some(image) = pages.get(page as usize) {
            let u = sample.u.rem_euclid(1.0);
            let v = sample.v.rem_euclid(1.0);
            let x = ((u * image.width as f32) as u32).min(image.width - 1);
            let y = ((v * image.height as f32) as u32).min(image.height - 1);
            let offset = (y as usize * image.width as usize + x as usize) * 4;
            let texel = [
                image.pixels[offset] as f32 / 255.0,
                image.pixels[offset + 1] as f32 / 255.0,
                image.pixels[offset + 2] as f32 / 255.0,
                image.pixels[offset + 3] as f32 / 255.0,
            ];
            return [
                texel[0] * material.base_color[0],
                texel[1] * material.base_color[1],
                texel[2] * material.base_color[2],
                texel[3] * material.base_color[3],
            ];
        }
    }
    material.base_color
}

/// Shade one fragment with the PMX two-step toon model.
///
/// MMD's core is a two-band ramp: `N·L` selects between the shade colour and
/// the base colour, with the step at [`TOON_STEP`]. This is the real
/// per-fragment maths; the outline, sphere-map and edge passes are out of
/// scope.
pub fn shade_fragment(
    material: Option<&anima_mmd::RestPoseMaterial>,
    sample: &Sample,
    base: [f32; 4],
) -> [u8; 4] {
    let Some(material) = material else {
        return to_rgba(base);
    };
    // Key light from the camera's upper-left, in view space.
    let light = normalize([-0.4, 0.6, 0.7]);
    let normal = normalize(sample.normal);
    let n_dot_l =
        (normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2]).clamp(0.0, 1.0);
    let lit = f32::from(n_dot_l >= TOON_STEP);
    let shade = 1.0 - lit;
    let mut rgb = [0.0f32; 3];
    for c in 0..3 {
        rgb[c] = base[c] * (1.0 - shade) + base[c] * material.shade_color[c] * shade;
    }
    let alpha = base[3].clamp(0.0, 1.0);
    to_rgba([rgb[0], rgb[1], rgb[2], alpha])
}

fn normalize(v: [f32; 3]) -> [f32; 3] {
    let len = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    if len < 1e-8 {
        return [0.0, 0.0, 1.0];
    }
    [v[0] / len, v[1] / len, v[2] / len]
}

fn to_rgba(c: [f32; 4]) -> [u8; 4] {
    [
        (c[0].clamp(0.0, 1.0) * 255.0 + 0.5) as u8,
        (c[1].clamp(0.0, 1.0) * 255.0 + 0.5) as u8,
        (c[2].clamp(0.0, 1.0) * 255.0 + 0.5) as u8,
        (c[3].clamp(0.0, 1.0) * 255.0 + 0.5) as u8,
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn material() -> anima_mmd::RestPoseMaterial {
        anima_mmd::RestPoseMaterial {
            name: "m".to_string(),
            name_global: String::new(),
            base_color: [1.0, 1.0, 1.0, 1.0],
            shade_color: [0.5, 0.5, 0.5, 1.0],
            texture_index: -1,
            texture: None,
        }
    }

    #[test]
    fn lit_fragment_is_brighter_than_shaded() {
        let m = material();
        let lit = shade_fragment(
            Some(&m),
            &Sample {
                u: 0.0,
                v: 0.0,
                normal: [0.0, 0.0, 1.0],
                depth: 0.0,
            },
            [1.0, 1.0, 1.0, 1.0],
        );
        let shade = shade_fragment(
            Some(&m),
            &Sample {
                u: 0.0,
                v: 0.0,
                normal: [0.0, 0.0, -1.0],
                depth: 0.0,
            },
            [1.0, 1.0, 1.0, 1.0],
        );
        assert!(lit[0] > shade[0], "lit {lit:?} vs shade {shade:?}");
    }

    #[test]
    fn missing_material_returns_base() {
        let out = shade_fragment(
            None,
            &Sample {
                u: 0.0,
                v: 0.0,
                normal: [0.0, 0.0, 1.0],
                depth: 0.0,
            },
            [0.25, 0.5, 0.75, 1.0],
        );
        assert_eq!(out, [64, 128, 191, 255]);
    }
}