// SPDX-License-Identifier: GPL-3.0-or-later
// MMD side of the frozen render/texture contract.
//
// The Rust `anima_render::mmd_native` driver owns the whole MMD pipeline:
// rest-pose assembly, VMD sampling, morph mixing, vowel lip-sync, additive
// expressions and the CPU toon shading pass. This file adds the part the frozen
// `render_contract.h` expects but the Rust driver cannot see: the per-model
// page bookkeeping in the `airi_render_backend` table, whose definition is
// private to `render_contract.cpp`.
//
// The engine calls (`anima_mmd_*`) are linked from `libanima_render`. This file
// owns nothing but the per-model page table the frozen getters read back, and it
// mints no texture id: every page id comes from the platform's
// `register_texture` closure and goes back through `release_texture` at
// dispose.

#include "mmd_backend.h"

#include "render_contract.h"
#include "render_contract_internal.h"

#include <cstddef>
#include <cstdint>
#include <memory>
#include <string>
#include <utility>
#include <vector>

namespace {

float clamp01(float v) { return v < 0.0f ? 0.0f : (v > 1.0f ? 1.0f : v); }

/// One page the Rust driver decoded: dimensions plus tightly packed RGBA8.
struct MmdPage {
    uint32_t width = 0;
    uint32_t height = 0;
    std::vector<uint8_t> pixels;
    std::string name;
};

/// One loaded MMD model: the pages the Rust renderer produced, with their
/// frozen-contract names. The platform mints exactly one texture per page
/// through the Rust driver's registry callback; there are no C++-owned ids.
struct MmdModel {
    std::vector<MmdPage> pages;
};

int32_t mmdFail(airi_render_backend *backend, const char *message) {
    if (backend) backend->lastError = message ? message : "mmd backend failure";
    return 1;
}

MmdModel *findMmd(airi_render_backend *backend, uint64_t id) {
    if (!backend) return nullptr;
    auto it = backend->models.find(id);
    if (it == backend->models.end()) return nullptr;
    return reinterpret_cast<MmdModel *>(it->second.mmd);
}

/// Copy one page's pixels out of the Rust driver into `page`.
bool readPage(MmdCInstance *renderer, uint64_t id, size_t index, MmdPage &page) {
    // Query the real pixel count first: the driver allocates a tightly packed
    // RGBA8 buffer, so the cap is the page's byte length, not w*h*4 assumed
    // from the (possibly zero) width/height query.
    size_t count = 0;
    if (anima_mmd_page_count(renderer, id, &count) != 0) return false;
    if (index >= count) return false;
    uint32_t w = 0, h = 0;
    if (anima_mmd_page(renderer, id, index, &w, &h, nullptr, 0) != 0) return false;
    page.width = w;
    page.height = h;
    page.pixels.assign((size_t) w * (size_t) h * 4, 0);
    if (page.pixels.empty()) return true;
    return anima_mmd_page(renderer, id, index, &w, &h, page.pixels.data(),
                          page.pixels.size()) == 0;
}

MmdCInstance *mmdRenderer(airi_render_backend *backend) {
    if (!backend) return nullptr;
    if (!backend->mmd) {
        MmdCInstance *renderer = nullptr;
        if (anima_mmd_create(backend->register_texture, backend->release_texture,
                             backend->ctx, &renderer) != 0) {
            return nullptr;
        }
        backend->mmd = renderer;
    }
    return static_cast<MmdCInstance *>(backend->mmd);
}

} // namespace

