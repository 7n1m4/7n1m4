// SPDX-License-Identifier: GPL-3.0-or-later
//! Daemon-owned provider validation state.
//!
//! Mirrors the Vue runtime's validation cache (`validation.ts`): one entry per
//! provider *instance*, keyed by `instanceId`, whose cached `isConfigured`
//! decision is reusable only while the WHOLE config still produces the same
//! one-way digest. Any change — credentials included — invalidates the cache,
//! exactly like the TS `JSON.stringify(config)` comparison. Only the digest
//! and presence metadata are persisted or returned; no raw config value ever
//! reaches the blob, a log, or an API reply (same rule as
//! `anima_channel::wire::ProviderInfo`).
//!
//! NOTICE: validation state lives in the raw `settings/provider-validation`
//! blob, exactly like the daemon's `settings/chat` session choice. It is not a
//! typed settings section (no registry entry, no wire verb). All writes go
//! through `anima_store::SettingsRepo::set_if_unchanged`, which compares the
//! `updated_at` captured by `get_with_updated_at` against the stored row inside
//! one atomic SQLite statement: a slower writer is rejected instead of
//! reverting a newer value, even across processes. The read-modify-write is
//! additionally serialized in-process; see [`record`].

use std::collections::BTreeMap;
use std::fmt::Write;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anima_channel::provider::ProviderValidationHash;
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::core::CoreService;

/// Raw settings blob holding `instanceId -> ProviderValidationState`.
pub const SETTINGS_KEY: &str = "settings/provider-validation";

/// Algorithm + version marker stored with every digest. Matches the committed
/// wire DTO shape (`{ algorithm, value }`); a future algorithm change writes a
/// new marker and every cached decision revalidates once, never a false hit.
pub const HASH_ALGORITHM: &str = "sha256-v1";

/// Serializes in-process read-modify-writes to avoid spurious CAS failures between callers; stale snapshots are rejected by `set_if_unchanged`.
static RECORD_LOCK: Mutex<()> = Mutex::new(());

/// Secret-free validation metadata for one provider instance.
///
/// Deliberately has no `config`, `apiKey`, `secret` or `token` field: the only
/// trace of the config is the one-way [`config_hash`] used for cache
/// invalidation.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderValidationState {
    /// Globally unique instance key (`${providerId}:${id}`).
    pub instance_id: String,
    /// Cached validation decision. A boolean even when unvalidated, matching
    /// the TS `typeof runtimeState.isConfigured === 'boolean'` cache guard.
    pub is_configured: bool,
    /// An explicit validation succeeded (TS provider catalog `validated`).
    pub validated: bool,
    /// Validation was intentionally skipped (TS `validationBypassed`).
    pub validation_bypassed: bool,
    /// One-way digest of the full config snapshot (wire-DTO-shaped marker).
    pub hash: ProviderValidationHash,
    /// Unix milliseconds of the last recorded validation, when known.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_validated: Option<i64>,
}

/// Canonical, length-delimited encoding of a JSON value. Deterministic key
/// order, u8 type tags, u64 LE byte lengths and entry counts mean unrelated
/// snapshots cannot collide by concatenation. Credential `str` bytes go
/// straight into the SHA-256 state — never into a serialized value or a log.
fn hash_value<D: Digest>(value: &serde_json::Value, hasher: &mut D) {
    match value {
        serde_json::Value::Null => hasher.update(&[0]),
        serde_json::Value::Bool(bool_value) => {
            hasher.update(&[1]);
            hasher.update(&[u8::from(*bool_value)]);
        }
        serde_json::Value::Number(number) => {
            hasher.update(&[2]);
            let text = number.to_string();
            hasher.update(&(text.len() as u64).to_le_bytes());
            hasher.update(text.as_bytes());
        }
        serde_json::Value::String(string) => {
            hasher.update(&[3]);
            hasher.update(&(string.len() as u64).to_le_bytes());
            hasher.update(string.as_bytes());
        }
        serde_json::Value::Array(items) => {
            hasher.update(&[4]);
            hasher.update(&(items.len() as u64).to_le_bytes());
            for item in items {
                hash_value(item, hasher);
            }
        }
        serde_json::Value::Object(map) => {
            hasher.update(&[5]);
            let mut keys: Vec<&String> = map.keys().collect();
            keys.sort_unstable();
            hasher.update(&(keys.len() as u64).to_le_bytes());
            for key in keys {
                hasher.update(&(key.len() as u64).to_le_bytes());
                hasher.update(key.as_bytes());
                hash_value(&map[key], hasher);
            }
        }
    }
}

