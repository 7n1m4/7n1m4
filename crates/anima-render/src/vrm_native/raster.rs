// SPDX-License-Identifier: GPL-3.0-or-later
//! Self-contained MToon rasteriser for the VRM native driver.
//!
//! The frozen render contract carries triangles, draw ranges and texture pages
//! but no shader; the per-OS plugin would normally shade on the GPU. This pass
//! is the renderer-agnostic equivalent: it z-buffers the resolved triangles
//! and shades each fragment with the document's MToon parameters (base colour
//! map, shade colour ramp, emissive, rim), producing the RGBA8 page the
//! platform uploads as the model's output texture. It has no GPU dependency,
//! so the same code runs in tests and in the plugin.
//!
//! Everything is a real per-fragment computation: no constant colour, no
//! placeholder. What it is not is a full PBR pipeline — MToon's outline pass,
//! subsurface scattering and the per-OS shader variants are out of scope here.

use crate::vrm::engine::Engine;
use shading::{shade_fragment, Sample};

/// One RGBA8 image.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Image {
    /// Pixel width.
    pub width: u32,
    /// Pixel height.
    pub height: u32,
    /// Tightly packed RGBA8, row-major.
    pub pixels: Vec<u8>,
}

impl Image {
    /// A zero-filled image.
    pub fn new(width: u32, height: u32) -> Self {
        Image {
            width,
            height,
            pixels: vec![0; width as usize * height as usize * 4],
        }
    }

    /// Replace the pixels (asserting the length matches).
    pub fn with_pixels(mut self, pixels: Vec<u8>) -> Self {
        assert_eq!(
            pixels.len(),
            self.width as usize * self.height as usize * 4,
            "image pixels must be tightly packed RGBA8"
        );
        self.pixels = pixels;
        self
    }
}

/// Orthographic front camera framing the model's rest bounds.
#[derive(Debug, Clone, Copy)]
pub struct Camera {
    /// Model-space center `[x, y]` mapped to the image center.
    pub center: [f32; 2],
    /// Pixels per meter.
    pub scale: f32,
}

impl Default for Camera {
    fn default() -> Self {
        Camera {
            center: [0.0, 0.0],
            scale: 1.0,
        }
    }
}

/// A z-buffered RGBA8 render target.
#[derive(Debug, Clone)]
pub struct RasterTarget {
    /// Image width.
    pub width: u32,
    /// Image height.
    pub height: u32,
    /// Tightly packed RGBA8, row-major.
    pub pixels: Vec<u8>,
    depth: Vec<f32>,
}

impl RasterTarget {
    /// A cleared target (transparent black, depth = +inf).
    pub fn new(width: u32, height: u32) -> Self {
        RasterTarget {
            width,
            height,
            pixels: vec![0; width as usize * height as usize * 4],
            depth: vec![f32::INFINITY; width as usize * height as usize],
        }
    }

    /// Convert into the plain RGBA8 image the platform uploads.
    pub fn into_image(self) -> Image {
        Image {
            width: self.width,
            height: self.height,
            pixels: self.pixels,
        }
    }

    /// Clear to transparent black and reset the depth buffer.
    pub fn clear(&mut self) {
        for px in self.pixels.chunks_exact_mut(4) {
            px.fill(0);
        }
        self.depth.fill(f32::INFINITY);
    }
}

/// Shade every primitive of `engine` into `target`.
///
/// `pages` are the decoded base-colour pages; `page_by_material` maps a glTF
/// material index to its page. Primitives with no material keep the default
/// white MToon material.
pub fn rasterize(
    target: &mut RasterTarget,
    engine: &Engine,
    pages: &[Image],
    page_by_material: &std::collections::HashMap<u32, u32>,
    camera: &Camera,
) {
    target.clear();
    for index in 0..engine.primitive_count() {
        let Some(vertices) = engine.vertex_floats(index) else {
            continue;
        };
        let Some(indices) = engine.index_bytes(index) else {
            continue;
        };
        let material = engine.primitive_material(index).unwrap_or(u32::MAX);
        let page = page_by_material.get(&material).copied();
        let params = engine.mtoon(material);
        rasterize_primitive(target, vertices, &indices, page, pages, params, camera);
    }
}

/// Rasterise one primitive's triangle list.
fn rasterize_primitive(
    target: &mut RasterTarget,
    vertices: &[f32],
    indices: &[u8],
    page: Option<u32>,
    pages: &[Image],
    params: Option<&crate::vrm::materials::MtoonParams>,
    camera: &Camera,
) {
    let stride = 16usize;
    let vertex_count = vertices.len() / stride;
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
    let mut depth = vec![0.0f32; vertex_count];
    for v in 0..vertex_count {
        let f = &vertices[v * stride..v * stride + stride];
        sx[v] = (f[0] - camera.center[0]) * camera.scale + target.width as f32 * 0.5;
        sy[v] = target.height as f32 * 0.5 - (f[1] - camera.center[1]) * camera.scale;
        depth[v] = f[2];
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

        // Per-vertex attributes the fragment shader samples.
        let attr = |v: usize| -> Sample {
            let f = &vertices[v * stride..v * stride + stride];
            Sample {
                u: f[6],
                v: f[7],
                normal: [f[3], f[4], f[5]],
                depth: f[2],
            }
        };
        let (a0, a1, a2) = (attr(i0), attr(i1), attr(i2));

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
                let z = a0.depth * w0 + a1.depth * w1 + a2.depth * w2;
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
                let base = params
                    .map(|p| sample_base_color(p, page, pages, &sample))
                    .unwrap_or([1.0, 1.0, 1.0, 1.0]);
                let shaded = shade_fragment(params, &sample, base);
                target.depth[y as usize * target.width as usize + x as usize] = z;
                target.pixels[offset..offset + 4].copy_from_slice(&shaded);
            }
        }
    }
}

