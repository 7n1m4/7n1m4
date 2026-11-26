// SPDX-License-Identifier: GPL-3.0-or-later
// Implementation of the frozen render/texture C ABI (render_contract.h).
//
// This file is the per-OS-agnostic part of the contract: it owns the backend
// table and dispatches to a concrete renderer registered beneath it. The first
// concrete renderer is the spine-cpp backend in spine_shell.{h,cpp}; 3D
// backends (VRM/MMD) register the same way. The GPU layer (texture mint /
// release) is injected by the platform at airi_render_create and never
// fabricated here, so Dart only ever holds the opaque texture_id.

#include "render_contract.h"
#include "render_contract_internal.h"
#include "vrm_backend.h"
#include "mmd_backend.h"

// The VRM backend's per-model state, defined in vrm_backend.cpp.
struct VrmModel;

#include "spine_shell.h"

#include <cstdio>
#include <cstring>
#include <utility>
#include <vector>

namespace {
airi_render_handle make_handle(airi_render_backend *b, uint32_t texture_id) {
    airi_render_handle h{};
    h.id = b->nextId++;
    h.texture_id = texture_id;
    return h;
}

static bool readFile(const char *path, std::vector<uint8_t> &out) {
    FILE *f = std::fopen(path, "rb");
    if (!f) return false;
    std::fseek(f, 0, SEEK_END);
    long sz = std::ftell(f);
    std::fseek(f, 0, SEEK_SET);
    if (sz < 0) { std::fclose(f); return false; }
    out.resize((size_t) sz);
    if (sz > 0 && std::fread(out.data(), 1, (size_t) sz, f) != (size_t) sz) {
        std::fclose(f);
        out.clear();
        return false;
    }
    std::fclose(f);
    return true;
}

static uint32_t rdU32(const uint8_t *p) {
    return (uint32_t) p[0] | ((uint32_t) p[1] << 8) |
           ((uint32_t) p[2] << 16) | ((uint32_t) p[3] << 24);
}

static float clamp01(float v) {
    if (v < 0.0f) return 0.0f;
    if (v > 1.0f) return 1.0f;
    return v;
}
} // namespace

extern "C" airi_render_backend *airi_render_create(
    int32_t kind,
    uint32_t (*register_texture)(void *ctx, uint32_t width, uint32_t height),
    void (*release_texture)(void *ctx, uint32_t texture_id),
    void *ctx) {
    auto *b = new airi_render_backend();
    b->kind = kind;
    b->register_texture = register_texture;
    b->release_texture = release_texture;
    b->ctx = ctx;
    return b;
}

extern "C" void airi_render_destroy(airi_render_backend *backend) {
    if (!backend) return;
    for (auto &kv : backend->models) {
        if (backend->release_texture) {
            for (uint32_t id : kv.second.texture_ids) {
                backend->release_texture(backend->ctx, id);
            }
        }
        airi_spine_destroy(kv.second.session);
    }
    airi_vrm_shutdown(backend);
    airi_mmd_shutdown(backend);
    delete backend;
}

extern "C" int32_t airi_render_load(airi_render_backend *backend,
                                    const char *asset_path,
                                    airi_render_handle *out_handle) {
    if (!backend || !asset_path || !out_handle) {
        if (backend) backend->lastError = "airi_render_load: null argument";
        return 1;
    }
    backend->lastError.clear();
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        // The VRM driver owns its own per-model state, page ids and sink
        // read-back; the frozen signature and the Spine path are unchanged.
        airi_render_handle vrm_handle{};
        int32_t vrm_status = airi_vrm_load(backend, asset_path, &vrm_handle);
        if (vrm_status == 0) *out_handle = vrm_handle;
        return vrm_status;
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        airi_render_handle mmd_handle{};
        int32_t mmd_status = airi_mmd_load(backend, asset_path, &mmd_handle);
        if (mmd_status == 0) *out_handle = mmd_handle;
        return mmd_status;
    }
    if (backend->kind != AIRI_RENDER_KIND_SPINE) {
        // Every other kind still has no native backend.
        backend->lastError =
            "airi_render_load: no native backend for this model kind yet";
        return 2;
    }

    std::vector<uint8_t> data;
    if (!readFile(asset_path, data)) {
        backend->lastError = "airi_render_load: cannot read bundle";
        return 1;
    }
    // Reaching here means the kind is SPINE (the only remaining branch).
    if (data.empty() || data[0] != (uint8_t) AIRI_RENDER_KIND_SPINE) {
        backend->lastError = "airi_render_load: bad bundle kind";
        return 1;
    }
    size_t pos = 1;
    if (pos + 1 > data.size()) { backend->lastError = "airi_render_load: truncated"; return 1; }
    uint8_t skel_is_binary = data[pos++];
    if (pos + 4 > data.size()) { backend->lastError = "airi_render_load: truncated"; return 1; }
    uint32_t skel_len = rdU32(data.data() + pos); pos += 4;
    if (pos + skel_len > data.size()) { backend->lastError = "airi_render_load: truncated"; return 1; }
    const uint8_t *skel_data = data.data() + pos;
    pos += skel_len;
    if (pos + 4 > data.size()) { backend->lastError = "airi_render_load: truncated"; return 1; }
    uint32_t atlas_len = rdU32(data.data() + pos); pos += 4;
    if (pos + atlas_len > data.size()) { backend->lastError = "airi_render_load: truncated"; return 1; }
    const char *atlas_data = (const char *) (data.data() + pos);
    pos += atlas_len;

    airi_spine_session *session = airi_spine_create();
    if (airi_spine_load(session, skel_data, skel_len, skel_is_binary != 0,
                        atlas_data, atlas_len) == 0) {
        const char *err = airi_spine_last_error(session);
        backend->lastError = err ? err : "airi_spine_load failed";
        airi_spine_destroy(session);
        return 1;
    }

    size_t count = airi_spine_page_count(session);
    ModelEntry entry{};
    entry.session = session;
    uint32_t first_tex = 0;
    for (size_t i = 0; i < count; ++i) {
        uint32_t page_w = 0, page_h = 0;
        airi_spine_page_size(session, i, &page_w, &page_h);
        uint32_t tid = backend->register_texture
            ? backend->register_texture(backend->ctx, page_w, page_h) : 0;
        entry.texture_ids.push_back(tid);
        if (i == 0) first_tex = tid;
    }
    uint64_t id = backend->nextId++;
    backend->models[id] = std::move(entry);
    airi_render_handle h{};
    h.id = id;
    h.texture_id = first_tex;
    *out_handle = h;
    return 0;
}

