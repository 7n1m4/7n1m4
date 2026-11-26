// SPDX-License-Identifier: GPL-3.0-or-later

//! Secret-free remote asset catalog manifest and download metadata wire DTOs.
//!
//! These describe *metadata only*: catalog entries with sizes and digests, and
//! a download handle with integrity and byte-budget data. No binary payload is
//! ever placed on a gateway frame — assets stay in daemon-owned storage. The
//! data budget follows the `SESSION_EXPORT_ENVELOPE_BYTES` reserve precedent
//! ([`crate::ws::MAX_WS_PAYLOAD_BYTES`] minus an 8 KiB RPC envelope), so a
//! metadata reply always fits a single WebSocket frame.

use serde::{Deserialize, Serialize};

/// Room reserved inside one WebSocket frame for the RPC envelope around asset
/// metadata replies (`type`, `action`, `ok` and an optional echoed client id).
/// Mirrors the daemon's `SESSION_EXPORT_ENVELOPE_BYTES` reserve.
pub const ASSET_METADATA_ENVELOPE_BYTES: u64 = 8192;

/// Max serialized size of asset metadata `data` inside one WS frame. The
/// metadata value is wrapped in an RPC envelope before becoming a frame, so
/// the transport cap minus the envelope is the real data budget.
pub const ASSET_METADATA_MAX_DATA_BYTES: u64 =
    crate::ws::MAX_WS_PAYLOAD_BYTES - ASSET_METADATA_ENVELOPE_BYTES;

/// One asset entry in a remote catalog manifest: metadata only, never bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct AssetCatalogEntry {
    /// Logical asset key within the catalog, never a host file path.
    pub asset_id: String,
    /// Catalog category tag (e.g. `model`, `mmd`, `vrma`, `background`).
    pub kind: String,
    /// Decoded byte size advertised by the manifest.
    #[specta(type = specta_typescript::Number)]
    pub size_bytes: u64,
    /// Hex content digest used for integrity checks; no secret material.
    pub content_hash: String,
    /// MIME type, when the manifest declares one.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub mime_type: Option<String>,
}

/// A remote asset catalog manifest: entry metadata and caps, no binary bytes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct AssetCatalogManifest {
    /// Stable catalog identifier (e.g. `models`, `backgrounds`).
    pub catalog_id: String,
    /// Manifest revision or etag used for cache invalidation.
    pub revision: String,
    /// Asset entries in the catalog.
    pub entries: Vec<AssetCatalogEntry>,
    /// Per-asset decoded byte cap enforced by the daemon.
    #[specta(type = specta_typescript::Number)]
    pub max_asset_bytes: u64,
    /// Whether the manifest was trimmed to a bounded entry count.
    pub truncated: bool,
}

/// Download metadata for one asset: a handle and integrity/cap data, never the
/// binary payload itself.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct AssetDownloadMetadata {
    /// Catalog the asset belongs to.
    pub catalog_id: String,
    /// Logical asset key within the catalog, never a host file path.
    pub asset_id: String,
    /// Decoded byte size advertised by the manifest.
    #[specta(type = specta_typescript::Number)]
    pub size_bytes: u64,
    /// Hex content digest the downloaded bytes must match.
    pub content_hash: String,
    /// Wire data budget (`MAX_WS_PAYLOAD_BYTES` minus the envelope reserve).
    #[specta(type = specta_typescript::Number)]
    pub max_data_bytes: u64,
}