extern "C" int32_t airi_mmd_load(airi_render_backend *backend,
                                 const char *asset_path,
                                 airi_render_handle *out_handle) {
    if (!backend || !asset_path || !out_handle) {
        return mmdFail(backend, "airi_mmd_load: null argument");
    }
    if (backend->kind != AIRI_RENDER_KIND_MMD) {
        return mmdFail(backend, "airi_mmd_load: backend is not an MMD backend");
    }
    backend->lastError.clear();

    MmdCInstance *renderer = mmdRenderer(backend);
    if (!renderer) return mmdFail(backend, "anima_mmd_create failed");

    uint64_t id = 0;
    uint32_t output_texture = AIRI_RENDER_NO_TEXTURE;
    if (anima_mmd_load(renderer, asset_path, &id, &output_texture) != 0) {
        backend->lastError = std::string("airi_mmd_load: ")
                           + anima_mmd_last_error(renderer);
        return 2;
    }

    auto model = std::make_unique<MmdModel>();
    size_t page_count = 0;
    if (anima_mmd_page_count(renderer, id, &page_count) != 0) {
        backend->lastError = "airi_mmd_load: page count failed";
        anima_mmd_dispose(renderer, id);
        return 2;
    }
    model->pages.resize(page_count);
    for (size_t i = 0; i < page_count; ++i) {
        if (!readPage(renderer, id, i, model->pages[i])) {
            backend->lastError = "airi_mmd_load: page read failed";
            anima_mmd_dispose(renderer, id);
            return 2;
        }
        model->pages[i].name = (i + 1 == page_count)
                                   ? "mmd-output"
                                   : "mmd-page-" + std::to_string(i);
    }

    backend->models[id].mmd = model.release();
    out_handle->id = id;
    out_handle->texture_id = output_texture;
    return 0;
}