extern "C" const char *airi_render_last_error(airi_render_backend *backend) {
    return backend ? backend->lastError.c_str() : "";
}

extern "C" int32_t airi_render_pages(airi_render_backend *backend,
                                     airi_render_handle handle,
                                     airi_render_page *out_pages,
                                     size_t page_cap,
                                     size_t *out_count) {
    if (!backend || !out_count) return 1;
    // VRM/MMD models live in their own per-kind tables, not `models` (which
    // is Spine-only). Dispatch before looking up a Spine session.
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_pages(backend, handle, out_pages, page_cap, out_count);
    }
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_pages(backend, handle, out_pages, page_cap, out_count);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        backend->lastError = "airi_render_pages: unknown handle";
        return 2;
    }
    size_t count = airi_spine_page_count(it->second.session);
    if (out_count) *out_count = count;
    if (count > page_cap) return 3;
    for (size_t i = 0; i < count; ++i) {
        airi_render_page page{};
        page.name = airi_spine_page_image(it->second.session, i);
        page.format = AIRI_RENDER_TEX_RGBA8;
        page.premultiplied_alpha = airi_spine_page_pma(it->second.session, i);
        airi_spine_page_size(it->second.session, i, &page.width, &page.height);
        out_pages[i] = page;
    }
    return 0;
}

extern "C" void airi_render_frame_counts(airi_render_backend *backend,
                                         airi_render_handle handle,
                                         size_t *out_vertices,
                                         size_t *out_indices,
                                         size_t *out_draws) {
    // The VRM driver owns the per-model geometry, so the counters must come
    // from airi_vrm_frame_counts; only the Spine table is reachable below.
    if (backend && backend->kind == AIRI_RENDER_KIND_VRM) {
        airi_vrm_frame_counts(backend, handle, out_vertices, out_indices, out_draws);
        return;
    }
    if (backend && backend->kind == AIRI_RENDER_KIND_MMD) {
        airi_mmd_frame_counts(backend, handle, out_vertices, out_indices, out_draws);
        return;
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        if (out_vertices) *out_vertices = 0;
        if (out_indices) *out_indices = 0;
        if (out_draws) *out_draws = 0;
        return;
    }
    airi_spine_draw_counts(it->second.session, out_vertices, out_indices,
                           out_draws);
}

extern "C" int32_t airi_render_render(airi_render_backend *backend,
                                      airi_render_handle handle,
                                      float delta_seconds,
                                      airi_render_vertex *out_vertices,
                                      size_t vertex_cap,
                                      uint32_t *out_indices,
                                      size_t index_cap,
                                      airi_render_draw *out_draws,
                                      size_t draw_cap) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_render(backend, handle, delta_seconds, out_vertices,
                               vertex_cap, out_indices, index_cap, out_draws,
                               draw_cap);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_render(backend, handle, delta_seconds, out_vertices,
                               vertex_cap, out_indices, index_cap, out_draws,
                               draw_cap);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        backend->lastError = "airi_render_render: unknown handle";
        return 2;
    }
    airi_spine_update(it->second.session, delta_seconds);

    size_t nv = 0, ni = 0, nd = 0;
    airi_spine_draw_counts(it->second.session, &nv, &ni, &nd);
    if (nv > vertex_cap || ni > index_cap || nd > draw_cap) return 3;

    std::vector<airi_spine_vertex> sv(nv);
    std::vector<uint16_t> si(ni);
    std::vector<airi_spine_draw> sd(nd);
    if (airi_spine_collect_draws(it->second.session, sv.data(), nv, si.data(),
                                 ni, sd.data(), nd) == 0) {
        backend->lastError = "airi_spine_collect_draws: size mismatch";
        return 4;
    }
    for (size_t i = 0; i < nv; ++i) {
        out_vertices[i].x = sv[i].x;
        out_vertices[i].y = sv[i].y;
        out_vertices[i].z = 0.0f;
        out_vertices[i].u = sv[i].u;
        out_vertices[i].v = sv[i].v;
    }
    for (size_t i = 0; i < ni; ++i) out_indices[i] = si[i];
    for (size_t i = 0; i < nd; ++i) {
        out_draws[i].page = (uint32_t) sd[i].page_index;
        out_draws[i].blend = sd[i].blend_mode;
        out_draws[i].alpha = sd[i].alpha;
        out_draws[i].vertex_offset = sd[i].vertex_offset;
        out_draws[i].vertex_count = sd[i].vertex_count;
        out_draws[i].index_offset = sd[i].index_offset;
        out_draws[i].index_count = sd[i].index_count;
    }
    return 0;
}

