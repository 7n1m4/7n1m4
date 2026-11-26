// SPDX-License-Identifier: GPL-3.0-or-later
// C++ side of the frozen render/texture contract: VRM page reads and the
// airi_vrm_* dispatch. The Rust `anima_render::vrm_native` driver owns the
// whole VRM pipeline (skinning, morph blending, spring bones, gaze/lip-sync,
// additive expressions and the CPU ton shading pass). What the C++ side adds
// is the per-model page bookkeeping the frozen contract expects but the Rust
// driver cannot see.

#include "vrm_backend.h"

#include "render_contract.h"
#include "render_contract_internal.h"

#include <cmath>
#include <cstdint>
#include <cstring>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

/// One page the Rust driver decoded: dimensions plus tightly packed RGBA8.
struct VrmPage {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels;
    std::string name;
};

/// One loaded VRM model: the pages the Rust renderer produced, with their
/// frozen-contract names. The platform mints exactly one texture per page
/// through the Rust driver's registry callback; there are no C++-owned ids.
struct VrmModel {
    std::vector<VrmPage> pages;
};

int32_t vrmFail(airi_render_backend *backend, const char *message) {
    if (backend) backend->lastError = message ? message : "vrm backend failure";
    return 1;
}

VrmModel *findVrm(airi_render_backend *backend, uint64_t id) {
    if (!backend) return nullptr;
    auto it = backend->models.find(id);
    if (it == backend->models.end()) return nullptr;
    return reinterpret_cast<VrmModel *>(it->second.vrm);
}

void destroyVrm(VrmModel *model) {
    delete model;
}

/// Copy one page's pixels out of the Rust driver into `page`.
bool readPage(VrmCInstance *renderer, uint64_t id, size_t index, VrmPage &page) {
    // Query the real pixel count first: the driver allocates a tightly packed
    // RGBA8 buffer, so the cap is the page's byte length, not w*h*4 assumed
    // from the (possibly zero) width/height query.
    size_t count = 0;
    if (anima_vrm_page_count(renderer, id, &count) != 0) return false;
    if (index >= count) return false;
    uint32_t w = 0, h = 0;
    if (anima_vrm_page(renderer, id, index, &w, &h, nullptr, 0) != 0) return false;
    page.width = w;
    page.height = h;
    page.pixels.assign((size_t) w * (size_t) h * 4, 0);
    if (page.pixels.empty()) return true;
    return anima_vrm_page(renderer, id, index, &w, &h, page.pixels.data(),
                          page.pixels.size()) == 0;
}

} // namespace

VrmCInstance *vrmRenderer(airi_render_backend *backend) {
    if (!backend) return nullptr;
    if (!backend->vrm) {
        VrmCInstance *renderer = nullptr;
        if (anima_vrm_create(backend->register_texture, backend->release_texture,
                             backend->ctx, &renderer) != 0) {
            return nullptr;
        }
        backend->vrm = renderer;
    }
    return static_cast<VrmCInstance *>(backend->vrm);
}

extern "C" int32_t airi_vrm_load(airi_render_backend *backend,
                                 const char *asset_path,
                                 airi_render_handle *out_handle) {
    if (!backend || !asset_path || !out_handle) {
        return vrmFail(backend, "airi_vrm_load: null argument");
    }
    if (backend->kind != AIRI_RENDER_KIND_VRM) {
        return vrmFail(backend, "airi_vrm_load: backend is not a VRM backend");
    }
    backend->lastError.clear();

    VrmCInstance *renderer = vrmRenderer(backend);
    if (!renderer) return vrmFail(backend, "anima_vrm_create failed");

    uint64_t id = 0;
    uint32_t output_texture = AIRI_RENDER_NO_TEXTURE;
    if (anima_vrm_load(renderer, asset_path, &id, &output_texture) != 0) {
        backend->lastError = std::string("airi_vrm_load: ")
                           + anima_vrm_last_error(renderer);
        return 2;
    }

    auto model = std::make_unique<VrmModel>();
    size_t page_count = 0;
    if (anima_vrm_page_count(renderer, id, &page_count) != 0) {
        backend->lastError = "airi_vrm_load: page count failed";
        anima_vrm_dispose(renderer, id);
        return 2;
    }
    model->pages.resize(page_count);
    for (size_t i = 0; i < page_count; ++i) {
        if (!readPage(renderer, id, i, model->pages[i])) {
            backend->lastError = "airi_vrm_load: page read failed";
            anima_vrm_dispose(renderer, id);
            return 2;
        }
        // Names mirror the Rust driver's page order (base colours, then the
        // shaded output) so callers can identify the surface they are reading.
        model->pages[i].name = (i + 1 == page_count)
                                   ? "vrm-output"
                                   : "vrm-page-" + std::to_string(i);
    }

    backend->models[id].vrm = model.release();
    out_handle->id = id;
    out_handle->texture_id = output_texture;
    return 0;
}

