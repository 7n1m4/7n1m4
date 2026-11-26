// SPDX-License-Identifier: GPL-3.0-or-later
//! The frozen native render/texture contract.
//!
//! This module is the single cross-platform seam every per-OS GPU backend
//! implements and the only native surface the Flutter plugin sees. It is
//! renderer-agnostic: a 2D Spine scene and a 3D VRM/MMD scene both reduce to
//! the same frame shape — texture pages, a flat vertex/index buffer, and draw
//! ranges — defined in [`frame`].
//!
//! The platform (Dart) side is frozen: `MethodChannelModelBackend` on channel
//! `org.moeru.airi/anima/model/<kind>` exchanges the methods and argument keys
//! declared by [`crate::contract::contract::render_contract_json`]. Dart never
//! sees vertices, draws or pages; it registers one GPU texture per
//! [`TexturePayload`] and thereafter holds only the opaque `textureId` that
//! [`RendererBackend::load`] returns.
//!
//! Ownership: a backend is created with [`RenderBackend::create`] and torn
//! down with [`RenderBackend::drop`] (which calls `airi_render_destroy`,
//! idempotent and null-safe). `load`
//! returns the opaque texture id of the model's output surface; the platform
//! owns that id and releases it when it disposes the handle, and the backend
//! frees the GPU resources it allocated for the handle on the matching
//! `dispose`. A backend is `Send` but not `Sync`: the platform confines it to
//! one render thread.

pub mod backend;
pub mod contract;
pub mod frame;
pub mod ffi;

pub use backend::{BackendKind, RendererBackend};
pub use contract::{render_contract_json, CONTRACT_VERSION};
pub use frame::{
    BlendMode, DrawCommand, FrameGeometry, RenderFrame, TextureFormat, TexturePayload, Vertex,
};
pub use ffi::{airi_render_handle, kind, RenderBackend, TextureRegistry};