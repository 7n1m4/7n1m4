// SPDX-License-Identifier: GPL-3.0-or-later
//! Provider resolution from the environment and the providers table.
//!
//! Shared by the chat pipeline (through the slint bridge today, the daemon
//! later) so every surface picks the same provider when it must answer
//! "which provider would a send go through".

use anima_llm::ProviderConfig;
use anima_store::StoredProvider;

/// Environment variable naming the provider id to use.
pub const ENV_PROVIDER: &str = "AIRI_SLINT_PROVIDER";
/// Environment variable for the API key of the env-selected provider.
pub const ENV_API_KEY: &str = "AIRI_SLINT_API_KEY";
/// Environment variable for the base URL of the env-selected provider.
pub const ENV_BASE_URL: &str = "AIRI_SLINT_BASE_URL";
/// Environment variable for the model of the env-selected provider.
pub const ENV_MODEL: &str = "AIRI_SLINT_MODEL";

/// Substring matches in a normalized config key. Public so the read-only
/// `vault.secret_key_policy` RPC can report the exact policy without clients
/// hand-maintaining a copy. Patterns only — never stored key names or values.
pub const SECRET_CONFIG_KEY_SUBSTRINGS: &[&str] = &[
    "apikey",
    "authheader",
    "authorization",
    "secret",
    "password",
    "credential",
    "bearer",
];

/// Suffix matches in a normalized config key. See
/// [`SECRET_CONFIG_KEY_SUBSTRINGS`] for the exposure contract.
pub const SECRET_CONFIG_KEY_SUFFIXES: &[&str] = &["token", "key"];

/// TS `isSecretConfigKey`: normalized names ending in `key`/`token` or
/// containing an auth word are secrets. Used to keep pooled/system-row
/// credentials out of thin-client replies (`toSafeSystemRow` in the TS
/// reference) and to stop a PATCH from rotating a managed secret.
pub fn is_secret_config_key(key: &str) -> bool {
    let normalized = normalize_config_key(key);
    SECRET_CONFIG_KEY_SUBSTRINGS
        .iter()
        .any(|s| normalized.contains(s))
        || SECRET_CONFIG_KEY_SUFFIXES
            .iter()
            .any(|s| normalized.ends_with(s))
}