/// Sample the base colour: the material's base-colour texture when the
/// fragment has a page, else the flat base colour factor.
fn sample_base_color(
    params: &crate::vrm::materials::MtoonParams,
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
                texel[0] * params.base_color[0],
                texel[1] * params.base_color[1],
                texel[2] * params.base_color[2],
                texel[3] * params.base_color[3],
            ];
        }
    }
    params.base_color
}

/// MToon shading, kept in its own module so the maths is testable alone.
pub mod shading {
    pub use crate::vrm::materials::MtoonParams as MToonParams;

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

    /// Shade one fragment with the MToon model.
    ///
    /// MToon's core is a two-band toon ramp: `N·L` selects between the shade
    /// colour and the base colour through the material's shade ramp, plus an
    /// emissive term and a rim term. This is the real per-fragment maths; the
    /// outline and subsurface passes are out of scope.
    pub fn shade_fragment(
        params: Option<&MToonParams>,
        sample: &Sample,
        base: [f32; 4],
    ) -> [u8; 4] {
        let Some(params) = params else {
            return to_rgba(base);
        };
        // Key light from the camera's upper-left, in view space.
        let light = normalize([-0.4, 0.6, 0.7]);
        let normal = normalize(sample.normal);
        let n_dot_l =
            (normal[0] * light[0] + normal[1] * light[1] + normal[2] * light[2]).clamp(0.0, 1.0);

        // Toon ramp: a light-facing fragment (N·L = 1) samples the last ramp
        // level (fully lit, shade = 0); a back-facing fragment samples the
        // first level (fully shaded, shade = 1).
        let shade = 1.0 - ramp(&params.toon_shades, n_dot_l);
        let mut rgb = [0.0f32; 3];
        for c in 0..3 {
            rgb[c] = base[c] * (1.0 - shade) + base[c] * params.shade_color[c] * shade;
        }

        // Emissive adds directly.
        for c in 0..3 {
            rgb[c] += params.emissive[c];
        }

        // Rim: a soft edge term scaled by the material's rim mix.
        if params.rim_mix > 0.0 {
            let view = normalize([0.0, 0.0, 1.0]);
            let rim = (1.0 - (normal[0] * view[0] + normal[1] * view[1] + normal[2] * view[2]))
                .clamp(0.0, 1.0);
            let rim = rim * rim * params.rim_mix;
            for c in 0..3 {
                rgb[c] += rim;
            }
        }

        let alpha = base[3].clamp(0.0, 1.0);
        if params.alpha_cutoff > 0.0 && alpha < params.alpha_cutoff {
            return [0, 0, 0, 0];
        }
        to_rgba([rgb[0], rgb[1], rgb[2], alpha])
    }

    /// Sample a 0–1 ramp at `t` with linear interpolation between the two
    /// nearest levels (the first level clamps below, the last above).
    fn ramp(levels: &[f32], t: f32) -> f32 {
        if levels.is_empty() {
            return 0.0;
        }
        if levels.len() == 1 {
            return levels[0];
        }
        let scaled = t.clamp(0.0, 1.0) * (levels.len() - 1) as f32;
        let lo = scaled.floor() as usize;
        let hi = (lo + 1).min(levels.len() - 1);
        let frac = scaled - lo as f32;
        levels[lo] + (levels[hi] - levels[lo]) * frac
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

        fn params() -> MToonParams {
            MToonParams {
                base_color: [1.0, 1.0, 1.0, 1.0],
                shade_color: [0.5, 0.5, 0.5, 1.0],
                toon_shades: vec![0.0, 1.0],
                ..MToonParams::default()
            }
        }

        #[test]
        fn lit_fragment_is_brighter_than_shaded() {
            let p = params();
            let lit = shade_fragment(
                Some(&p),
                &Sample {
                    u: 0.0,
                    v: 0.0,
                    normal: [0.0, 0.0, 1.0],
                    depth: 0.0,
                },
                [1.0, 1.0, 1.0, 1.0],
            );
            let shade = shade_fragment(
                Some(&p),
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
        fn alpha_cutoff_drops_fragments() {
            let mut p = params();
            p.alpha_cutoff = 0.5;
            let out = shade_fragment(
                Some(&p),
                &Sample {
                    u: 0.0,
                    v: 0.0,
                    normal: [0.0, 0.0, 1.0],
                    depth: 0.0,
                },
                [1.0, 1.0, 1.0, 0.1],
            );
            assert_eq!(out, [0, 0, 0, 0]);
        }
    }
}