/// One-way SHA-256 fingerprint of the ENTIRE config, tagged with algorithm +
/// version. TS hashes `JSON.stringify(config)`, so rotating `apiKey`,
/// `accessKeyId`, `appKey`, or any Azure-specific field must invalidate the
/// cached decision. This canonical encoding is order-independent but equally
/// sensitive to every field; the 64-hex digest cannot reveal its input.
pub fn config_hash(config: &serde_json::Value) -> ProviderValidationHash {
    let mut hasher = Sha256::new();
    hash_value(config, &mut hasher);
    let digest = hasher.finalize();
    let mut value = String::with_capacity(digest.len() * 2);
    for &byte in &digest {
        write!(&mut value, "{byte:02x}").expect("hex formatting into a String cannot fail");
    }
    ProviderValidationHash {
        algorithm: HASH_ALGORITHM.to_string(),
        value,
    }
}

fn read_blob(core: &CoreService) -> Result<Option<serde_json::Value>, String> {
    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
    anima_store::SettingsRepo::new(db)
        .get(SETTINGS_KEY)
        .map_err(|e| e.to_string())
}

/// All stored validation states. A malformed entry is skipped (this is a cache,
/// not an authoritative record); the raw entry survives the next write because
/// [`record`] edits the blob as JSON, not through this typed view.
pub fn load_states(
    core: &CoreService,
) -> Result<BTreeMap<String, ProviderValidationState>, String> {
    let Some(blob) = read_blob(core)? else {
        return Ok(BTreeMap::new());
    };
    let Some(map) = blob.as_object() else {
        return Err("invalid provider validation settings".to_string());
    };
    Ok(map
        .iter()
        .filter_map(|(instance_id, value)| {
            serde_json::from_value::<ProviderValidationState>(value.clone())
                .ok()
                .map(|state| (instance_id.clone(), state))
        })
        .collect())
}

/// Secret-free metadata for one instance, if it has been validated before.
pub fn state(
    core: &CoreService,
    instance_id: &str,
) -> Result<Option<ProviderValidationState>, String> {
    Ok(load_states(core)?.remove(instance_id))
}

/// Vue's hash short-circuit: return the cached `isConfigured` only when the
/// full-config digest (marker included) still matches and `force` is false.
/// `None` means "must validate" — every config change invalidates the decision.
pub fn cached_is_configured(
    core: &CoreService,
    instance_id: &str,
    config: &serde_json::Value,
    force: bool,
) -> Result<Option<bool>, String> {
    if force {
        return Ok(None);
    }
    let Some(saved) = state(core, instance_id)? else {
        return Ok(None);
    };
    if saved.hash == config_hash(config) {
        Ok(Some(saved.is_configured))
    } else {
        Ok(None)
    }
}

/// Single raw read-modify-write of the validation blob for one instance.
///
/// The value and its `updated_at` are read together, mutated, then written back
/// with `SettingsRepo::set_if_unchanged`. The lock serializes writers in THIS
/// process; the compare-and-swap inside SQLite covers other processes too.
/// Poisoning is recovered: the blob is validated on every read, so a poisoned
/// lock holds no state.
fn record(core: &CoreService, new_state: &ProviderValidationState) -> Result<(), String> {
    let _guard = RECORD_LOCK
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
    let repo = anima_store::SettingsRepo::new(db);
    let (mut blob, expected): (serde_json::Value, i64) = repo
        .get_with_updated_at(SETTINGS_KEY)
        .map_err(|e| e.to_string())?
        .unwrap_or_else(|| (serde_json::json!({}), 0));
    let map = blob
        .as_object_mut()
        .ok_or_else(|| "invalid provider validation settings".to_string())?;
    let value = serde_json::to_value(new_state).map_err(|e| e.to_string())?;
    map.insert(new_state.instance_id.clone(), value);
    repo.set_if_unchanged(SETTINGS_KEY, &blob, expected)
        .map_err(|e| e.to_string())
}

