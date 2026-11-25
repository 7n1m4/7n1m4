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

/// TS `isSecretConfigKey`: normalized names ending in `key`/`token` or
/// containing an auth word are secrets. Used to keep pooled/system-row
/// credentials out of thin-client replies (`toSafeSystemRow` in the TS
/// reference) and to stop a PATCH from rotating a managed secret.
pub fn is_secret_config_key(key: &str) -> bool {
    let normalized = normalize_config_key(key);
    const SUBSTRINGS: &[&str] = &[
        "apikey",
        "authheader",
        "authorization",
        "secret",
        "password",
        "credential",
        "bearer",
    ];
    const SUFFIXES: &[&str] = &["token", "key"];
    SUBSTRINGS.iter().any(|s| normalized.contains(s))
        || SUFFIXES.iter().any(|s| normalized.ends_with(s))
}

/// Match wire (`apiKey`) and stored (`api_key`) spellings of the same key.
fn normalize_config_key(key: &str) -> String {
    key.chars()
        .filter(|c| c.is_ascii_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
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
}
