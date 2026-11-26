// SPDX-License-Identifier: GPL-3.0-or-later

//! Secret-free provider validation state wire DTOs.
//!
//! Additive metadata only: a provider instance identifier, two presence flags,
//! and a one-way digest of the snapshot that was validated. No credential,
//! token, API key, raw config, path or prompt ever crosses the gateway wire —
//! same rule as [`crate::wire::ProviderInfo`] and
//! [`crate::wire::DiscordStatusReply`]. These types carry no RPC verb; they are
//! payload shapes for a future, separately-gated daemon verb.

use serde::{Deserialize, Serialize};

/// One-way fingerprint metadata for the configuration snapshot a validation
/// ran against. The digest cannot reveal its input.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct ProviderValidationHash {
    /// Digest algorithm tag (e.g. `sha256`), never the input material.
    pub algorithm: String,
    /// Hex-encoded digest of the validation input; not reversible.
    pub value: String,
}

/// Secret-free validation state for one configured provider instance.
///
/// The two flags describe presence of a recorded validation result, not the
/// credential itself. `validation_bypassed` means the operator deliberately
/// skipped validation; `validated` means the hashed snapshot passed it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct ProviderValidationState {
    /// Stable provider instance identifier. Not a credential.
    pub instance_id: String,
    /// Whether validation succeeded on the hashed snapshot.
    pub validated: bool,
    /// Whether validation was deliberately bypassed by the operator.
    pub validation_bypassed: bool,
    /// Digest of the snapshot that produced this state.
    pub hash: ProviderValidationHash,
}
