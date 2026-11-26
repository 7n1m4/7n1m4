// SPDX-License-Identifier: GPL-3.0-or-later
// Frozen C ABI for the native render/texture contract.
//
// This is the single cross-language boundary the per-OS GPU backends expose to
// the Flutter plugin. The Dart side is frozen (MethodChannelModelBackend on
// org.moeru.airi/anima/model/<kind>); this header is its native counterpart.
// Dart never sees vertices, draws or pages — only the opaque `uint32_t
// texture_id` returned by `airi_render_load`.
//
// Lifecycle:
//   airi_render_create(kind) -> airi_render_load -> (setLipSync | setEmotion |
//   setAmbientPhase | render)* -> airi_render_dispose -> airi_render_destroy
//
// Threading: one backend instance is confined to one render thread. The
// closures registered at create time are the platform's texture registry; the
// backend never fabricates texture ids.
//
// Error handling: functions returning int32_t use 0 for success and nonzero
// for failure; airi_render_last_error returns a NUL-terminated message owned by
// the backend and valid until the next mutating call on the same handle.
#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Opaque backend instance (one per model kind, created by the platform).
struct airi_render_backend;

// Frozen ModelKind wire indices (mirror BackendKind in Rust and ModelKind in
// Dart). Do not reorder.
#define AIRI_RENDER_KIND_VRM 0
#define AIRI_RENDER_KIND_SPINE 1
#define AIRI_RENDER_KIND_MMD 2
#define AIRI_RENDER_KIND_LIVE2D 3

// Opaque model handle: the native identity of one loaded model. `texture_id`
// is the GPU/PlatformView texture the platform minted; Dart only ever sees
// this integer. AIRI_RENDER_NO_TEXTURE means "no output texture yet".
#define AIRI_RENDER_NO_TEXTURE UINT32_MAX

typedef struct {
    uint64_t id;
    uint32_t texture_id;
} airi_render_handle;

// Texture pixel layout (mirror TextureFormat).
#define AIRI_RENDER_TEX_RGBA8 0

// One uploaded texture page. `pixels` holds width*height*4 row-major bytes.
typedef struct {
    const char *name;
    uint32_t width;
    uint32_t height;
    int32_t format;
    int32_t premultiplied_alpha;
    const uint8_t *pixels;
    size_t pixels_len;
} airi_render_page;

// Blend modes (mirror BlendMode). Do not reorder.
#define AIRI_RENDER_BLEND_NORMAL 0
#define AIRI_RENDER_BLEND_ADDITIVE 1
#define AIRI_RENDER_BLEND_MULTIPLY 2
#define AIRI_RENDER_BLEND_SCREEN 3

// One textured vertex (world space; z is 0 for flat 2D scenes).
typedef struct {
    float x, y, z, u, v;
} airi_render_vertex;

// One draw range indexing into the frame's vertex/index/page buffers.
typedef struct {
    uint32_t page;
    int32_t blend;
    float alpha;
    uint32_t vertex_offset;
    uint32_t vertex_count;
    uint32_t index_offset;
    uint32_t index_count;
} airi_render_draw;

/* Lifecycle ---------------------------------------------------------- */

// Create a backend for `kind` (one of AIRI_RENDER_KIND_*). `register_texture`
// mints an opaque texture id for a (width,height) page and returns it;
// `release_texture` frees one. Both are the platform's and must outlive the
// backend. Never returns NULL.
struct airi_render_backend *airi_render_create(
    int32_t kind,
    uint32_t (*register_texture)(void *ctx, uint32_t width, uint32_t height),
    void (*release_texture)(void *ctx, uint32_t texture_id),
    void *ctx);

// Destroy a backend and every remaining handle. Safe on NULL; idempotent.
void airi_render_destroy(struct airi_render_backend *backend);

/* Loading ------------------------------------------------------------ */

// Load the model at `asset_path` (a local file or bundle root, NUL-terminated
// UTF-8). On success writes the handle to `out_handle` and returns 0; on
// failure returns nonzero and fills airi_render_last_error.
int32_t airi_render_load(struct airi_render_backend *backend,
                         const char *asset_path,
                         airi_render_handle *out_handle);

// Message for the last failed call on this backend ("" when none).
const char *airi_render_last_error(struct airi_render_backend *backend);

/* Per-frame ---------------------------------------------------------- */

// Upload the model's texture pages (call once after load). Writes the page
// count to `out_count`; `out_pages` must hold at least that many. Returns 0 on
// success.
int32_t airi_render_pages(struct airi_render_backend *backend,
                          airi_render_handle handle,
                          airi_render_page *out_pages,
                          size_t page_cap,
                          size_t *out_count);

// Fill counts for the next render; the caller sizes its buffers from these.
void airi_render_frame_counts(struct airi_render_backend *backend,
                              airi_render_handle handle,
                              size_t *out_vertices,
                              size_t *out_indices,
                              size_t *out_draws);

// Advance by `delta_seconds` and serialize one frame. Buffers must hold at
// least the counts from airi_render_frame_counts. Returns 0 on success.
int32_t airi_render_render(struct airi_render_backend *backend,
                           airi_render_handle handle,
                           float delta_seconds,
                           airi_render_vertex *out_vertices,
                           size_t vertex_cap,
                           uint32_t *out_indices,
                           size_t index_cap,
                           airi_render_draw *out_draws,
                           size_t draw_cap);

/* Sinks -------------------------------------------------------------- */

// Set a continuous mouth-open weight in [0, 1].
int32_t airi_render_set_lip_sync(struct airi_render_backend *backend,
                                 airi_render_handle handle,
                                 float weight);

// Apply one expression/motion cue by semantic tag.
int32_t airi_render_set_emotion(struct airi_render_backend *backend,
                                airi_render_handle handle,
                                const char *tag,
                                const char *kind,
                                float intensity);

// Set a continuous idle/ambient motion phase in [0, 1].
int32_t airi_render_set_ambient_phase(struct airi_render_backend *backend,
                                      airi_render_handle handle,
                                      float phase);

// Release all native resources for `handle` and free its texture. Idempotent.
int32_t airi_render_dispose(struct airi_render_backend *backend,
                            airi_render_handle handle);

// Read back the last sink values applied to a handle (for diagnostics/tests).
// Returns 0 on success; `out_*` may be NULL. `out_tag`/`out_kind` are
// NUL-terminated and owned by the backend until the next mutating call.
int32_t airi_render_get_lip_sync(struct airi_render_backend *backend, airi_render_handle handle, float *out_weight);
int32_t airi_render_get_emotion(struct airi_render_backend *backend, airi_render_handle handle, const char **out_tag, const char **out_kind, float *out_intensity);
int32_t airi_render_get_ambient_phase(struct airi_render_backend *backend, airi_render_handle handle, float *out_phase);

#ifdef __cplusplus
} /* extern "C" */
#endif