/// Persist a validation outcome and return its secret-free metadata. The full
/// config is fingerprinted but never written to the blob or reply.
pub fn record_validation(
    core: &CoreService,
    instance_id: &str,
    config: &serde_json::Value,
    is_configured: bool,
    validated: bool,
    validation_bypassed: bool,
) -> Result<ProviderValidationState, String> {
    let state = ProviderValidationState {
        instance_id: instance_id.to_string(),
        is_configured,
        validated,
        validation_bypassed,
        hash: config_hash(config),
        last_validated: Some(now_ms()),
    };
    record(core, &state)?;
    Ok(state)
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| i64::try_from(elapsed.as_millis()).unwrap_or(i64::MAX))
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use crate::core::CoreService;

    use super::cached_is_configured;
    use super::config_hash;
    use super::load_states;
    use super::record_validation;
    use super::state;
    use super::HASH_ALGORITHM;
    use super::SETTINGS_KEY;

    fn core_at(dir: &tempfile::TempDir) -> CoreService {
        CoreService::open(Some(dir.path().to_path_buf()))
    }

    fn blob(core: &CoreService) -> serde_json::Value {
        anima_store::SettingsRepo::new(core.db().expect("daemon db handle"))
            .get::<serde_json::Value>(SETTINGS_KEY)
            .expect("settings read")
            .expect("validation blob exists")
    }

    #[test]
    fn config_hash_is_deterministic_but_is_not_json_stringify() {
        let a =
            serde_json::json!({ "apiKey": "sk-1", "model": "gpt-4", "nested": { "x": 1, "y": 2 } });
        // Same values, different key order: the canonical digest ignores it.
        let b =
            serde_json::json!({ "model": "gpt-4", "nested": { "y": 2, "x": 1 }, "apiKey": "sk-1" });
        assert_eq!(config_hash(&a), config_hash(&b));

        let changed =
            serde_json::json!({ "apiKey": "sk-1", "model": "gpt-5", "nested": { "x": 1, "y": 2 } });
        assert_ne!(config_hash(&a), config_hash(&changed));

        // The TS runtime hashes `JSON.stringify(config)`; a byte-for-byte copy
        // of that string is explicitly not our persisted fingerprint.
        assert_ne!(config_hash(&a).value, a.to_string());
    }

    #[test]
    fn distinct_full_configs_do_not_share_a_digest() {
        let left = serde_json::json!({
            "provider": "openai", "apiKey": "sk-one", "model": "gpt-4",
            "nested": { "temperature": 0.2, "tags": ["a", "b"] },
        });
        let right = serde_json::json!({
            "provider": "openai", "apiKey": "sk-one", "model": "gpt-4",
            "nested": { "temperature": 0.3, "tags": ["a", "b"] },
        });
        let left_hash = config_hash(&left);
        assert_eq!(left_hash.value.len(), 64);
        assert_eq!(left_hash.algorithm, HASH_ALGORITHM);
        assert_ne!(left_hash.value, config_hash(&right).value);
    }

    #[test]
    fn credential_and_azure_fields_invalidate_the_fingerprint() {
        let base = serde_json::json!({
            "resourceName": "res-one",
            "modelId": "gpt-4",
            "apiVersion": "2024-02-15-preview",
            "completionsApiVersion": "2024-02-15-preview",
            "apiKey": "sk-one",
        });
        let rotated = serde_json::json!({
            "resourceName": "res-one",
            "modelId": "gpt-4",
            "apiVersion": "2024-02-15-preview",
            "completionsApiVersion": "2024-02-15-preview",
            "apiKey": "sk-two",
        });
        assert_ne!(config_hash(&base), config_hash(&rotated), "apiKey rotation");

        for (field, value) in [
            ("resourceName", serde_json::json!("res-two")),
            ("modelId", serde_json::json!("gpt-5")),
            ("apiVersion", serde_json::json!("2024-10-01")),
            ("completionsApiVersion", serde_json::json!("2024-10-01")),
        ] {
            let mut changed = base.clone();
            changed[field] = value;
            assert_ne!(config_hash(&base), config_hash(&changed), "{field} change");
        }
    }

    #[test]
    fn canonical_digest_disambiguates_boundaries_presence_and_types() {
        let left = serde_json::json!({ "model": "ab", "endpoint": "c" });
        let right = serde_json::json!({ "model": "a", "endpoint": "bc" });
        assert_ne!(config_hash(&left), config_hash(&right));

        // Absent and empty are different presence states.
        assert_ne!(
            config_hash(&serde_json::json!({})),
            config_hash(&serde_json::json!({ "model": "" }))
        );

        // Type tags: a number is never coerced into the same string fingerprint.
        let number = config_hash(&serde_json::json!({ "model": 123 }));
        assert_ne!(number, config_hash(&serde_json::json!({ "model": "123" })));
        assert_ne!(number, config_hash(&serde_json::json!({})));
    }

    #[test]
    fn secret_rotation_invalidates_cached_is_configured() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let before = serde_json::json!({ "apiKey": "sk-one", "model": "gpt-4" });
        let after = serde_json::json!({ "apiKey": "sk-two", "model": "gpt-4" });
        record_validation(&core, "openai:*", &before, true, true, false).unwrap();

        assert_eq!(
            cached_is_configured(&core, "openai:*", &before, false).unwrap(),
            Some(true)
        );
        assert_eq!(
            cached_is_configured(&core, "openai:*", &after, false).unwrap(),
            None
        );
    }

    #[test]
    fn record_validation_persists_secret_free_metadata_in_raw_blob() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({
            "apiKey": "sk-super-secret-value",
            "accessKeyId": "AKIDSECRETVALUE",
            "appKey": "app-secret-value",
            "secret": "secret-value",
            "token": "token-value",
            "model": "gpt-4",
        });

        let recorded = record_validation(&core, "openai:*", &config, true, true, false).unwrap();
        assert_eq!(recorded.instance_id, "openai:*");
        assert!(recorded.is_configured);
        assert!(recorded.validated);
        assert!(!recorded.validation_bypassed);
        assert_eq!(recorded.hash, config_hash(&config));

        let saved = state(&core, "openai:*").unwrap().expect("saved state");
        assert_eq!(saved, recorded);

        let raw = blob(&core);
        assert_eq!(raw["openai:*"]["isConfigured"], true);
        assert_eq!(raw["openai:*"]["validated"], true);
        assert_eq!(raw["openai:*"]["validationBypassed"], false);
        assert_eq!(
            raw["openai:*"]["hash"],
            serde_json::to_value(config_hash(&config)).unwrap()
        );

        // Negative assertion: neither the persisted blob nor the returned value
        // carries a credential key or a credential value. Presence metadata only.
        let blob_text = raw.to_string();
        let value_text = serde_json::to_string(&recorded).unwrap();
        for needle in [
            "sk-super-secret-value",
            "AKIDSECRETVALUE",
            "app-secret-value",
            "secret-value",
            "token-value",
        ] {
            assert!(
                !blob_text.contains(needle),
                "credential value in blob: {needle}"
            );
            assert!(
                !value_text.contains(needle),
                "credential value in reply: {needle}"
            );
        }
        let lower_blob = blob_text.to_ascii_lowercase();
        let lower_value = value_text.to_ascii_lowercase();
        for field in [
            "apikey",
            "secret",
            "token",
            "password",
            "credential",
            "authorization",
        ] {
            assert!(
                !lower_blob.contains(field),
                "credential field in blob: {field}"
            );
            assert!(
                !lower_value.contains(field),
                "credential field in reply: {field}"
            );
        }
    }

    #[test]
    fn persisted_hash_matches_wire_marker_shape() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "apiKey": "sk-marker", "model": "gpt-4" });
        record_validation(&core, "openai:*", &config, true, true, false).unwrap();

        let raw = blob(&core);
        let marker: anima_channel::provider::ProviderValidationHash =
            serde_json::from_value(raw["openai:*"]["hash"].clone()).unwrap();
        assert_eq!(marker.algorithm, HASH_ALGORITHM);
        assert_eq!(marker.value.len(), 64, "SHA-256 must be 64 hex chars");
        assert!(marker.value.bytes().all(|byte| byte.is_ascii_hexdigit()));
        assert_eq!(raw["openai:*"]["hash"]["algorithm"], HASH_ALGORITHM);
        assert_eq!(raw["openai:*"]["hash"]["value"], marker.value);
        assert_eq!(marker, config_hash(&config));
    }

    #[test]
    fn states_are_keyed_by_instance_id_and_updates_preserve_siblings() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "model": "m" });

        record_validation(&core, "openai:primary", &config, true, true, false).unwrap();
        record_validation(&core, "ollama:local", &config, false, false, true).unwrap();
        assert_eq!(
            state(&core, "openai:primary")
                .unwrap()
                .unwrap()
                .is_configured,
            true
        );
        assert_eq!(
            state(&core, "ollama:local").unwrap().unwrap().is_configured,
            false
        );

        // A later write for one instance is a read-modify-write of the raw blob:
        // the sibling instance survives and the same slot is replaced, not appended.
        let changed = serde_json::json!({ "model": "m2" });
        record_validation(&core, "openai:primary", &changed, false, true, false).unwrap();
        assert_eq!(
            state(&core, "openai:primary").unwrap().unwrap().hash,
            config_hash(&changed)
        );
        let sibling = state(&core, "ollama:local").unwrap().unwrap();
        assert_eq!(sibling.hash, config_hash(&config));
        assert!(sibling.validation_bypassed);
        assert_eq!(blob(&core).as_object().unwrap().len(), 2);
    }

    #[test]
    fn concurrent_record_writes_keep_every_sibling_decision() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "model": "m" });

        let handles: Vec<_> = (0..16)
            .map(|index| {
                let core = core.clone();
                let config = config.clone();
                std::thread::spawn(move || {
                    record_validation(
                        &core,
                        &format!("openai:instance-{index}"),
                        &config,
                        index % 2 == 0,
                        true,
                        false,
                    )
                    .unwrap();
                })
            })
            .collect();
        for handle in handles {
            handle.join().unwrap();
        }

        // Without the RMW lock, interleaved snapshots can drop sibling writes.
        let states = load_states(&core).unwrap();
        assert_eq!(states.len(), 16);
        for index in 0..16 {
            let id = format!("openai:instance-{index}");
            assert_eq!(states[&id].is_configured, index % 2 == 0);
            assert_eq!(states[&id].hash, config_hash(&config));
        }
    }

    #[test]
    fn hash_short_circuit_tracks_config_and_honors_force() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let old = serde_json::json!({ "model": "old" });
        let new = serde_json::json!({ "model": "new" });
        record_validation(&core, "openai:*", &old, true, true, false).unwrap();

        assert_eq!(
            cached_is_configured(&core, "openai:*", &old, false).unwrap(),
            Some(true)
        );
        assert_eq!(
            cached_is_configured(&core, "openai:*", &new, false).unwrap(),
            None
        );
        assert_eq!(
            cached_is_configured(&core, "openai:*", &old, true).unwrap(),
            None
        );

        record_validation(&core, "openai:*", &new, false, false, false).unwrap();
        assert_eq!(
            cached_is_configured(&core, "openai:*", &new, false).unwrap(),
            Some(false)
        );
        assert_eq!(
            cached_is_configured(&core, "openai:*", &old, false).unwrap(),
            None
        );
    }

    #[test]
    fn validation_bypassed_metadata_is_persisted_without_trusting_the_cache_less() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "baseUrl": "http://localhost:11434" });

        let bypassed =
            record_validation(&core, "ollama:local", &config, true, false, true).unwrap();
        assert!(!bypassed.validated);
        assert!(bypassed.validation_bypassed);
        let saved = state(&core, "ollama:local").unwrap().unwrap();
        assert_eq!(saved, bypassed);
        // The short-circuit is hash-based: bypass metadata is reported, not re-run.
        assert_eq!(
            cached_is_configured(&core, "ollama:local", &config, false).unwrap(),
            Some(true)
        );
    }

    #[test]
    fn missing_instance_has_no_cached_decision() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "model": "m" });
        assert!(state(&core, "never-seen:*").unwrap().is_none());
        assert_eq!(
            cached_is_configured(&core, "never-seen:*", &config, false).unwrap(),
            None
        );
    }

    #[test]
    fn two_core_handles_on_one_file_both_keep_their_decision() {
        let dir = tempfile::tempdir().unwrap();
        // Two CoreService handles open the same airi.sqlite through independent
        // Database/connection mutexes, standing in for two processes.
        let first = core_at(&dir);
        let second = CoreService::open(Some(dir.path().to_path_buf()));
        let config = serde_json::json!({ "model": "m" });

        record_validation(&first, "openai:one", &config, true, true, false).unwrap();
        record_validation(&second, "ollama:two", &config, false, false, true).unwrap();

        let states = load_states(&first).unwrap();
        assert_eq!(
            states.len(),
            2,
            "neither handle may clobber the other's write"
        );
        assert!(states["openai:one"].is_configured);
        assert!(!states["ollama:two"].is_configured);
        assert!(states["ollama:two"].validation_bypassed);
    }

    #[test]
    fn stale_expected_write_to_validation_blob_is_rejected_without_changing_it() {
        let dir = tempfile::tempdir().unwrap();
        let core = core_at(&dir);
        let config = serde_json::json!({ "model": "m" });
        record_validation(&core, "openai:*", &config, true, true, false).unwrap();

        let repo = anima_store::SettingsRepo::new(core.db().expect("daemon db handle"));
        let (mut stale_blob, stale_expected): (serde_json::Value, i64) = repo
            .get_with_updated_at(SETTINGS_KEY)
            .unwrap()
            .expect("validation blob exists");

        // A newer write advances the stored stamp, invalidating our snapshot.
        record_validation(&core, "ollama:local", &config, false, false, true).unwrap();
        stale_blob["openai:*"]["isConfigured"] = serde_json::json!(false);

        let err = repo
            .set_if_unchanged(SETTINGS_KEY, &stale_blob, stale_expected)
            .expect_err("stale validation-blob write rejected");
        assert!(err.to_string().contains("stale"), "error: {err:#}");

        // The rejected write leaves the blob as the newer writer left it.
        let after = blob(&core);
        assert_eq!(after["openai:*"]["isConfigured"], true);
        assert_eq!(after["ollama:local"]["validationBypassed"], true);
        assert_eq!(after.as_object().unwrap().len(), 2);
    }

    #[test]
    fn stale_snapshot_from_one_handle_cannot_clobber_another_handles_write() {
        let dir = tempfile::tempdir().unwrap();
        let first = core_at(&dir);
        let second = CoreService::open(Some(dir.path().to_path_buf()));
        let config = serde_json::json!({ "model": "m" });

        record_validation(&first, "openai:*", &config, true, true, false).unwrap();

        // Both handles observe the SAME value/stamp snapshot of the one row.
        let first_repo = anima_store::SettingsRepo::new(first.db().expect("first db handle"));
        let second_repo = anima_store::SettingsRepo::new(second.db().expect("second db handle"));
        let (snapshot, expected): (serde_json::Value, i64) = first_repo
            .get_with_updated_at(SETTINGS_KEY)
            .unwrap()
            .expect("validation blob exists");
        let (_, second_expected): (serde_json::Value, i64) = second_repo
            .get_with_updated_at(SETTINGS_KEY)
            .unwrap()
            .expect("validation blob exists");
        assert_eq!(expected, second_expected, "both handles share one snapshot");

        // Handle A records a change, advancing updated_at strictly.
        record_validation(&first, "ollama:local", &config, false, false, true).unwrap();

        // Handle B writes from its now-stale snapshot. `record` always re-reads
        // under RECORD_LOCK, so the explicit-stamp path is the store CAS: a
        // plain `set` (or the in-process lock alone) would clobber A's write.
        let mut stale = snapshot;
        stale["openai:*"]["isConfigured"] = serde_json::json!(false);
        let err = second_repo
            .set_if_unchanged(SETTINGS_KEY, &stale, expected)
            .expect_err("stale snapshot from second handle rejected");
        assert!(err.to_string().contains("stale"), "error: {err:#}");

        // A's newer value is intact: the rejected write changed nothing.
        let after = blob(&first);
        assert_eq!(after["openai:*"]["isConfigured"], true);
        assert_eq!(after["ollama:local"]["validationBypassed"], true);
        assert_eq!(after.as_object().unwrap().len(), 2);
    }
}
