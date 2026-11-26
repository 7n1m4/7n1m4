// SPDX-License-Identifier: GPL-3.0-or-later
// MMD side of the frozen render/texture contract.
//
// The Rust `anima_render::mmd_native` driver owns the whole MMD pipeline:
// rest-pose assembly, VMD sampling, morph mixing, vowel lip-sync, additive
// expressions and the CPU toon shading pass. What the C++ side adds is the part
// the frozen `render_contract.h` expects but the Rust driver cannot see: the
// `airi_render_backend` table, whose definition is private to
// `render_contract.cpp`.
//
// The calls here run on the Rust side (`anima_mmd_*`, linked from
// `libanima_render`). This file owns nothing but the per-model page bookkeeping
// the getters read back, and it mints no texture id: page ids come from the
// platform's `register_texture` closure and go back through
// `release_texture` at dispose.

#ifndef AIRI_MMD_BACKEND_H
#define AIRI_MMD_BACKEND_H

#include "render_contract.h"

#ifdef __cplusplus
extern "C" {
#endif

// Opaque Rust-side renderer instance (one per MMD backend). Created by
// `anima_mmd_create`, destroyed by `anima_mmd_destroy`; the handle is stored in
// the caller's backend table.
struct MmdCInstance;

// --- Rust entry points (linked from libanima_render) ----------------------
// Every function returns 0 on success and nonzero on failure; the reason is
// available from `anima_mmd_last_error` until the next mutating call.

int32_t anima_mmd_create(uint32_t (*register_texture)(void *, uint32_t, uint32_t),
                         void (*release_texture)(void *, uint32_t),
                         void *ctx,
                         MmdCInstance **out_renderer);
void anima_mmd_destroy(MmdCInstance *renderer);
int32_t anima_mmd_load(MmdCInstance *renderer,
                       const char *asset_path,
                       uint64_t *out_id,
                       uint32_t *out_texture_id);
int32_t anima_mmd_page_count(MmdCInstance *renderer, uint64_t id, size_t *out_count);
int32_t anima_mmd_page(MmdCInstance *renderer,
                       uint64_t id,
                       size_t index,
                       uint32_t *out_width,
                       uint32_t *out_height,
                       uint8_t *out_pixels,
                       size_t pixel_cap);
int32_t anima_mmd_render(MmdCInstance *renderer,
                         uint64_t id,
                         float delta_seconds,
                         airi_render_vertex *out_vertices,
                         size_t vertex_cap,
                         uint32_t *out_indices,
                         size_t index_cap,
                         airi_render_draw *out_draws,
                         size_t draw_cap);
int32_t anima_mmd_frame_counts(MmdCInstance *renderer,
                               uint64_t id,
                               size_t *out_vertices,
                               size_t *out_indices,
                               size_t *out_draws);
int32_t anima_mmd_set_lip_sync(MmdCInstance *renderer, uint64_t id, float weight);
int32_t anima_mmd_set_emotion(MmdCInstance *renderer,
                              uint64_t id,
                              const char *tag,
                              float intensity);
int32_t anima_mmd_set_ambient_phase(MmdCInstance *renderer, uint64_t id, float phase);
int32_t anima_mmd_dispose(MmdCInstance *renderer, uint64_t id);
int32_t anima_mmd_get_lip_sync(MmdCInstance *renderer, uint64_t id, float *out_weight);
int32_t anima_mmd_get_emotion(MmdCInstance *renderer,
                              uint64_t id,
                              const char **out_tag,
                              float *out_intensity);
int32_t anima_mmd_get_ambient_phase(MmdCInstance *renderer, uint64_t id, float *out_phase);
const char *anima_mmd_last_error(MmdCInstance *renderer);

// Load `asset_path` (a `.pmx`) into `backend` under a fresh model id.
// Returns 0 on success; nonzero leaves `out_handle` untouched and records the
// reason in the backend's last error.
int32_t airi_mmd_load(airi_render_backend *backend,
                      const char *asset_path,
                      airi_render_handle *out_handle);

// Texture pages for an MMD model (decoded base colours, then the shaded output).
int32_t airi_mmd_pages(airi_render_backend *backend,
                       airi_render_handle handle,
                       airi_render_page *out_pages,
                       size_t page_cap,
                       size_t *out_count);

// Resolved geometry counts for the next frame.
int32_t airi_mmd_frame_counts(airi_render_backend *backend,
                              airi_render_handle handle,
                              size_t *out_vertices,
                              size_t *out_indices,
                              size_t *out_draws);

// Advance and serialise one frame in the frozen vertex/index/draw shapes.
int32_t airi_mmd_render(airi_render_backend *backend,
                        airi_render_handle handle,
                        float delta_seconds,
                        airi_render_vertex *out_vertices,
                        size_t vertex_cap,
                        uint32_t *out_indices,
                        size_t index_cap,
                        airi_render_draw *out_draws,
                        size_t draw_cap);

// Continuous mouth-open weight in [0, 1] (the `あ` channel).
int32_t airi_mmd_set_lip_sync(airi_render_backend *backend,
                              airi_render_handle handle,
                              float weight);

// Additive emotion cue by semantic tag.
int32_t airi_mmd_set_emotion(airi_render_backend *backend,
                             airi_render_handle handle,
                             const char *tag,
                             const char *kind,
                             float intensity);

// Continuous idle/ambient phase in [0, 1].
int32_t airi_mmd_set_ambient_phase(airi_render_backend *backend,
                                   airi_render_handle handle,
                                   float phase);

// Read the sinks back from the native renderer (not the table copy).
int32_t airi_mmd_get_lip_sync(airi_render_backend *backend,
                              airi_render_handle handle,
                              float *out_weight);
int32_t airi_mmd_get_emotion(airi_render_backend *backend,
                             airi_render_handle handle,
                             const char **out_tag,
                             const char **out_kind,
                             float *out_intensity);
int32_t airi_mmd_get_ambient_phase(airi_render_backend *backend,
                                   airi_render_handle handle,
                                   float *out_phase);

// Release the model and its platform textures. Idempotent.
int32_t airi_mmd_dispose(airi_render_backend *backend, airi_render_handle handle);

// Shut down the MMD backend and release all resources.
void airi_mmd_shutdown(airi_render_backend *backend);

#ifdef __cplusplus
} // extern "C"
#endif

#endif // AIRI_MMD_BACKEND_H