extern "C" int32_t airi_vrm_pages(airi_render_backend *backend,
                                  airi_render_handle handle,
                                  airi_render_page *out_pages,
                                  size_t page_cap,
                                  size_t *out_count) {
    VrmModel *m = findVrm(backend, handle.id);
    // The shaded output changes every frame, so read the current pixels from
    // the Rust driver rather than the cached copy taken at load time.
    VrmCInstance *renderer = backend ? static_cast<VrmCInstance *>(backend->vrm) : nullptr;
    if (!m || !renderer) return vrmFail(backend, "airi_vrm_pages: unknown handle");

    size_t count = 0;
    if (anima_vrm_page_count(renderer, handle.id, &count) != 0) {
        return vrmFail(backend, "airi_vrm_pages: page count failed");
    }
    if (out_count) *out_count = count;
    // A sizing call (null output) must not fail just because the C++ cache is
    // shorter than the live page list.
    if (!out_pages || count > page_cap) return count > page_cap ? 3 : 0;
    if (count != m->pages.size()) {
        m->pages.resize(count);
        for (size_t i = 0; i < count; ++i) {
            m->pages[i].name = (i + 1 == count)
                                   ? "vrm-output"
                                   : "vrm-page-" + std::to_string(i);
        }
    }
    for (size_t i = 0; i < count; ++i) {
        if (!readPage(renderer, handle.id, i, m->pages[i])) {
            return vrmFail(backend, "airi_vrm_pages: page read failed");
        }
        airi_render_page page{};
        page.name = m->pages[i].name.c_str();
        page.width = m->pages[i].width;
        page.height = m->pages[i].height;
        page.format = AIRI_RENDER_TEX_RGBA8;
        page.premultiplied_alpha = 0;
        page.pixels = m->pages[i].pixels.data();
        page.pixels_len = m->pages[i].pixels.size();
        out_pages[i] = page;
    }
    return 0;
}

extern "C" int32_t airi_vrm_frame_counts(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         size_t *out_vertices,
                                         size_t *out_indices,
                                         size_t *out_draws) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) {
        if (out_vertices) *out_vertices = 0;
        if (out_indices) *out_indices = 0;
        if (out_draws) *out_draws = 0;
        return vrmFail(backend, "airi_vrm_frame_counts: unknown handle");
    }
    return anima_vrm_frame_counts(static_cast<VrmCInstance *>(backend->vrm), handle.id, out_vertices,
                                  out_indices, out_draws);
}

extern "C" int32_t airi_vrm_render(airi_render_backend *backend,
                                   airi_render_handle handle,
                                   float delta_seconds,
                                   airi_render_vertex *out_vertices,
                                   size_t vertex_cap,
                                   uint32_t *out_indices,
                                   size_t index_cap,
                                   airi_render_draw *out_draws,
                                   size_t draw_cap) {
    if (!backend) return vrmFail(backend, "airi_vrm_render: null backend");
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_render: unknown handle");

    int32_t status = anima_vrm_render(static_cast<VrmCInstance *>(backend->vrm), handle.id, delta_seconds,
                                      out_vertices, vertex_cap, out_indices,
                                      index_cap, out_draws, draw_cap);
    if (status != 0) {
        backend->lastError = std::string("airi_vrm_render: ")
                           + anima_vrm_last_error(static_cast<VrmCInstance *>(backend->vrm));
        return 3;
    }
    return 0;
}

extern "C" int32_t airi_vrm_set_lip_sync(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         float weight) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_set_lip_sync: unknown handle");
    return anima_vrm_set_lip_sync(static_cast<VrmCInstance *>(backend->vrm), handle.id, clamp01(weight));
}

extern "C" int32_t airi_vrm_set_emotion(airi_render_backend *backend,
                                        airi_render_handle handle,
                                        const char *tag,
                                        const char *kind,
                                        float intensity) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_set_emotion: unknown handle");
    (void) kind; // the Rust driver keys expressions by tag alone
    return anima_vrm_set_emotion(static_cast<VrmCInstance *>(backend->vrm), handle.id, tag, clamp01(intensity));
}

extern "C" int32_t airi_vrm_set_ambient_phase(airi_render_backend *backend,
                                              airi_render_handle handle,
                                              float phase) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_set_ambient_phase: unknown handle");
    return anima_vrm_set_ambient_phase(static_cast<VrmCInstance *>(backend->vrm), handle.id, phase);
}

extern "C" int32_t airi_vrm_get_lip_sync(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         float *out_weight) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_get_lip_sync: unknown handle");
    return anima_vrm_get_lip_sync(static_cast<VrmCInstance *>(backend->vrm), handle.id, out_weight);
}

extern "C" int32_t airi_vrm_get_emotion(airi_render_backend *backend,
                                        airi_render_handle handle,
                                        const char **out_tag,
                                        const char **out_kind,
                                        float *out_intensity) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_get_emotion: unknown handle");
    const char *tag = nullptr;
    float intensity = 0.0f;
    int32_t status = anima_vrm_get_emotion(static_cast<VrmCInstance *>(backend->vrm), handle.id, &tag, &intensity);
    if (status != 0) return status;
    if (out_tag) *out_tag = tag;
    if (out_kind) *out_kind = "motion";
    if (out_intensity) *out_intensity = intensity;
    return 0;
}

extern "C" int32_t airi_vrm_get_ambient_phase(airi_render_backend *backend,
                                              airi_render_handle handle,
                                              float *out_phase) {
    VrmModel *m = findVrm(backend, handle.id);
    if (!m) return vrmFail(backend, "airi_vrm_get_ambient_phase: unknown handle");
    return anima_vrm_get_ambient_phase(static_cast<VrmCInstance *>(backend->vrm), handle.id, out_phase);
}

extern "C" int32_t airi_vrm_dispose(airi_render_backend *backend,
                                    airi_render_handle handle) {
    if (!backend) return vrmFail(backend, "airi_vrm_dispose: null backend");
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) return 0; // idempotent
    auto *model = reinterpret_cast<VrmModel *>(it->second.vrm);
    // The Rust renderer releases every page texture it minted. The C++ table
    // only holds copied pixels, so there is nothing to release here.
    anima_vrm_dispose(static_cast<VrmCInstance *>(backend->vrm), handle.id);
    destroyVrm(model);
    backend->models.erase(it);
    return 0;
}

extern "C" void airi_vrm_shutdown(airi_render_backend *backend) {
    if (!backend) return;
    if (backend->vrm) {
        anima_vrm_destroy(static_cast<VrmCInstance *>(backend->vrm));
        backend->vrm = nullptr;
    }
}