extern "C" int32_t airi_render_set_lip_sync(airi_render_backend *backend,
                                            airi_render_handle handle,
                                            float weight) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_set_lip_sync(backend, handle, weight);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_set_lip_sync(backend, handle, weight);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        backend->lastError = "airi_render_set_lip_sync: unknown handle";
        return 2;
    }
    it->second.lipSync = clamp01(weight);
    airi_spine_set_lip_sync(it->second.session, it->second.lipSync);
    return 0;
}

extern "C" int32_t airi_render_set_emotion(airi_render_backend *backend,
                                           airi_render_handle handle,
                                           const char *tag,
                                           const char *kind,
                                           float intensity) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_set_emotion(backend, handle, tag, kind, intensity);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_set_emotion(backend, handle, tag, kind, intensity);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        backend->lastError = "airi_render_set_emotion: unknown handle";
        return 2;
    }
    it->second.emotionTag = tag ? tag : "";
    it->second.emotionKind = kind ? kind : "";
    it->second.emotionIntensity = clamp01(intensity);
    airi_spine_set_animation(it->second.session, 1, it->second.emotionTag.c_str(), 0);
    return 0;
}

extern "C" int32_t airi_render_set_ambient_phase(airi_render_backend *backend,
                                                 airi_render_handle handle,
                                                 float phase) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_set_ambient_phase(backend, handle, phase);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_set_ambient_phase(backend, handle, phase);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) {
        backend->lastError = "airi_render_set_ambient_phase: unknown handle";
        return 2;
    }
    it->second.ambientPhase = clamp01(phase);
    return 0;
}

extern "C" int32_t airi_render_dispose(airi_render_backend *backend,
                                       airi_render_handle handle) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_dispose(backend, handle);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_dispose(backend, handle);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) return 0; // idempotent
    if (backend->release_texture) {
        for (uint32_t id : it->second.texture_ids) {
            backend->release_texture(backend->ctx, id);
        }
    }
    airi_spine_destroy(it->second.session);
    backend->models.erase(it);
    return 0;
}

extern "C" int32_t airi_render_get_lip_sync(airi_render_backend *backend, airi_render_handle handle, float *out_weight) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        // Read the sink back from the native renderer, not the table copy.
        return airi_vrm_get_lip_sync(backend, handle, out_weight);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_get_lip_sync(backend, handle, out_weight);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) { backend->lastError = "airi_render_get_lip_sync: unknown handle"; return 2; }
    if (out_weight) *out_weight = it->second.lipSync;
    return 0;
}

extern "C" int32_t airi_render_get_emotion(airi_render_backend *backend, airi_render_handle handle, const char **out_tag, const char **out_kind, float *out_intensity) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_get_emotion(backend, handle, out_tag, out_kind,
                                    out_intensity);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_get_emotion(backend, handle, out_tag, out_kind,
                                    out_intensity);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) { backend->lastError = "airi_render_get_emotion: unknown handle"; return 2; }
    if (out_tag) *out_tag = it->second.emotionTag.c_str();
    if (out_kind) *out_kind = it->second.emotionKind.c_str();
    if (out_intensity) *out_intensity = it->second.emotionIntensity;
    return 0;
}

extern "C" int32_t airi_render_get_ambient_phase(airi_render_backend *backend, airi_render_handle handle, float *out_phase) {
    if (!backend) return 1;
    if (backend->kind == AIRI_RENDER_KIND_VRM) {
        return airi_vrm_get_ambient_phase(backend, handle, out_phase);
    }
    if (backend->kind == AIRI_RENDER_KIND_MMD) {
        return airi_mmd_get_ambient_phase(backend, handle, out_phase);
    }
    auto it = backend->models.find(handle.id);
    if (it == backend->models.end()) { backend->lastError = "airi_render_get_ambient_phase: unknown handle"; return 2; }
    if (out_phase) *out_phase = it->second.ambientPhase;
    return 0;
}