/// Match wire (`apiKey`) and stored (`api_key`) spellings of the same key.
fn normalize_config_key(key: &str) -> String {
    key.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Normalized substrings for storage keys that carry credentials but do not
/// use the config-key spellings above (id-shaped keys, OAuth flows, TLS
/// material, ...). Shapes only — never a stored key name, value or config blob.
pub const SECRET_STORAGE_KEY_SUBSTRINGS: &[&str] = &[
    "accountid",
    "freehub",
    "keyid",
    "keypair",
    "mcpconfig",
    "oauth",
    "tlsconfig",
    "verifier",
];

/// Case-insensitive prefixes whose whole branch is credential-bearing.
/// Same exposure contract as [`SECRET_STORAGE_KEY_SUBSTRINGS`].
pub const SECRET_STORAGE_KEY_PREFIXES: &[&str] = &[
    // Only the credential-bearing leaves of these branches are secret: a
    // whole-branch rule would drop ordinary roster/server-args on backup.
    "local:peers/device-keypair",
    "local:providers",
    "settings/credentials/",
    "settings/free-hub/",
    "settings/mcp/config",
];

/// Match the storage-key half of the backup/sync exclusion policy. Normalizes
/// like config keys so `key-id` and `keyId` hit the same published pattern.
pub fn is_secret_storage_key(key: &str) -> bool {
    let normalized = normalize_config_key(key);
    let lowercase = key.to_ascii_lowercase();
    SECRET_STORAGE_KEY_SUBSTRINGS
        .iter()
        .any(|s| normalized.contains(s))
        || SECRET_STORAGE_KEY_PREFIXES
            .iter()
            .any(|p| lowercase.starts_with(p))
}

/// Full exclusion policy for unencrypted backup/sync: config-shaped secrets
/// plus storage-key shapes. Shared with the read-only policy verb so TS never
/// hand-maintains the tree again.
pub fn is_secret_key(key: &str) -> bool {
    is_secret_config_key(key) || is_secret_storage_key(key)
}

/// Recursively strip secret-shaped keys from a provider config value.
pub fn strip_secret_config_keys(value: &serde_json::Value) -> serde_json::Value {
    match value {
        serde_json::Value::Object(map) => serde_json::Value::Object(
            map.iter()
                .filter(|(key, _)| !is_secret_config_key(key))
                .map(|(key, v)| (key.clone(), strip_secret_config_keys(v)))
                .collect(),
        ),
        serde_json::Value::Array(items) => {
            serde_json::Value::Array(items.iter().map(strip_secret_config_keys).collect())
        }
        other => other.clone(),
    }
}

/// Merge an incoming config patch while preserving stored credential-shaped
/// keys. A client cannot overwrite a managed secret by echoing its key.
pub fn merge_config_preserving_secrets(
    existing: &serde_json::Map<String, serde_json::Value>,
    incoming: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Value {
    let mut merged = incoming.clone();
    for (key, value) in existing {
        if is_secret_config_key(key) {
            merged.insert(key.clone(), value.clone());
        }
    }
    serde_json::Value::Object(merged)
}

/// Merge an explicit rotation patch: an incoming secret-shaped key replaces
/// the stored key with the same normalized name (wire camelCase and stored
/// snake_case are the same key). Unmentioned credentials stay protected.
pub fn merge_config_rotating_secrets(
    existing: &serde_json::Map<String, serde_json::Value>,
    incoming: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Value {
    // A rotation changes a known credential; it does not introduce a new one.
    let mut merged: serde_json::Map<String, serde_json::Value> = incoming
        .iter()
        .filter(|(k, _)| {
            !is_secret_config_key(k)
                || existing
                    .keys()
                    .any(|stored| normalize_config_key(stored) == normalize_config_key(k))
        })
        .map(|(k, v)| (k.clone(), v.clone()))
        .collect();
    for (key, value) in existing {
        if !is_secret_config_key(key) {
            continue;
        }
        let normalized = normalize_config_key(key);
        if let Some((incoming_key, _)) = incoming.iter().find(|(k, v)| {
            is_secret_config_key(k) && normalize_config_key(k) == normalized && !v.is_null()
        }) {
            // Keep the existing spelling so a rotation never creates a second
            // secret field with a different name.
            merged.remove(incoming_key);
            merged.insert(key.clone(), incoming[incoming_key].clone());
        } else {
            merged.insert(key.clone(), value.clone());
        }
    }
    serde_json::Value::Object(merged)
}

/// LocalStorage key holding provider credentials as a v2 instance snapshot,
/// or (before migration) as a legacy `providerId → options` map.
pub const PROVIDER_INSTANCES_STORAGE_KEY: &str = "settings/credentials/providers";

/// Infix of the single primary instance every provider has (`providerId:*`).
/// Legacy single-slot callers keep addressing state through this row.
pub const PRIMARY_INSTANCE_INFIX: &str = "*";

/// Canonical camelCase names of the only four legacy aliases the TS store
/// migrates (`instance-store.ts:63-68`). Listing canonical names only — not
/// alias→canonical pairs — avoids a second alias table; snake spellings are
/// derived by [`snake_case_to_camel`] and gated against this list.
const LEGACY_CREDENTIAL_CANONICAL_KEYS: &[&str] =
    &["apiKey", "baseUrl", "awsAccessKeyId", "awsSecretAccessKey"];

/// Derive the camelCase spelling of a snake_case key (`api_key` → `apiKey`).
///
/// A pure spelling rule only: callers must gate the result against
/// [`LEGACY_CREDENTIAL_CANONICAL_KEYS`] so unknown host-specific keys such as
/// `cf_account_id` never gain a camelCase twin.
fn snake_case_to_camel(key: &str) -> Option<String> {
    if !key.contains('_') {
        return None;
    }
    let mut out = String::with_capacity(key.len());
    let mut capitalize = false;
    for part in key.split('_') {
        if part.is_empty() {
            continue;
        }
        let mut chars = part.chars();
        if capitalize {
            if let Some(first) = chars.next() {
                out.extend(first.to_uppercase());
            }
            out.extend(chars.flat_map(char::to_lowercase));
        } else {
            out.extend(part.chars().flat_map(char::to_lowercase));
        }
        capitalize = true;
    }
    (!out.is_empty()).then_some(out)
}

/// Fill the four known camelCase canonical keys from their snake_case aliases
/// when the exact canonical key is absent. A canonical key present with any
/// value (even `null`) wins; near-spellings (`apikey`, `api-key`) are not
/// canonical and do not block the fill. When several aliases target one
/// canonical, the usable (non-whitespace) value wins, ties broken by key name.
/// Unknown host-specific snake keys are left untouched.
///
/// **Secret-bearing:** the returned map holds raw credentials. Pass it through
/// [`strip_secret_config_keys`] before any trust boundary, logging or RPC, and
/// never log its values.
pub fn normalize_legacy_credential_keys(
    options: &serde_json::Map<String, serde_json::Value>,
) -> serde_json::Map<String, serde_json::Value> {
    let mut normalized = options.clone();
    for &canonical in LEGACY_CREDENTIAL_CANONICAL_KEYS {
        // TS checks `normalized[canonical] === undefined`: only the exact key
        // counts, not a normalized near-spelling.
        if options.contains_key(canonical) {
            continue;
        }
        let Some((_, value)) = options
            .iter()
            .filter(|(key, value)| {
                value.is_string() && snake_case_to_camel(key).as_deref() == Some(canonical)
            })
            .max_by_key(|(key, value)| {
                (
                    value.as_str().is_some_and(|s| !s.trim().is_empty()),
                    (*key).clone(),
                )
            })
        else {
            continue;
        };
        normalized.insert(canonical.to_string(), value.clone());
    }
    normalized
}

/// True when a value carries no usable credential material. Whitespace-only
/// strings, empty arrays, empty nested records, `null` and `false` are empty
/// so a blank-but-truthy shell cannot poll forever without authenticating.
fn is_empty_credential_value(value: &serde_json::Value) -> bool {
    match value {
        serde_json::Value::String(s) => s.trim().is_empty(),
        serde_json::Value::Array(items) => items.is_empty(),
        serde_json::Value::Object(map) => map.values().all(|nested| match nested {
            serde_json::Value::String(s) => s.trim().is_empty(),
            serde_json::Value::Null | serde_json::Value::Bool(false) => true,
            _ => false,
        }),
        serde_json::Value::Null | serde_json::Value::Bool(false) => true,
        _ => false,
    }
}

/// TS `isEmptyCredentialStub`: a legacy record with nothing usable to migrate.
/// An empty record satisfies this via `all` on zero values. The input is
/// secret-bearing: inspect only, never log it.
pub fn is_empty_credential_stub(options: &serde_json::Map<String, serde_json::Value>) -> bool {
    options.values().all(is_empty_credential_value)
}

/// TS `cleanInfix`: normalize an instance id that may already be a full
/// `<providerId>:<instanceId>` key. Missing, empty or primary infixes resolve
/// to [`PRIMARY_INSTANCE_INFIX`]; repeated provider prefixes are peeled once
/// each so a dirty key cannot nest the provider id. The result addresses a
/// secret-bearing row — never log provider credentials alongside it.
pub fn clean_instance_infix(provider_id: &str, instance_id: Option<&str>) -> String {
    let Some(mut clean) = instance_id.filter(|id| !id.is_empty()) else {
        return PRIMARY_INSTANCE_INFIX.to_string();
    };
    if clean == PRIMARY_INSTANCE_INFIX {
        return PRIMARY_INSTANCE_INFIX.to_string();
    }
    let prefix = format!("{provider_id}:");
    while let Some(rest) = clean.strip_prefix(&prefix) {
        clean = rest;
    }
    if clean.is_empty() {
        PRIMARY_INSTANCE_INFIX.to_string()
    } else {
        clean.to_string()
    }
}

/// Build the instance-key (`<providerId>:<instanceId>`) used by the v2
/// snapshot, with primary-infix normalization applied to `instance_id`.
/// The key locates a secret-bearing row; never log its credentials.
pub fn provider_instance_storage_key(provider_id: &str, instance_id: Option<&str>) -> String {
    format!(
        "{provider_id}:{}",
        clean_instance_infix(provider_id, instance_id)
    )
}

/// Pure legacy migration: map a `providerId → options` credential blob to
/// `<providerId>:*` instance keys with the four known snake_case aliases
/// normalized and empty stubs dropped.
///
/// Already-v2 snapshots (including an array-shaped `instancesByInstanceKey`,
/// which TS also treats as an object) and foreign input (null, array, string,
/// number) return `None` so a caller can pass them through untouched — never
/// replace stored credentials with an empty result. Only keys and option maps
/// are produced — no instance rows, storage writes or credential rotation.
///
/// **Secret-bearing:** the returned map holds raw credentials. Pass it through
/// [`strip_secret_config_keys`] before any trust boundary, logging or RPC, and
/// never log its values. Callers wrap it into their own row shape.
pub fn migrate_legacy_provider_credential_keys(
    raw: &serde_json::Value,
) -> Option<serde_json::Map<String, serde_json::Value>> {
    let Some(snapshot) = raw.as_object() else {
        return None;
    };
    let version_is_v2 = snapshot.get("version").and_then(|v| v.as_u64()) == Some(2);
    let instance_map_is_object_shaped = matches!(
        snapshot.get("instancesByInstanceKey"),
        Some(value) if value.is_object() || value.is_array()
    );
    if version_is_v2 && instance_map_is_object_shaped {
        return None;
    }

    let mut instances = serde_json::Map::new();
    for (provider_id, record) in snapshot {
        let Some(options) = record.as_object() else {
            continue;
        };
        let normalized = normalize_legacy_credential_keys(options);
        if is_empty_credential_stub(&normalized) {
            continue;
        }
        let key = provider_instance_storage_key(provider_id, Some(PRIMARY_INSTANCE_INFIX));
        // Two legacy ids can collapse onto the same `<providerId>:*` key;
        // merge their options instead of silently dropping the first one.
        if let Some(existing) = instances.get_mut(&key).and_then(|v| v.as_object_mut()) {
            for (name, value) in normalized {
                existing.insert(name, value);
            }
        } else {
            instances.insert(key, serde_json::Value::Object(normalized));
        }
    }
    Some(instances)
}

/// The provider a send would go through.
#[derive(Debug, Clone)]
pub struct ProviderResolution {
    /// Provider id (e.g. `openai`).
    pub id: String,
    /// Provider config (api key, base URL, model, extra options).
    pub config: ProviderConfig,
    /// Model, mirroring `config.model` for label display.
    pub model: String,
}

impl ProviderResolution {
    /// `id` when no model is configured, else `id · model`.
    pub fn label(&self) -> String {
        if self.model.trim().is_empty() {
            self.id.clone()
        } else {
            format!("{} · {}", self.id, self.model.trim())
        }
    }
}

/// Resolve the provider: env override first, then the first enabled row in
/// the providers table. `rows` are the caller's own listing (fetched from
/// `ProviderRepo` or injected in tests); the env is passed as an
/// `std::env::var`-shaped function so tests never touch the process env.
///
/// Returns `None` when nothing is configured — callers decide what "nothing
/// configured" means for them (the slint bridge falls back to a default
/// `openai` id; the memory wiring shows "not configured").
pub fn resolve_provider(
    env: impl Fn(&str) -> Option<String>,
    rows: &[StoredProvider],
) -> Option<ProviderResolution> {
    resolve_provider_selection(env, rows, "", "")
}

/// Resolve a provider from the daemon-owned active selection.
///
/// An active id (when non-empty) must name an enabled stored row; it takes
/// precedence over the env override and over row order. An active model
/// overrides the model stored in that row (credentials and base URL stay
/// with the row). Empty id/model defer to [`resolve_provider`] semantics.
/// A stale selection resolves to `None` — never silently to another provider.
pub fn resolve_provider_selection(
    env: impl Fn(&str) -> Option<String>,
    rows: &[StoredProvider],
    active_provider: &str,
    active_model: &str,
) -> Option<ProviderResolution> {
    let active_provider = active_provider.trim();
    if !active_provider.is_empty() {
        let provider = rows.iter().find(|p| p.enabled && p.id == active_provider)?;
        let config: ProviderConfig = match serde_json::from_value(provider.config.clone()) {
            Ok(c) => c,
            Err(err) => {
                tracing::warn!(
                    provider_id = %provider.id,
                    error = %err,
                    "stored provider config failed to deserialize; using empty config"
                );
                ProviderConfig::default()
            }
        };
        let model = if active_model.trim().is_empty() {
            config.model.clone().unwrap_or_default()
        } else {
            active_model.trim().to_string()
        };
        return Some(ProviderResolution {
            id: provider.id.clone(),
            config,
            model,
        });
    }
    if let Some(id) = env(ENV_PROVIDER) {
        let id = id.trim().to_string();
        if !id.is_empty() {
            let config = ProviderConfig {
                api_key: env(ENV_API_KEY),
                base_url: env(ENV_BASE_URL),
                model: env(ENV_MODEL),
                extra_json: Default::default(),
            };
            let model = config.model.clone().unwrap_or_default();
            return Some(ProviderResolution { id, config, model });
        }
    }
    let provider = rows.iter().find(|p| p.enabled)?;
    let config: ProviderConfig = match serde_json::from_value(provider.config.clone()) {
        Ok(c) => c,
        Err(err) => {
            tracing::warn!(
                provider_id = %provider.id,
                error = %err,
                "stored provider config failed to deserialize; using empty config"
            );
            ProviderConfig::default()
        }
    };
    let model = config.model.clone().unwrap_or_default();
    Some(ProviderResolution {
        id: provider.id.clone(),
        config,
        model,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use anima_store::StoredProvider;

    fn row(id: &str, enabled: bool, config: serde_json::Value) -> StoredProvider {
        StoredProvider {
            id: id.to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config,
            enabled,
            updated_at: 0,
        }
    }

    fn empty_env(_: &str) -> Option<String> {
        None
    }

    fn env_fn(pairs: &'static [(&'static str, &'static str)]) -> impl Fn(&str) -> Option<String> {
        move |key| {
            pairs
                .iter()
                .find(|(k, _)| *k == key)
                .map(|(_, v)| v.to_string())
        }
    }

    #[test]
    fn env_override_wins_over_stored_rows() {
        let env = env_fn(&[
            (ENV_PROVIDER, "anthropic"),
            (ENV_API_KEY, "sk-test"),
            (ENV_MODEL, "claude-x"),
        ]);
        let rows = [row(
            "openai",
            true,
            serde_json::json!({ "model": "stored-model" }),
        )];
        let r = resolve_provider(env, &rows).unwrap();
        assert_eq!(r.id, "anthropic");
        assert_eq!(r.config.api_key.as_deref(), Some("sk-test"));
        assert_eq!(r.model, "claude-x");
    }

    #[test]
    fn blank_env_id_falls_through_to_stored() {
        let env = env_fn(&[(ENV_PROVIDER, "   ")]);
        let rows = [row(
            "openai",
            true,
            serde_json::json!({ "model": "stored-model" }),
        )];
        let r = resolve_provider(env, &rows).unwrap();
        assert_eq!(r.id, "openai");
        assert_eq!(r.model, "stored-model");
    }

    #[test]
    fn first_enabled_row_wins_and_disabled_rows_are_skipped() {
        let rows = [
            row("disabled-one", false, serde_json::json!({ "model": "x" })),
            row("enabled-one", true, serde_json::json!({ "model": "y" })),
            row("enabled-two", true, serde_json::json!({ "model": "z" })),
        ];
        let r = resolve_provider(empty_env, &rows).unwrap();
        assert_eq!(r.id, "enabled-one");
        assert_eq!(r.model, "y");
    }

    #[test]
    fn malformed_stored_config_defaults_to_empty_config() {
        let rows = [row("openai", true, serde_json::json!("not an object"))];
        let r = resolve_provider(empty_env, &rows).unwrap();
        assert_eq!(r.id, "openai");
        assert!(r.config.api_key.is_none());
        assert_eq!(r.model, "");
    }

    #[test]
    fn camelcase_stored_config_is_accepted() {
        let rows = [row(
            "openai",
            true,
            serde_json::json!({ "apiKey": "sk-legacy", "baseUrl": "https://legacy.test/v1", "model": "m" }),
        )];
        let r = resolve_provider(empty_env, &rows).unwrap();
        assert_eq!(r.config.api_key.as_deref(), Some("sk-legacy"));
        assert_eq!(r.config.base_url.as_deref(), Some("https://legacy.test/v1"));
        assert_eq!(r.model, "m");
    }

    #[test]
    fn nothing_configured_resolves_to_none() {
        assert!(resolve_provider(empty_env, &[]).is_none());
    }

    #[test]
    fn active_selection_overrides_env_and_row_order() {
        let env = env_fn(&[
            (ENV_PROVIDER, "anthropic"),
            (ENV_API_KEY, "sk-env"),
            (ENV_MODEL, "env-model"),
        ]);
        let rows = [
            row("first", true, serde_json::json!({ "model": "first-model" })),
            row(
                "chosen",
                true,
                serde_json::json!({ "model": "stored-model", "api_key": "sk-stored" }),
            ),
        ];
        let r = resolve_provider_selection(env, &rows, "chosen", "picked-model").unwrap();
        assert_eq!(r.id, "chosen");
        assert_eq!(r.model, "picked-model");
        assert_eq!(r.config.api_key.as_deref(), Some("sk-stored"));
    }

    #[test]
    fn active_selection_without_model_uses_stored_model() {
        let rows = [
            row("first", true, serde_json::json!({ "model": "first-model" })),
            row(
                "chosen",
                true,
                serde_json::json!({ "model": "stored-model" }),
            ),
        ];
        let r = resolve_provider_selection(empty_env, &rows, " chosen ", "  ").unwrap();
        assert_eq!(r.id, "chosen");
        assert_eq!(r.model, "stored-model");
    }

    #[test]
    fn stale_or_disabled_active_selection_fails_closed() {
        let rows = [
            row("chosen", false, serde_json::json!({ "model": "m" })),
            row("fallback", true, serde_json::json!({ "model": "m" })),
        ];
        assert!(resolve_provider_selection(empty_env, &rows, "chosen", "m").is_none());
        assert!(resolve_provider_selection(empty_env, &rows, "gone", "m").is_none());
    }

    #[test]
    fn label_shows_model_when_present_else_id() {
        let rows = [row(
            "openai",
            true,
            serde_json::json!({ "model": "gpt-4o" }),
        )];
        assert_eq!(
            resolve_provider(empty_env, &rows).unwrap().label(),
            "openai · gpt-4o"
        );
        let rows = [row("openai", true, serde_json::json!({}))];
        assert_eq!(
            resolve_provider(empty_env, &rows).unwrap().label(),
            "openai"
        );
    }

    #[test]
    fn secret_keys_are_stripped_recursively_without_echoing_values() {
        let raw = serde_json::json!({
            "apiKey": "TOP-SECRET",
            "base_url": "https://example.test/v1",
            // `credentials` is a secret-shaped container: TS toSafeSystemRow
            // strips the whole subtree, including non-secret-looking fields.
            "credentials": { "accessToken": "ANOTHER-SECRET", "region": "us-east" },
            "extra": [{ "auth_header": "BEARER-SECRET", "maxTokens": 100 }],
            "maxTokens": 500,
            "tokenizer": "cl100k",
        });
        let safe = strip_secret_config_keys(&raw);
        let text = safe.to_string();
        assert!(!text.contains("TOP-SECRET"));
        assert!(!text.contains("ANOTHER-SECRET"));
        assert!(!text.contains("BEARER-SECRET"));
        assert_eq!(safe["base_url"], "https://example.test/v1");
        assert!(
            safe["credentials"].is_null(),
            "secret container must be stripped wholesale"
        );
        assert_eq!(safe["extra"][0]["maxTokens"], 100);
        assert_eq!(safe["maxTokens"], 500);
        assert_eq!(safe["tokenizer"], "cl100k");
        assert!(is_secret_config_key("apiKey"));
        assert!(is_secret_config_key("auth-header"));
        assert!(is_secret_config_key("secretAccessKey"));
        assert!(!is_secret_config_key("maxTokens"));
    }

    #[test]
    fn patch_preserves_stored_secrets_but_updates_other_settings() {
        let existing = serde_json::json!({
            "api_key": "STORED-SECRET",
            "base_url": "https://old.test/v1",
            "maxTokens": 100,
        })
        .as_object()
        .unwrap()
        .clone();
        let incoming = serde_json::json!({
            "apiKey": "CLIENT-SECRET",
            "baseUrl": "https://new.test/v1",
            "maxTokens": 200,
        })
        .as_object()
        .unwrap()
        .clone();
        let merged = merge_config_preserving_secrets(&existing, &incoming);
        assert_eq!(merged["api_key"], "STORED-SECRET");
        assert_eq!(merged["baseUrl"], "https://new.test/v1");
        assert_eq!(merged["maxTokens"], 200);
    }
    #[test]
    fn client_cannot_inject_secret_via_camelcase_key() {
        let existing = serde_json::json!({ "api_key": "STORED-SECRET" })
            .as_object()
            .unwrap()
            .clone();
        let incoming = serde_json::json!({ "apiKey": "CLIENT-SECRET", "maxTokens": 200 })
            .as_object()
            .unwrap()
            .clone();
        let merged = merge_config_preserving_secrets(&existing, &incoming);
        let safe = strip_secret_config_keys(&merged);
        assert_eq!(merged["api_key"], "STORED-SECRET");
        assert!(!safe.to_string().contains("CLIENT-SECRET"));
        assert!(!safe.to_string().contains("STORED-SECRET"));
        assert_eq!(safe["maxTokens"], 200);
    }

    #[test]
    fn rotation_replaces_matching_secret_by_normalized_name_only() {
        let existing = serde_json::json!({
            "api_key": "OLD-KEY",
            "access_token": "OLD-TOKEN",
            "base_url": "https://old.test/v1",
            "maxTokens": 100,
        })
        .as_object()
        .unwrap()
        .clone();
        let incoming = serde_json::json!({
            "apiKey": "NEW-KEY",
            "baseUrl": "https://new.test/v1",
            "maxTokens": 200,
        })
        .as_object()
        .unwrap()
        .clone();

        let merged = merge_config_rotating_secrets(&existing, &incoming);
        assert_eq!(merged["api_key"], "NEW-KEY");
        assert!(
            merged.get("apiKey").is_none(),
            "no duplicate camelCase key survives"
        );
        assert_eq!(merged["access_token"], "OLD-TOKEN");
        assert_eq!(merged["baseUrl"], "https://new.test/v1");
        assert_eq!(merged["maxTokens"], 200);
    }

    #[test]
    fn rotation_does_not_introduce_unknown_secret_keys() {
        let existing = serde_json::json!({ "api_key": "OLD-KEY" })
            .as_object()
            .unwrap()
            .clone();
        let incoming = serde_json::json!({
            "apiKey": "NEW-KEY",
            "authHeader": "EXTRA-SECRET",
            "baseUrl": "https://new.test/v1",
        })
        .as_object()
        .unwrap()
        .clone();

        let merged = merge_config_rotating_secrets(&existing, &incoming);
        assert_eq!(merged["api_key"], "NEW-KEY");
        assert!(merged.get("authHeader").is_none());
        assert_eq!(merged["baseUrl"], "https://new.test/v1");
    }

    #[test]
    fn storage_key_policy_covers_renamed_secret_shapes() {
        // Each row is a synthetic shape, not a stored key: renaming a credential
        // inside any family must still be excluded from backup/sync.
        for (key, expected) in [
            ("settings/credentials/new-provider", true),
            ("settings/free-hub/renamed/key", true),
            ("settings/mcp/config", true),
            ("local:peers/device-keypair", true),
            ("local:providers", true),
            ("cf_newflow_verifier", true),
            ("settings/sync/s3-new-key-id", true),
            ("settings/cloudflare/cfNewAccountId", true),
            ("settings/cloudflare/cfOAuthTokensRenamed", true),
            ("settings/server-channel/websocket-tls-config", true),
            // Ordinary neighbours must stay syncable.
            ("settings/sync/s3-endpoint", false),
            ("settings/cloudflare/cfSubdomain", false),
            ("settings/discord/enabled", false),
            ("settings/region", false),
            // A whole-branch rule would silently drop these from backup.
            ("local:provider-catalog", false),
            ("settings/providers/added", false),
            ("settings/consciousness/active-provider", false),
            ("local:peers/roster", false),
            ("settings/mcp/server-args", false),
        ] {
            assert_eq!(is_secret_key(key), expected, "classification of {key}");
        }
    }

    #[test]
    fn storage_policy_patterns_are_shapes_not_stored_keys() {
        for pattern in SECRET_STORAGE_KEY_SUBSTRINGS
            .iter()
            .chain(SECRET_STORAGE_KEY_PREFIXES.iter())
        {
            // Patterns are shapes: no values, no uppercase, no wildcards.
            assert!(
                !pattern.contains('=') && !pattern.contains('*'),
                "pattern must be a shape: {pattern}"
            );
            assert!(
                pattern.chars().all(|c| !c.is_ascii_uppercase()),
                "pattern must be lowercase: {pattern}"
            );
        }
        assert!(is_secret_storage_key("local:peers/device-keypair"));
        assert!(is_secret_storage_key("settings/mcp/config"));
        assert!(!is_secret_storage_key("local:peers/roster"));
        assert!(!is_secret_storage_key("settings/mcp/server-args"));
    }

    #[test]
    fn legacy_snake_case_aliases_normalize_to_camel_case() {
        let legacy = serde_json::json!({
            "openrouter-ai": {
                "api_key": "sk-or-alias",
                "base_url": "https://openrouter.example/api",
                "aws_access_key_id": "AKIA-ALIAS",
                "aws_secret_access_key": "aws-secret-alias",
            },
        });
        let migrated = migrate_legacy_provider_credential_keys(&legacy).unwrap();
        let options = &migrated["openrouter-ai:*"];
        assert!(options["apiKey"].as_str() == Some("sk-or-alias"));
        assert!(options["baseUrl"].as_str() == Some("https://openrouter.example/api"));
        assert!(options["awsAccessKeyId"].as_str() == Some("AKIA-ALIAS"));
        assert!(options["awsSecretAccessKey"].as_str() == Some("aws-secret-alias"));
        // Aliases are filled, not renamed: the snake_case originals survive.
        assert!(options["api_key"].as_str() == Some("sk-or-alias"));
    }

    #[test]
    fn existing_camel_case_canonical_wins_over_snake_alias() {
        let legacy = serde_json::json!({
            "provider": { "apiKey": "sk-canonical", "api_key": "sk-alias" },
        });
        let migrated = migrate_legacy_provider_credential_keys(&legacy).unwrap();
        assert!(migrated["provider:*"]["apiKey"].as_str() == Some("sk-canonical"));
    }

    #[test]
    fn already_v2_snapshot_is_not_remigrated() {
        let snapshot = serde_json::json!({
            "version": 2,
            "instancesByInstanceKey": { "provider:*": { "options": {} } },
        });
        assert!(migrate_legacy_provider_credential_keys(&snapshot).is_none());
    }

    #[test]
    fn primary_infix_normalizes_instance_keys() {
        assert_eq!(clean_instance_infix("openai", None), "*");
        assert_eq!(clean_instance_infix("openai", Some("")), "*");
        assert_eq!(clean_instance_infix("openai", Some("*")), "*");
        assert_eq!(clean_instance_infix("openai", Some("openai:work")), "work");
        assert_eq!(
            clean_instance_infix("openai", Some("openai:openai:deep")),
            "deep"
        );
        assert_eq!(provider_instance_storage_key("openai", None), "openai:*");
        assert_eq!(
            provider_instance_storage_key("openai", Some("openai:work")),
            "openai:work"
        );

        let legacy = serde_json::json!({ "openai": { "apiKey": "sk-primary" } });
        let migrated = migrate_legacy_provider_credential_keys(&legacy).unwrap();
        assert_eq!(migrated.len(), 1);
        assert!(migrated.contains_key("openai:*"));
    }

    #[test]
    fn empty_credential_stubs_are_discarded() {
        for empty in [
            serde_json::json!({}),
            serde_json::json!({ "apiKey": "   " }),
            serde_json::json!({ "apiKey": null }),
            serde_json::json!({ "apiKey": [] }),
            serde_json::json!({ "credentials": { "token": "", "region": null } }),
        ] {
            let options = empty.as_object().unwrap().clone();
            assert!(is_empty_credential_stub(&options), "expected an empty stub");
        }
        let real = serde_json::json!({ "apiKey": "sk-real" })
            .as_object()
            .unwrap()
            .clone();
        assert!(!is_empty_credential_stub(&real));

        let legacy = serde_json::json!({
            "nothing": {},
            "blank": { "apiKey": "  " },
            "real": { "apiKey": "sk-real" },
        });
        let migrated = migrate_legacy_provider_credential_keys(&legacy).unwrap();
        assert_eq!(migrated.len(), 1);
        assert!(migrated.contains_key("real:*"));
    }

    #[test]
    fn normalized_keys_merge_preserves_stored_secrets() {
        let stored = serde_json::json!({
            "api_key": "STORED-SECRET",
            "base_url": "https://old.test/v1",
        })
        .as_object()
        .unwrap()
        .clone();
        let legacy = serde_json::json!({
            "api_key": "STORED-SECRET",
            "base_url": "https://old.test/v1",
        })
        .as_object()
        .unwrap()
        .clone();
        let normalized = normalize_legacy_credential_keys(&legacy);
        assert!(normalized["apiKey"].as_str() == Some("STORED-SECRET"));

        // An incoming patch cannot rotate a managed secret by echoing its
        // camelCase spelling; the shared merge helper keeps the stored value.
        let incoming = serde_json::json!({
            "apiKey": "CLIENT-SECRET",
            "baseUrl": "https://new.test/v1",
        })
        .as_object()
        .unwrap()
        .clone();
        let merged = merge_config_preserving_secrets(&stored, &incoming);
        let safe = strip_secret_config_keys(&merged);
        assert!(merged["api_key"].as_str() == Some("STORED-SECRET"));
        assert_eq!(merged["baseUrl"], "https://new.test/v1");
        assert!(!safe.to_string().contains("CLIENT-SECRET"));
        assert!(!safe.to_string().contains("STORED-SECRET"));
    }

    #[test]
    fn only_the_four_known_aliases_gain_camel_keys() {
        // Parity with instance-store.ts:63-68: unknown host-specific snake keys
        // are left untouched, never given a camelCase twin.
        let options = serde_json::json!({
            "api_key": "sk-known",
            "cf_account_id": "acct-unknown",
            "custom_setting": "custom",
        })
        .as_object()
        .unwrap()
        .clone();
        let normalized = normalize_legacy_credential_keys(&options);
        assert!(normalized["apiKey"].as_str() == Some("sk-known"));
        assert!(normalized.get("cfAccountId").is_none());
        assert!(normalized.get("customSetting").is_none());
        assert!(normalized["cf_account_id"].as_str() == Some("acct-unknown"));

        let legacy = serde_json::json!({
            "provider": { "api_key": "sk-known", "cf_account_id": "acct-unknown" },
        });
        let migrated = migrate_legacy_provider_credential_keys(&legacy).unwrap();
        let row = &migrated["provider:*"];
        assert!(row["apiKey"].as_str() == Some("sk-known"));
        assert!(row.get("cfAccountId").is_none());
    }

    #[test]
    fn exact_null_canonical_blocks_alias_fill() {
        // TS checks `normalized[canonical] === undefined`; null is present.
        let options = serde_json::json!({ "apiKey": null, "api_key": "sk-alias" })
            .as_object()
            .unwrap()
            .clone();
        let normalized = normalize_legacy_credential_keys(&options);
        assert!(normalized["apiKey"].is_null());
        assert!(normalized["api_key"].as_str() == Some("sk-alias"));
    }

    #[test]
    fn near_spelling_canonical_does_not_block_alias_fill() {
        for raw in [
            serde_json::json!({ "apikey": "sk-near", "api_key": "sk-alias" }),
            serde_json::json!({ "api-key": "sk-near", "api_key": "sk-alias" }),
            serde_json::json!({ "ApiKey": "sk-near", "api_key": "sk-alias" }),
        ] {
            let options = raw.as_object().unwrap().clone();
            let normalized = normalize_legacy_credential_keys(&options);
            assert!(normalized["apiKey"].as_str() == Some("sk-alias"));
        }
    }

    #[test]
    fn usable_alias_wins_over_empty_alias_for_same_canonical() {
        let options = serde_json::json!({ "API_KEY": "", "api_key": "sk-real" })
            .as_object()
            .unwrap()
            .clone();
        let normalized = normalize_legacy_credential_keys(&options);
        assert!(normalized["apiKey"].as_str() == Some("sk-real"));
    }

    #[test]
    fn foreign_input_and_array_instance_map_pass_through() {
        // Some(empty map) here would let a caller wipe stored credentials.
        for raw in [
            serde_json::Value::Null,
            serde_json::json!([]),
            serde_json::json!("foreign"),
            serde_json::json!(42),
            serde_json::json!(true),
            // TS treats an array `instancesByInstanceKey` as an object.
            serde_json::json!({ "version": 2, "instancesByInstanceKey": [] }),
        ] {
            assert!(
                migrate_legacy_provider_credential_keys(&raw).is_none(),
                "foreign input must pass through"
            );
        }
    }
}