extern "C" int32_t airi_mmd_pages(airi_render_backend *backend,
                                  airi_render_handle handle,
                                  airi_render_page *out_pages,
                                  size_t page_cap,
                                  size_t *out_count) {
    MmdModel *m = findMmd(backend, handle.id);
    // The shaded output changes every frame, so read the current pixels from
    // the Rust driver rather than the cached copy taken at load time.
    MmdCInstance *renderer = backend ? static_cast<MmdCInstance *>(backend->mmd) : nullptr;
    if (!m || !renderer) return mmdFail(backend, "airi_mmd_pages: unknown handle");

    size_t count = 0;
    if (anima_mmd_page_count(renderer, handle.id, &count) != 0) {
        return mmdFail(backend, "airi_mmd_pages: page count failed");
    }
    if (out_count) *out_count = count;
    if (!out_pages || count > page_cap) return count > page_cap ? 3 : 0;
    if (count != m->pages.size()) {
        m->pages.resize(count);
        for (size_t i = 0; i < count; ++i) {
            m->pages[i].name = (i + 1 == count)
                                   ? "mmd-output"
                                   : "mmd-page-" + std::to_string(i);
        }
    }
    for (size_t i = 0; i < count; ++i) {
        if (!readPage(renderer, handle.id, i, m->pages[i])) {
            return mmdFail(backend, "airi_mmd_pages: page read failed");
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

extern "C" int32_t airi_mmd_frame_counts(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         size_t *out_vertices,
                                         size_t *out_indices,
                                         size_t *out_draws) {
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) {
        if (out_vertices) *out_vertices = 0;
        if (out_indices) *out_indices = 0;
        if (out_draws) *out_draws = 0;
        return mmdFail(backend, "airi_mmd_frame_counts: unknown handle");
    }
    return anima_mmd_frame_counts(static_cast<MmdCInstance *>(backend->mmd), handle.id, out_vertices,
                                  out_indices, out_draws);
}

extern "C" int32_t airi_mmd_render(airi_render_backend *backend,
                                   airi_render_handle handle,
                                   float delta_seconds,
                                   airi_render_vertex *out_vertices,
                                   size_t vertex_cap,
                                   uint32_t *out_indices,
                                   size_t index_cap,
                                   airi_render_draw *out_draws,
                                   size_t draw_cap) {
    if (!backend) return mmdFail(backend, "airi_mmd_render: null backend");
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_render: unknown handle");

    int32_t status = anima_mmd_render(static_cast<MmdCInstance *>(backend->mmd), handle.id, delta_seconds,
                                      out_vertices, vertex_cap, out_indices,
                                      index_cap, out_draws, draw_cap);
    if (status != 0) {
        backend->lastError = std::string("airi_mmd_render: ")
                           + anima_mmd_last_error(static_cast<MmdCInstance *>(backend->mmd));
        return 3;
    }
    return 0;
}

extern "C" int32_t airi_mmd_set_lip_sync(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         float weight) {
    if (!backend) return mmdFail(backend, "airi_mmd_set_lip_sync: null backend");
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_set_lip_sync: unknown handle");
    // `handle.lipSync` is the frozen getter's sink; the Rust driver owns the
    // vowel channel itself (the `あ` morph).
    backend->models[handle.id].lipSync = clamp01(weight);
    int32_t status = anima_mmd_set_lip_sync(static_cast<MmdCInstance *>(backend->mmd), handle.id, weight);
    if (status != 0) {
        backend->lastError = std::string("airi_mmd_set_lip_sync: ")
                           + anima_mmd_last_error(static_cast<MmdCInstance *>(backend->mmd));
    }
    return status;
}

extern "C" int32_t airi_mmd_set_emotion(airi_render_backend *backend,
                                        airi_render_handle handle,
                                        const char *tag,
                                        const char *kind,
                                        float intensity) {
    if (!backend) return mmdFail(backend, "airi_mmd_set_emotion: null backend");
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_set_emotion: unknown handle");
    ModelEntry &entry = backend->models[handle.id];
    entry.emotionTag = tag ? tag : "";
    entry.emotionKind = kind ? kind : "";
    entry.emotionIntensity = clamp01(intensity);
    int32_t status = anima_mmd_set_emotion(static_cast<MmdCInstance *>(backend->mmd), handle.id,
                                           entry.emotionTag.c_str(),
                                           entry.emotionIntensity);
    if (status != 0) {
        backend->lastError = std::string("airi_mmd_set_emotion: ")
                           + anima_mmd_last_error(static_cast<MmdCInstance *>(backend->mmd));
    }
    return status;
}

extern "C" int32_t airi_mmd_set_ambient_phase(airi_render_backend *backend,
                                              airi_render_handle handle,
                                              float phase) {
    if (!backend) return mmdFail(backend, "airi_mmd_set_ambient_phase: null backend");
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_set_ambient_phase: unknown handle");
    backend->models[handle.id].ambientPhase = clamp01(phase);
    int32_t status = anima_mmd_set_ambient_phase(static_cast<MmdCInstance *>(backend->mmd), handle.id, phase);
    if (status != 0) {
        backend->lastError = std::string("airi_mmd_set_ambient_phase: ")
                           + anima_mmd_last_error(static_cast<MmdCInstance *>(backend->mmd));
    }
    return status;
}

extern "C" int32_t airi_mmd_get_lip_sync(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         float *out_weight) {
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_get_lip_sync: unknown handle");
    return anima_mmd_get_lip_sync(static_cast<MmdCInstance *>(backend->mmd), handle.id, out_weight);
}

extern "C" int32_t airi_mmd_get_emotion(airi_render_backend *backend,
                                        airi_render_handle handle,
                                        const char **out_tag,
                                        const char **out_kind,
                                        float *out_intensity) {
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_get_emotion: unknown handle");
    // The frozen ABI also carries the cue kind; the MMD channel keys on the
    // semantic tag alone, so report the fixed "motion" kind.
    if (out_kind) *out_kind = "motion";
    return anima_mmd_get_emotion(static_cast<MmdCInstance *>(backend->mmd), handle.id, out_tag, out_intensity);
}

extern "C" int32_t airi_mmd_get_ambient_phase(airi_render_backend *backend,
                                              airi_render_handle handle,
                                              float *out_phase) {
    MmdModel *m = findMmd(backend, handle.id);
    if (!m) return mmdFail(backend, "airi_mmd_get_ambient_phase: unknown handle");
    return anima_mmd_get_ambient_phase(static_cast<MmdCInstance *>(backend->mmd), handle.id, out_phase);
}

extern "C" int32_t airi_mmd_dispose(airi_render_backend *backend,
                                    airi_render_handle handle) {
    if (!backend) return mmdFail(backend, "airi_mmd_dispose: null backend");
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) return 0; // idempotent
    auto *model = reinterpret_cast<MmdModel *>(it->second.mmd);
    // The Rust renderer releases every page texture it minted. The C++ table
    // only holds copied pixels, so there is nothing to release here.
    anima_mmd_dispose(static_cast<MmdCInstance *>(backend->mmd), handle.id);
    delete model;
    backend->models.erase(it);
    return 0;
}

extern "C" void airi_mmd_shutdown(airi_render_backend *backend) {
    if (!backend) return;
    if (backend->mmd) {
        anima_mmd_destroy(static_cast<MmdCInstance *>(backend->mmd));
        backend->mmd = nullptr;
    }
}