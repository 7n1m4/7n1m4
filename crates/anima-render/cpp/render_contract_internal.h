// SPDX-License-Identifier: GPL-3.0-or-later
// Private model table shared by the frozen contract and the VRM backend.
//
// `render_contract.h` is frozen: `airi_render_backend` stays opaque to callers.
// This header is the contract's own implementation detail, included only by
// `render_contract.cpp` and `vrm_backend.cpp`, so the VRM dispatch can reach the
// per-model slot without widening the public ABI.

#pragma once

#include "render_contract.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <unordered_map>
#include <vector>

struct airi_spine_session;

/// One loaded model's slot. Exactly one of `session` (Spine) or `vrm` (VRM) is
/// populated, chosen by the backend's kind; the sink fields are shared because
/// the frozen getters read them for every kind.
struct ModelEntry {
    airi_spine_session *session = nullptr;
    void *vrm = nullptr;
    /// Rust-side MMD renderer instance (kind == AIRI_RENDER_KIND_MMD).
    void *mmd = nullptr;
    /// Platform texture ids: one per page, in page order.
    std::vector<uint32_t> texture_ids;
    float lipSync = 0.0f;
    float ambientPhase = 0.0f;
    std::string emotionTag;
    std::string emotionKind;
    float emotionIntensity = 0.0f;
};

struct airi_render_backend {
    int32_t kind = AIRI_RENDER_KIND_VRM;
    uint32_t (*register_texture)(void *, uint32_t, uint32_t) = nullptr;
    void (*release_texture)(void *, uint32_t) = nullptr;
    void *ctx = nullptr;
    void *vrm = nullptr;
    /// Rust-side MMD renderer instance (kind == AIRI_RENDER_KIND_MMD).
    void *mmd = nullptr;
    std::string lastError;
    uint64_t nextId = 1;
    std::unordered_map<uint64_t, ModelEntry> models;
};