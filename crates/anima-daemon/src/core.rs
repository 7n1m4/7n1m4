// SPDX-License-Identifier: GPL-3.0-or-later

//! Daemon-owned `airi-core` service.
//!
//! This is the ONLY place the daemon touches core state. It opens the
//! application store using the same profile/identity rules Slint uses today
//! and fails closed on open error: no empty/temp/fallback database.
//!
//! ## Single-writer invariant
//! `CoreService::open` opens the profile's `airi.sqlite` once for the daemon;
//! client profiles stay separate and never open the daemon store. A failed
//! open yields unavailable with no empty/temp/fallback database; `status_reply`
//! exposes only secret-free coarse health, and
//! `crates/anima-daemon/tests/ownership.rs` covers the matrix.
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use anima_core::AppCore;
use anima_store::{Database, StoredProvider};

type SettingsLoadFn = fn(&anima_core::settings::SettingsStore) -> Result<serde_json::Value, String>;
type SettingsSaveFn =
    fn(&anima_core::settings::SettingsStore, serde_json::Value) -> Result<(), String>;

/// Build the settings registry from `(wire key, section type)` pairs.
///
/// Every type is constrained by `SettingsSection` at compile time, so adding a
/// stale section (e.g. `ActiveProviderSettings`) fails to compile instead of
/// silently drifting from the types `anima-core` actually registers.
macro_rules! settings_sections {
    ($(($key:literal, $type:ty)),+ $(,)?) => {
        const SETTINGS_SECTIONS: &[(&str, SettingsLoadFn, SettingsSaveFn)] = &[
            $((
                $key,
                load_section::<$type>,
                save_section::<$type>,
            )),+
        ];
    };
}

fn load_section<S: anima_core::settings::SettingsSection>(
    store: &anima_core::settings::SettingsStore,
) -> Result<serde_json::Value, String> {
    serde_json::to_value(
        store
            .load_section::<S>()
            .map_err(|_| "load failed".to_string())?,
    )
    .map_err(|_| "serialize failed".to_string())
}

fn save_section<S: anima_core::settings::SettingsSection>(
    store: &anima_core::settings::SettingsStore,
    patch: serde_json::Value,
) -> Result<(), String> {
    let parsed = merged_section::<S>(store, patch)?;
    store
        .save_section(&parsed)
        .map_err(|_| "save failed".to_string())
}

/// Merge a wire PATCH into one persisted section and return the typed blob.
///
/// `settings.set` is a PATCH. Start from the persisted blob so an older
/// client that sends only the field it edited cannot wipe the rest of the
/// section. Typed deserialization of the merged value still rejects
/// unknown fields and invalid shapes before anything is persisted.
fn merged_section<S: anima_core::settings::SettingsSection>(
    store: &anima_core::settings::SettingsStore,
    patch: serde_json::Value,
) -> Result<S, String> {
    let patch = patch
        .as_object()
        .ok_or_else(|| "invalid settings shape".to_string())?;
    let mut merged = store
        .load_opt::<serde_json::Value>(S::KEY)
        .map_err(|_| "load failed".to_string())?
        .and_then(|value| value.as_object().cloned())
        .unwrap_or_default();
    for (key, value) in patch {
        if value.is_null() {
            merged.remove(key);
        } else {
            merged.insert(key.clone(), value.clone());
        }
    }
    serde_json::from_value(serde_json::Value::Object(merged))
        .map_err(|_| "invalid settings shape".to_string())
}

settings_sections!(
    ("general", anima_core::settings::GeneralSettings),
    ("chat", anima_core::settings::ChatSettings),
    ("theme", anima_core::settings::ThemeSettings),
    ("control-strip", anima_core::settings::ControlStripSettings),
    ("cards", anima_core::settings::CardsSettings),
    ("stage-model", anima_core::settings::StageModelSettings),
    ("captions", anima_core::settings::CaptionsSettings),
    ("stage-window", anima_core::settings::StageWindowSettings),
    ("positioning", anima_core::settings::PositioningSettings),
    ("spine", anima_core::settings::SpineSettings),
    ("mmd", anima_core::settings::MmdSettings),
    ("live2d", anima_core::settings::Live2dSettings),
    ("audio-device", anima_core::settings::AudioDeviceSettings),
    ("user-profile", anima_core::settings::UserProfileSettings),
    ("local-llm", anima_core::settings::LocalLlmSettings),
    ("consciousness", anima_core::settings::ConsciousnessSettings),
    ("chat-provider", anima_core::settings::ChatProviderSettings),
    ("speech", anima_core::settings::SpeechSettings),
    ("hearing", anima_core::settings::HearingSettings),
    ("vision", anima_core::settings::VisionSettings),
);

/// Resolve a settings-section name to its typed load/save operations.
///
/// Single source of truth for the supported sections: `settings_get` and
/// `settings_set` both route through here, so registering a section is one edit
/// in [`settings_sections!`].
fn settings_section(section: &str) -> Option<(SettingsLoadFn, SettingsSaveFn)> {
    SETTINGS_SECTIONS
        .iter()
        .find(|(key, _, _)| *key == section)
        .map(|(_, load, save)| (*load, *save))
}

/// Merge a primary PATCH and its mirror selection, then commit both in one
/// transaction so a rejected mirror cannot leave a half-applied selection.
fn save_mirrored<P, M>(
    store: &anima_core::settings::SettingsStore,
    patch: serde_json::Value,
    selection: serde_json::Map<String, serde_json::Value>,
) -> Result<(), String>
where
    P: anima_core::settings::SettingsSection,
    M: anima_core::settings::SettingsSection,
{
    let primary = merged_section::<P>(store, patch)?;
    let mirror = merged_section::<M>(store, serde_json::Value::Object(selection))?;
    store
        .save_pair((P::KEY, &primary), (M::KEY, &mirror))
        .map_err(|_| "save failed".to_string())
}

/// Project a stored provider into the secret-free wire DTO.
///
/// `ProviderInfo` has no config field, but system/pooled rows carry managed
/// credentials in their config blob. Strip secret-shaped keys before reading
/// any settings out of it so a future DTO field cannot leak them by accident.
fn provider_info(p: &StoredProvider) -> anima_channel::wire::ProviderInfo {
    let config = anima_core::providers::strip_secret_config_keys(&p.config);
    let config = config.as_object();
    anima_channel::wire::ProviderInfo {
        id: p.id.clone(),
        kind: serde_json::to_string(&p.kind)
            .unwrap_or_else(|_| "\"unknown\"".to_string())
            .trim_matches('"')
            .to_string(),
        model: config
            .and_then(|o| o.get("model"))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        // `ProviderConfig` serializes this as `base_url`; only older/foreign
        // rows carry the camelCase spelling. Reading just `baseUrl` reported
        // an empty base URL for every provider written through the daemon.
        base_url: config
            .and_then(|o| o.get("base_url").or_else(|| o.get("baseUrl")))
            .and_then(|v| v.as_str())
            .unwrap_or("")
            .to_string(),
        enabled: p.enabled,
        updated_at: p.updated_at,
    }
}

/// Coarse, secret-free snapshot of core/store availability.
#[derive(Debug, Clone)]
pub struct CoreSnapshot {
    /// Whether the store/core opened successfully.
    pub available: bool,
    /// Sanitized reason when unavailable (no secrets, no paths).
    pub reason: Option<String>,
    /// Number of persisted sessions (0 when unavailable).
    pub session_count: u64,
    /// Number of persisted messages (0 when unavailable).
    pub message_count: u64,
}

/// Owns the daemon-side core state. Shared via `Arc`; handlers read a
/// snapshot without holding a lock across `.await`.
#[derive(Clone)]
pub struct CoreService {
    inner: Arc<Mutex<CoreInner>>,
}

struct CoreInner {
    core: Option<AppCore>,
    available: bool,
    reason: Option<String>,
    session_count: u64,
    message_count: u64,
}

/// Shared id normalization for card metadata reads and writes: both paths must
/// trim client-supplied ids identically, otherwise a whitespace-padded id
/// writes one row and reads a different one.
fn normalized_card_id(id: &str) -> Result<&str, String> {
    let id = id.trim();
    if id.is_empty() {
        return Err("missing id".to_string());
    }
    Ok(id)
}

impl CoreService {
    /// Open the store using the same rules as Slint: an explicit profile dir
    /// wins, otherwise the platform data dir + `airi-slint/airi.sqlite`.
    pub fn open(profile: Option<PathBuf>) -> Self {
        let path = match profile {
            Some(p) => p.join("airi.sqlite"),
            None => match dirs::data_dir() {
                Some(d) => d.join("airi-slint").join("airi.sqlite"),
                None => {
                    return Self::unavailable("no platform data directory".to_string());
                }
            },
        };

        match Database::open(&path) {
            Ok(db) => {
                // `list()`/`list_all()` materialized the entire messages table
                // just to take `.len()`. Two `count(*)` queries give the same
                // status numbers without a full-table scan at startup.
                let (sessions, messages) = Self::quick_counts(&db).unwrap_or((0, 0));
                let core = AppCore::new(db);
                Self {
                    inner: Arc::new(Mutex::new(CoreInner {
                        core: Some(core),
                        available: true,
                        reason: None,
                        session_count: sessions,
                        message_count: messages,
                    })),
                }
            }
            Err(_) => Self::unavailable("store open failed".to_string()),
        }
    }

    fn unavailable(reason: String) -> Self {
        Self {
            inner: Arc::new(Mutex::new(CoreInner {
                core: None,
                available: false,
                reason: Some(reason),
                session_count: 0,
                message_count: 0,
            })),
        }
    }

    /// Cheap session/message counts for the health snapshot. Uses the same
    /// public `with_connection` escape hatch `anima_core::vault::stats` uses;
    /// no full-row materialization.
    fn quick_counts(db: &anima_store::Database) -> Result<(u64, u64), String> {
        db.with_connection(|conn| {
            let sessions: i64 =
                conn.query_row("select count(*) from sessions", [], |r| r.get(0))?;
            let messages: i64 =
                conn.query_row("select count(*) from messages", [], |r| r.get(0))?;
            Ok((sessions as u64, messages as u64))
        })
        .map_err(|_| "count query failed".to_string())
    }

    /// Whether core/store is available.
    pub fn available(&self) -> bool {
        self.inner.lock().map(|g| g.available).unwrap_or(false)
    }

    /// Read a snapshot without holding the lock across await.
    pub fn snapshot(&self) -> CoreSnapshot {
        let g = self.inner.lock().expect("core service mutex poisoned");
        CoreSnapshot {
            available: g.available,
            reason: g.reason.clone(),
            session_count: g.session_count,
            message_count: g.message_count,
        }
    }

    /// Map a snapshot into the channel wire DTO.
    pub fn status_reply(&self) -> anima_channel::wire::CoreStatusReply {
        let snap = self.snapshot();
        anima_channel::wire::CoreStatusReply {
            app: env!("CARGO_PKG_NAME").to_string(),
            version: env!("CARGO_PKG_VERSION").to_string(),
            core_available: snap.available,
            store_available: snap.available,
            store_health: if snap.available {
                "ok".to_string()
            } else {
                "unavailable".to_string()
            },
            protocol: "airi-channel/1".to_string(),
            session_count: snap.session_count,
            message_count: snap.message_count,
        }
    }

    /// List all configured providers (metadata only, no secrets).
    pub fn providers_list(&self) -> Result<anima_channel::wire::ProvidersListReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let repo = core.provider_repo();
        let providers = repo.list().map_err(|_| "store query failed".to_string())?;
        let infos = providers.into_iter().map(|p| provider_info(&p)).collect();
        Ok(anima_channel::wire::ProvidersListReply { providers: infos })
    }

    /// Discover models for one enabled provider. The core mutex is
    /// released before any network model discovery so long-running requests
    /// cannot stall other daemon operations; only non-secret model metadata is
    /// projected onto the wire.
    pub fn providers_models(
        &self,
        request: &anima_channel::wire::ProvidersModelsRequest,
    ) -> Result<anima_channel::wire::ProvidersModelsReply, String> {
        let (chat, providers, settings) = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            let core = guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?;
            let repo = core.provider_repo();
            let mut providers = repo.list().map_err(|_| "store query failed".to_string())?;
            providers.retain(|p| p.enabled);
            if let Some(id) = request.provider_id.as_deref() {
                if !providers.iter().any(|p| p.id == id) {
                    return Err("provider not found".to_string());
                }
                providers.retain(|p| p.id == id);
            }
            let settings = anima_store::SettingsRepo::new(core.db.clone());
            (core.chat.clone(), providers, settings)
        };
        if providers.len() != 1 {
            return Err("provider not found".to_string());
        }
        let p = providers.into_iter().next().unwrap();
        let models = chat_runtime().block_on(async {
            let resolved = anima_core::chat::resolve_provider(
                &chat.providers,
                &chat.registry(),
                &p.id,
                serde_json::from_value(p.config.clone()).unwrap_or_default(),
                Some(&settings),
            )
            .await
            .map_err(|_| "provider model discovery failed".to_string())?;
            resolved
                .models()
                .await
                .map_err(|_| "provider model discovery failed".to_string())
        })?;
        Ok(anima_channel::wire::ProvidersModelsReply {
            provider_id: p.id.clone(),
            models: models
                .into_iter()
                .map(|m| anima_channel::wire::ProviderModelInfo {
                    id: m.id,
                    owned_by: m.owned_by,
                })
                .collect(),
        })
    }

    /// Create or update a provider through the daemon-owned `ProviderRepo`.
    /// Accepts the secret only on input; the returned id is safe to put on the
    /// wire. Missing fields keep the stored value so a partial update cannot
    /// silently drop an api key. Credential-shaped keys are preserved unless
    /// the caller opts into rotation with the literal `rotateSecrets: true`.
    pub fn providers_save(&self, payload: &serde_json::Value) -> Result<String, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        let repo = core.provider_repo();
        let id = payload
            .get("id")
            .or_else(|| payload.get("providerId"))
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .ok_or_else(|| "missing id".to_string())?;
        // Normalize the wire value once: the definition guard and the save
        // path must agree on what a kind is, padded or not.
        let kind_text = payload
            .get("kind")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty());
        if let Some(definition_id) = payload
            .get("definitionId")
            .and_then(|v| v.as_str())
            .map(str::trim)
            .filter(|s| !s.is_empty())
        {
            let registry = anima_llm::ProviderRegistry::new();
            let def = registry
                .get(definition_id)
                .ok_or_else(|| format!("unknown provider definition: {definition_id}"))?;
            if let Some(text) = kind_text {
                let requested: anima_store::ProviderKind =
                    serde_json::from_value(serde_json::Value::String(text.to_string()))
                        .map_err(|_| format!("unknown provider kind: {text}"))?;
                if serde_json::to_string(&requested).ok().as_deref()
                    != Some(&serde_json::to_string(&def.kind).unwrap_or_default())
                {
                    return Err(format!(
                        "provider kind {text} does not match definition {definition_id}"
                    ));
                }
            }
        }
        let existing = repo
            .get(id)
            .map_err(|_| "provider query failed".to_string())?;
        // A PATCH that omits `kind` (e.g. `{id, enabled:false}`) reuses the stored
        // kind; an explicit unknown kind still errors.
        let kind: anima_store::ProviderKind = match kind_text {
            Some(text) => serde_json::from_value(serde_json::Value::String(text.to_string()))
                .map_err(|_| format!("unknown provider kind: {text}"))?,
            None => existing
                .as_ref()
                .map(|p| p.kind.clone())
                .ok_or_else(|| "missing kind".to_string())?,
        };
        let rotate_secrets = payload
            .get("rotateSecrets")
            .map(|v| {
                v.as_bool()
                    .ok_or_else(|| "rotateSecrets must be a boolean".to_string())
            })
            .transpose()?
            .unwrap_or(false);

        let stored_config = existing
            .as_ref()
            .and_then(|p| p.config.as_object().cloned())
            .unwrap_or_default();
        let enabled = payload
            .get("enabled")
            .and_then(|v| v.as_bool())
            .unwrap_or_else(|| existing.as_ref().map_or(true, |p| p.enabled));
        // `ProviderConfig` stores snake_case; clients speak the wire's
        // camelCase. Accept both spellings on input. Start from the stored
        // config so a PATCH preserves non-secret extras it does not mention.
        let mut incoming = stored_config.clone();
        for (wire_key, stored_key) in [
            ("model", "model"),
            ("baseUrl", "base_url"),
            ("base_url", "base_url"),
            ("apiKey", "api_key"),
            ("api_key", "api_key"),
        ] {
            if let Some(value) = payload.get(wire_key).and_then(|v| v.as_str()) {
                incoming.insert(
                    stored_key.to_string(),
                    serde_json::Value::String(value.to_string()),
                );
            }
        }
        // By default a client-supplied apiKey must never rotate a
        // daemon-managed credential: stored secret-shaped keys win over every
        // incoming spelling, including camelCase aliases (TS
        // `mergeConfigPreservingSecrets` parity). Only an explicit opt-in lets
        // the new value through for the matching stored key.
        let merged = if rotate_secrets {
            anima_core::providers::merge_config_rotating_secrets(&stored_config, &incoming)
        } else {
            anima_core::providers::merge_config_preserving_secrets(&stored_config, &incoming)
        };
        repo.upsert(&StoredProvider {
            id: id.to_string(),
            kind,
            config: merged,
            enabled,
            updated_at: 0, // upsert stamps the current time
        })
        .map_err(|_| "provider save failed".to_string())?;
        Ok(id.to_string())
    }

    /// Delete a provider by id. Returns whether a row was actually removed.
    pub fn providers_delete(&self, id: &str) -> Result<bool, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        core.provider_repo()
            .delete(id)
            .map_err(|_| "provider delete failed".to_string())
    }

    /// Subscribe to the core's internal event bus (used to bridge settings
    /// changes to gateway clients).
    pub fn subscribe_core_events(
        &self,
    ) -> Option<tokio::sync::broadcast::Receiver<anima_core::CoreEvent>> {
        let guard = self.inner.lock().ok()?;
        guard.core.as_ref().map(|core| core.subscribe())
    }

    /// Get a typed settings section.
    pub fn settings_get(
        &self,
        section: &str,
    ) -> Result<anima_channel::wire::SettingsGetReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let store = core.settings();
        let (load, _) = settings_section(section)
            .ok_or_else(|| format!("unknown settings section: {section}"))?;
        let value = load(&store)?;
        let value_str =
            serde_json::to_string(&value).map_err(|_| "serialize failed".to_string())?;
        Ok(anima_channel::wire::SettingsGetReply {
            section: section.to_string(),
            settings: value_str,
        })
    }

    /// Set a typed settings section.
    pub fn settings_set(
        &self,
        section: &str,
        settings: serde_json::Value,
    ) -> Result<anima_channel::wire::SettingsSetReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let store = core.settings();
        // Only the chat provider/model selection has a twin section. Other
        // sections also carry an `activeProvider` field (speech, hearing) and
        // must use their normal typed save path.
        let selection = if matches!(section, "chat-provider" | "consciousness") {
            settings
                .as_object()
                .map(|o| {
                    o.iter()
                        .filter(|(key, _)| *key == "activeProvider" || *key == "activeModel")
                        .filter_map(|(key, value)| {
                            value
                                .as_str()
                                .map(|v| (key.clone(), serde_json::Value::String(v.to_string())))
                        })
                        .collect::<serde_json::Map<_, _>>()
                })
                .filter(|o| !o.is_empty())
        } else {
            None
        };
        if let Some(selection) = selection {
            match section {
                "chat-provider" => save_mirrored::<
                    anima_core::settings::ChatProviderSettings,
                    anima_core::settings::ConsciousnessSettings,
                >(&store, settings, selection),
                "consciousness" => save_mirrored::<
                    anima_core::settings::ConsciousnessSettings,
                    anima_core::settings::ChatProviderSettings,
                >(&store, settings, selection),
                // Unknown sections still fail with the same message as before.
                _ => Err(format!("unknown settings section: {section}")),
            }?;
        } else {
            // Unmirrored edits use the existing section table.
            let (_, save) = settings_section(section)
                .ok_or_else(|| format!("unknown settings section: {section}"))?;
            save(&store, settings)?;
        }
        Ok(anima_channel::wire::SettingsSetReply { ok: true })
    }

    /// Resolve a display model descriptor by id.
    pub fn resolve_display_model(
        &self,
        id: &str,
    ) -> Result<anima_channel::wire::CatalogDescriptor, String> {
        let id = id.trim();
        if id.is_empty() {
            return Err("missing display model id".to_string());
        }
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let store = core.settings();
        let settings: anima_core::settings::StageModelSettings = store
            .load_section::<anima_core::settings::StageModelSettings>()
            .map_err(|_| "load failed".to_string())?;
        settings
            .catalog
            .into_iter()
            .find(|e| e.id == id)
            .ok_or_else(|| format!("unknown display model id: {id}"))
    }

    pub fn vault_status(&self) -> Result<anima_channel::wire::VaultStatusReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Ok(anima_channel::wire::VaultStatusReply {
                available: false,
                stats: None,
            });
        };
        let stats = anima_core::vault::stats(&core.db, &[])
            .map_err(|_| "vault stats failed".to_string())?;

        let mut chats = (0u64, 0u64, 0u64);
        let mut memory = (0u64, 0u64, 0u64);
        let mut providers = (0u64, 0u64);
        let mut characters = (0u64, 0u64);

        for domain in &stats.domains {
            match domain.id.as_str() {
                "chats" => {
                    chats.2 = domain.bytes;
                    chats.0 = domain.count;
                }
                "messages" => {
                    chats.1 = domain.count;
                }
                "memory" => {
                    memory.2 = domain.bytes;
                    memory.0 = domain.count;
                }
                "journal_entries" => {
                    memory.1 = domain.count;
                }
                "providers" => {
                    providers.0 = domain.count;
                    providers.1 = domain.bytes;
                }
                "characters" => {
                    characters.0 = domain.count;
                    characters.1 = domain.bytes;
                }
                _ => {}
            }
        }

        let stats_data = anima_channel::wire::VaultStatsData {
            chats: anima_channel::wire::DomainStatsData {
                sessions: chats.0 as u32,
                messages: chats.1 as u32,
                bytes: chats.2 as u32,
            },
            memory: anima_channel::wire::MemoryStatsData {
                summaries: memory.0 as u32,
                journal_entries: memory.1 as u32,
                bytes: memory.2 as u32,
            },
            providers: anima_channel::wire::ProviderStatsData {
                count: providers.0 as u32,
                bytes: providers.1 as u32,
            },
            characters: anima_channel::wire::CharacterStatsData {
                count: characters.0 as u32,
                bytes: characters.1 as u32,
            },
        };
        Ok(anima_channel::wire::VaultStatusReply {
            available: true,
            stats: Some(stats_data),
        })
    }

    /// Persist a user turn into a session through the daemon-owned store
    /// (single writer). Creates the session on demand.
    pub fn chat_send(
        &self,
        session_id: &str,
        content: &str,
    ) -> Result<anima_store::StoredMessage, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        core.append_user_turn_with_session(session_id, content)
            .map_err(|_| "message append failed".to_string())
    }

    /// Ensure the requested session row exists before `send_message` runs.
    ///
    /// `ChatService::ensure_session` only honours an explicit id when that row
    /// already exists; otherwise it mints a new id. Without this, passing
    /// `Some(&sid)` would still stream the reply into a different session than
    /// the one returned in `chat.send`'s ack (and `chat.cancel` would flag the
    /// wrong one). This creates the session only — `send_message` writes the
    /// user turn, so there is no duplicate message.
    pub fn ensure_chat_session(&self, session_id: &str) -> Result<(), String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        let sessions = anima_store::SessionRepo::new(core.db.clone());
        if sessions
            .get(session_id)
            .map_err(|_| "session query failed".to_string())?
            .is_none()
        {
            sessions
                .create(session_id, session_id)
                .map_err(|_| "session create failed".to_string())?;
        }
        Ok(())
    }

    /// Replay the persisted messages of a session from the daemon-owned store.
    pub fn chat_stream(&self, session_id: &str) -> Result<Vec<anima_store::StoredMessage>, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        let messages = anima_store::MessageRepo::new(core.db.clone());
        messages
            .list(session_id)
            .map_err(|_| "message list failed".to_string())
    }

    /// Clone the daemon-owned chat service (single writer), if available.
    pub fn chat_service(&self) -> Option<anima_core::ChatService> {
        let guard = self.inner.lock().ok()?;
        guard.core.as_ref().map(|c| c.chat.clone())
    }

    /// Raw provider rows (configuration may include secrets) for daemon-owned
    /// chat sending. Callers must never serve these over RPC.
    pub fn provider_rows(&self) -> Result<Vec<anima_store::StoredProvider>, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard
            .core
            .as_ref()
            .ok_or_else(|| "store unavailable".to_string())?;
        core.provider_repo()
            .list()
            .map_err(|_| "provider list failed".to_string())
    }

    /// Request cancellation of an in-flight generation.
    ///
    /// A multi-thread runtime is a whole reactor; building one per cancel is
    /// pure overhead, and `block_on` is callable from many threads.
    pub fn chat_stop(&self, session_id: &str) -> Result<bool, String> {
        let svc = self
            .chat_service()
            .ok_or_else(|| "store unavailable".to_string())?;
        chat_runtime()
            .block_on(svc.stop(session_id.to_string()))
            .map_err(|e| e.to_string())
    }

    /// Cancel an in-flight generation for `session_id`.
    ///
    /// `ChatService` owns the single per-turn flag; the daemon registers it
    /// before spawning the background turn, so this is authoritative even for
    /// a cancel arriving immediately after the `chat.send` ack.
    pub fn chat_cancel(&self, session_id: &str) -> bool {
        self.chat_stop(session_id).unwrap_or(false)
    }

    /// Delete a session and its messages through the daemon-owned store.
    ///
    /// The daemon is the only writer: thin clients never touch SQLite. Returns
    /// `true` when the session existed; `false` is a success, not an error, so
    /// a client can treat "already gone" as an idempotent delete. The cached
    /// status counts are refreshed on success so `core.status` does not keep
    /// reporting a deleted session.
    pub fn session_delete(&self, session_id: &str) -> Result<bool, String> {
        let (svc, db) = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            let core = guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?;
            (core.chat.clone(), core.db.clone())
        };
        let deleted = chat_runtime()
            .block_on(svc.delete_session(session_id.to_string()))
            .map_err(|e| e.to_string())?;
        if deleted {
            if let Ok((sessions, messages)) = Self::quick_counts(&db) {
                let mut guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
                guard.session_count = sessions;
                guard.message_count = messages;
            }
        }
        Ok(deleted)
    }

    /// Daemon-owned short-term memory (STMM) service, sharing the store and
    /// provider table. Single writer.
    pub fn stmm_service(&self) -> Option<anima_core::memory::ShortTermMemoryService> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(
            anima_core::memory::ShortTermMemoryService::with_shared_providers(
                core.db.clone(),
                core.providers.clone(),
                Default::default(),
            ),
        )
    }

    /// Daemon-owned text journal service. Single writer.
    pub fn journal_service(&self) -> Option<anima_core::memory::TextJournalService> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(anima_core::memory::TextJournalService::new(core.db.clone()))
    }

    /// Daemon-owned retrieval service bound to the supplied embedder.
    pub fn retrieval_service(
        &self,
        embedder: std::sync::Arc<dyn anima_core::memory::embedding::Embedder>,
    ) -> Option<anima_core::memory::retrieval::MemoryRetrieval> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(anima_core::memory::retrieval::MemoryRetrieval::new(
            core.db.clone(),
            embedder,
        ))
    }

    /// Daemon-owned memory indexer bound to the supplied embedder.
    pub fn memory_indexer(
        &self,
        embedder: std::sync::Arc<dyn anima_core::memory::embedding::Embedder>,
    ) -> Option<anima_core::memory::retrieval::MemoryIndexer> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(anima_core::memory::retrieval::MemoryIndexer::new(
            core.db.clone(),
            embedder,
        ))
    }

    /// Daemon-owned database handle (single writer).
    pub fn db(&self) -> Option<anima_store::Database> {
        let guard = self.inner.lock().ok()?;
        guard.core.as_ref().map(|c| c.db.clone())
    }

    /// Alias for [`Self::db`].
    pub fn store(&self) -> Option<anima_store::Database> {
        self.db()
    }

    /// Read the daemon-owned local metadata for one card.
    pub fn card_metadata(
        &self,
        card_id: &str,
    ) -> Result<anima_channel::wire::CardMetadataReply, String> {
        let card_id = normalized_card_id(card_id)?;
        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        let repo = anima_store::CardMetadataRepo::new(db);
        let metadata = repo
            .get(card_id)
            .map_err(|_| "store query failed".to_string())?;
        Ok(anima_channel::wire::CardMetadataReply {
            id: card_id.to_string(),
            liked: metadata.liked,
            bookmarked: metadata.bookmarked,
        })
    }

    /// Write the daemon-owned local metadata for one card.
    ///
    /// Both flags are explicit booleans: the daemon never flips a bit on its
    /// own, so a stale client cannot cause an unintended toggle.
    pub fn card_metadata_set(
        &self,
        req: &anima_channel::wire::CardMetadataSetRequest,
    ) -> Result<anima_channel::wire::CardMetadataReply, String> {
        let card_id = normalized_card_id(&req.id)?;
        let liked = req.liked;
        let bookmarked = req.bookmarked;

        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        let repo = anima_store::CardMetadataRepo::new(db);
        repo.set(card_id, liked, bookmarked)
            .map_err(|_| "store write failed".to_string())?;
        Ok(anima_channel::wire::CardMetadataReply {
            id: card_id.to_string(),
            liked,
            bookmarked,
        })
    }

    /// Export a session and its messages as JSONL through the daemon-owned store.
    pub fn session_export_jsonl(&self, session_id: &str) -> Result<String, String> {
        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        anima_core::sessions::export_jsonl(&db, session_id).map_err(|e| e.to_string())
    }

    /// Alias for [`Self::session_export_jsonl`].
    pub fn session_export(&self, session_id: &str) -> Result<String, String> {
        self.session_export_jsonl(session_id)
    }

    /// Export a session bounded by [`anima_core::sessions::EXPORT_MAX_BYTES`],
    /// returning the JSONL payload when it fits.
    ///
    /// `Ok(Some(jsonl))` = complete snapshot, `Ok(None)` = over the bound with no
    /// payload produced.
    pub fn session_export_bounded_jsonl(&self, session_id: &str) -> Result<Option<String>, String> {
        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        match anima_core::sessions::export_bounded(&db, session_id).map_err(|e| e.to_string())? {
            anima_core::sessions::ExportOutcome::Complete(jsonl) => Ok(Some(jsonl)),
            anima_core::sessions::ExportOutcome::TooLarge { .. } => Ok(None),
        }
    }

    /// Import a JSONL session snapshot into the daemon-owned store.
    pub fn session_import_jsonl(
        &self,
        jsonl: &str,
    ) -> Result<anima_channel::wire::SessionImportReply, String> {
        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        let outcome = anima_core::sessions::import_jsonl(&db, jsonl).map_err(|e| e.to_string())?;
        Ok(anima_channel::wire::SessionImportReply {
            status: match outcome.status {
                anima_core::sessions::ImportStatus::Applied => {
                    anima_channel::wire::SessionImportStatus::Applied
                }
                anima_core::sessions::ImportStatus::Duplicate => {
                    anima_channel::wire::SessionImportStatus::Duplicate
                }
                anima_core::sessions::ImportStatus::Older => {
                    anima_channel::wire::SessionImportStatus::Older
                }
                anima_core::sessions::ImportStatus::Conflict => {
                    anima_channel::wire::SessionImportStatus::Conflict
                }
            },
            revision: outcome.revision,
        })
    }

    /// Daemon-owned card repository handle.
    ///
    /// Clones the `Database` out of the mutex and never holds `inner` across
    /// store I/O, mirroring [`Self::card_metadata`].
    fn card_repo(&self) -> Result<anima_store::CardRepo, String> {
        let db = {
            let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
            guard
                .core
                .as_ref()
                .ok_or_else(|| "store unavailable".to_string())?
                .db
                .clone()
        };
        Ok(anima_store::CardRepo::new(db))
    }

    /// List cards (id + name), newest first, capped at `limit`.
    pub fn card_list(&self, limit: usize) -> Result<Vec<anima_channel::wire::CardInfo>, String> {
        let repo = self.card_repo()?;
        let cards = repo
            .list_recent(limit)
            .map_err(|_| "store query failed".to_string())?;
        Ok(cards
            .into_iter()
            .map(|c| anima_channel::wire::CardInfo {
                id: c.id,
                name: c.name,
            })
            .collect())
    }

    /// Get one card document verbatim; `Ok(None)` when the id is unknown.
    ///
    /// The stored text is returned as-is: no decode/re-encode round trip, so
    /// unknown and extension fields survive; object key order is not guaranteed (serde_json Value).
    pub fn card_get(&self, id: &str) -> Result<Option<serde_json::Value>, String> {
        let id = normalized_card_id(id)?;
        let repo = self.card_repo()?;
        let card = repo.get(id).map_err(|_| "store query failed".to_string())?;
        card.map(|c| {
            serde_json::from_str(&c.document)
                .map_err(|_| "stored card document is not valid JSON".to_string())
        })
        .transpose()
    }

    /// Create a card from a full-fidelity document.
    ///
    /// `req.name` is the authoritative listing name; the document is stored
    /// as JSON text; unknown and extension fields are preserved (key order is not guaranteed).
    pub fn card_create(
        &self,
        req: &anima_channel::wire::CardCreateRequest,
    ) -> Result<anima_channel::wire::CardCreateReply, String> {
        let name = req.name.trim();
        if name.is_empty() {
            return Err("missing name".to_string());
        }
        let document =
            serde_json::to_string(&req.document).map_err(|_| "serialize failed".to_string())?;
        let repo = self.card_repo()?;
        let card = repo
            .insert(&anima_core::new_card_id(), &document, name)
            .map_err(|_| "store write failed".to_string())?;
        Ok(anima_channel::wire::CardCreateReply {
            id: card.id,
            name: card.name,
        })
    }

    /// Import a card from a JSON document or a base64-encoded PNG.
    ///
    /// Exactly one source is required. A name collision is resolved with the
    /// TS-compatible ` (2)`, ` (3)`, … suffix and the stored document's name is
    /// rewritten to match, so export → import round-trips.
    pub fn card_import(
        &self,
        req: &anima_channel::wire::CardImportRequest,
    ) -> Result<anima_channel::wire::CardImportReply, String> {
        use base64::Engine;
        let (document, name) = match (&req.card, &req.png_base64) {
            (Some(card), None) => {
                let name = Self::card_name_from_document(card)?;
                (card.clone(), name)
            }
            (None, Some(png)) => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(png)
                    .map_err(|_| "invalid pngBase64".to_string())?;
                let card = anima_core::cards::extract_card_from_png(&bytes)
                    .map_err(|_| "invalid pngBase64".to_string())?;
                let json = anima_core::cards::card_to_json_bytes(&card)
                    .map_err(|_| "invalid pngBase64".to_string())?;
                let value: serde_json::Value =
                    serde_json::from_slice(&json).map_err(|_| "invalid pngBase64".to_string())?;
                let name = card.name().to_string();
                (value, name)
            }
            (Some(_), Some(_)) => {
                return Err("specify either card or pngBase64, not both".to_string())
            }
            (None, None) => return Err("missing card or pngBase64".to_string()),
        };

        let repo = self.card_repo()?;
        let unique = repo
            .unique_name(&name)
            .map_err(|_| "store query failed".to_string())?;
        let renamed = unique != name;
        let document = if renamed {
            Self::rewrite_document_name(&document, &unique)?
        } else {
            document
        };
        let document =
            serde_json::to_string(&document).map_err(|_| "serialize failed".to_string())?;
        let card = repo
            .insert(&anima_core::new_card_id(), &document, &unique)
            .map_err(|_| "store write failed".to_string())?;
        Ok(anima_channel::wire::CardImportReply {
            id: card.id,
            name: card.name,
            renamed,
        })
    }

    /// Replace a card's document (and optionally its name) wholesale.
    ///
    /// A missing id is an error, not a silent success: the client asked to
    /// change a card it can see. The document is stored verbatim.
    pub fn card_update(
        &self,
        req: &anima_channel::wire::CardUpdateRequest,
    ) -> Result<anima_channel::wire::CardUpdateReply, String> {
        let id = normalized_card_id(&req.id)?;
        let repo = self.card_repo()?;
        let existing = repo
            .get(id)
            .map_err(|_| "store query failed".to_string())?
            .ok_or_else(|| "card not found".to_string())?;
        let name = match req.name.as_deref().map(str::trim) {
            Some("") | None => existing.name,
            Some(name) => name.to_string(),
        };
        let document =
            serde_json::to_string(&req.document).map_err(|_| "serialize failed".to_string())?;
        let updated = repo
            .update(id, &document, &name)
            .map_err(|_| "store write failed".to_string())?;
        Ok(anima_channel::wire::CardUpdateReply { updated })
    }

    /// Delete a card. Idempotent: `deleted: false` means it was already gone.
    pub fn card_delete(
        &self,
        req: &anima_channel::wire::CardDeleteRequest,
    ) -> Result<anima_channel::wire::CardDeleteReply, String> {
        let id = normalized_card_id(&req.id)?;
        let repo = self.card_repo()?;
        let deleted = repo
            .delete(id)
            .map_err(|_| "store write failed".to_string())?;
        Ok(anima_channel::wire::CardDeleteReply { deleted })
    }

    /// Card name of a card document, via the shared CC v2/v3 parser.
    fn card_name_from_document(document: &serde_json::Value) -> Result<String, String> {
        let bytes = serde_json::to_vec(document).map_err(|_| "serialize failed".to_string())?;
        let card = anima_core::cards::parse_card_json(&bytes)
            .map_err(|_| "invalid card document".to_string())?;
        Ok(card.name().to_string())
    }

    /// Rewrite a document's name in place, preserving every other field.
    ///
    /// Handles both the spec-wrapped form (`data.name`) and the flat legacy
    /// form (top-level `name`).
    fn rewrite_document_name(
        document: &serde_json::Value,
        name: &str,
    ) -> Result<serde_json::Value, String> {
        let mut doc = document.clone();
        let value = serde_json::Value::String(name.to_string());
        if let Some(data) = doc.get_mut("data").and_then(|v| v.as_object_mut()) {
            data.insert("name".to_string(), value);
        } else if let Some(obj) = doc.as_object_mut() {
            obj.insert("name".to_string(), value);
        } else {
            return Err("invalid card document".to_string());
        }
        Ok(doc)
    }
}

/// The process-wide Tokio runtime for background chat work (turns and cancels).
///
/// Matches the gateway's chat runtime shape.
fn chat_runtime() -> &'static tokio::runtime::Runtime {
    use std::sync::OnceLock;
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("daemon chat runtime")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    #[test]
    fn settings_registry_rejects_stale_section_names() {
        let expected_keys = [
            "general",
            "chat",
            "theme",
            "control-strip",
            "cards",
            "stage-model",
            "captions",
            "stage-window",
            "positioning",
            "spine",
            "mmd",
            "live2d",
            "audio-device",
            "user-profile",
            "local-llm",
            "consciousness",
            "chat-provider",
            "speech",
            "hearing",
            "vision",
        ];
        assert_eq!(SETTINGS_SECTIONS.len(), expected_keys.len());
        for ((key, _, _), expected) in SETTINGS_SECTIONS.iter().zip(expected_keys) {
            assert_eq!(
                *key, expected,
                "registry key must not drift or be reordered"
            );
            assert!(
                settings_section(key).is_some(),
                "registered key {key} must resolve"
            );
        }
        assert!(settings_section("chat-provider").is_some());
        for stale in ["active-provider", "active-chat", "activeProvider"] {
            assert!(
                settings_section(stale).is_none(),
                "stale key {stale} must not resolve"
            );
        }
    }

    #[test]
    fn healthy_open_is_available() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        assert!(svc.available());
        let snap = svc.snapshot();
        assert!(snap.available);
        assert!(snap.reason.is_none());
    }

    #[test]
    fn forced_open_error_is_unavailable_not_panic() {
        let dir = tempdir().unwrap();
        // Make a directory at the db path so opening fails.
        let db_path = dir.path().join("airi.sqlite");
        std::fs::create_dir_all(&db_path).unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        assert!(!svc.available());
        let snap = svc.snapshot();
        assert!(!snap.available);
        assert!(snap.reason.is_some());
    }

    #[test]
    fn startup_counts_are_cheap_and_accurate() {
        let dir = tempdir().unwrap();
        {
            let svc = CoreService::open(Some(dir.path().to_path_buf()));
            assert_eq!(svc.snapshot().session_count, 0);
            svc.chat_send("s1", "one").unwrap();
            svc.chat_send("s2", "two").unwrap();
        }
        // Reopening must count rows without materializing the messages table.
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let snap = svc.snapshot();
        assert_eq!(snap.session_count, 2);
        assert_eq!(snap.message_count, 2);
    }

    #[test]
    fn chat_send_creates_one_session_and_one_user_turn() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        svc.chat_send("atomic", "first").unwrap();
        svc.chat_send("atomic", "second").unwrap();

        let turns = svc.chat_stream("atomic").unwrap();
        assert_eq!(turns.len(), 2);
        assert_eq!(turns[0].content, "first");
        assert_eq!(turns[1].content, "second");
        assert!(turns
            .iter()
            .all(|m| m.role == "user" && m.session_id == "atomic"));

        // Reopen recomputes counts from disk: exactly one session, two turns.
        let snap = CoreService::open(Some(dir.path().to_path_buf())).snapshot();
        assert_eq!(snap.session_count, 1);
        assert_eq!(snap.message_count, 2);
    }

    #[test]
    fn chat_send_failed_message_insert_leaves_no_session() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().expect("daemon db handle");
        db.with_connection(|conn| {
            conn.execute_batch(
                "create trigger reject_message before insert on messages
                 begin select raise(abort, 'forced message failure'); end;",
            )?;
            Ok(())
        })
        .expect("install message rejection trigger");

        let err = svc
            .chat_send("rolled-back", "hello")
            .expect_err("message insert fails");
        assert_eq!(err, "message append failed");

        let sessions = anima_store::SessionRepo::new(db);
        assert!(sessions.get("rolled-back").unwrap().is_none());
        let snap = CoreService::open(Some(dir.path().to_path_buf())).snapshot();
        assert_eq!(snap.session_count, 0);
        assert_eq!(snap.message_count, 0);
    }

    #[test]
    fn cancel_without_a_turn_is_honest() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        assert!(!svc.chat_cancel("s1"));
    }

    #[test]
    fn card_metadata_whitespace_padded_id_round_trips() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));

        let written = svc
            .card_metadata_set(&anima_channel::wire::CardMetadataSetRequest {
                id: "  card-1\t".to_string(),
                liked: true,
                bookmarked: false,
            })
            .expect("padded write succeeds");
        let read = svc
            .card_metadata("  card-1\t")
            .expect("padded read succeeds");

        assert_eq!(written.id, "card-1");
        assert_eq!(read.id, "card-1");
        assert_eq!(read.liked, true);
        assert_eq!(read.bookmarked, false);
        assert!(read.liked);
        assert!(!read.bookmarked);

        // Same trimmed id reads the same row the padded write landed in.
        assert_eq!(svc.card_metadata("card-1").unwrap(), written);
        assert_eq!(svc.card_metadata("  \t ").unwrap_err(), "missing id");
    }

    #[test]
    fn card_metadata_io_releases_core_mutex() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().unwrap();

        // Hold the SQLite connection so the metadata read below blocks on I/O.
        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder = {
            let db = db.clone();
            std::thread::spawn(move || {
                db.with_connection(|_| {
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .unwrap();
            })
        };
        held_rx.recv().unwrap();

        let io_svc = svc.clone();
        let io = std::thread::spawn(move || io_svc.card_metadata("card-1"));
        // Give the reader time to reach the blocked connection lock.
        std::thread::sleep(std::time::Duration::from_millis(100));
        let core_mutex_free = svc.inner.try_lock().is_ok();

        release_tx.send(()).unwrap();
        io.join().unwrap().unwrap();
        holder.join().unwrap();

        // The daemon-wide core mutex must stay reachable while store I/O is in
        // flight; holding it across the 5s busy_timeout would stall every other
        // CoreService caller.
        assert!(core_mutex_free);
    }

    #[test]
    fn providers_list_scrubs_system_row_secrets_before_wire_projection() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        repo.upsert(&StoredProvider {
            id: "system-pool".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({
                "model": "gpt-pooled",
                "apiKey": "SYSTEM-SECRET",
                "credentials": { "region": "us-east", "accessToken": "NESTED-SECRET" },
            }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();

        let reply = svc.providers_list().unwrap();
        let text = serde_json::to_string(&reply).unwrap();
        assert!(!text.contains("SYSTEM-SECRET"));
        assert!(!text.contains("NESTED-SECRET"));
        assert_eq!(reply.providers[0].model, "gpt-pooled");
    }

    struct DiscoveryProvider;

    #[async_trait::async_trait]
    impl anima_llm::ChatProvider for DiscoveryProvider {
        fn id(&self) -> &str {
            "discoverable"
        }

        async fn models(&self) -> Result<Vec<anima_llm::ModelInfo>, anima_llm::LlmError> {
            Ok(vec![anima_llm::ModelInfo {
                id: "public-model".to_string(),
                owned_by: Some("public-owner".to_string()),
            }])
        }

        async fn stream(
            &self,
            _request: anima_llm::ChatRequest,
        ) -> Result<anima_llm::ChatStream, anima_llm::LlmError> {
            Err(anima_llm::LlmError::UnsupportedProvider(
                "test provider".to_string(),
            ))
        }
    }

    #[test]
    fn providers_models_unknown_provider_is_rejected_without_model_lookup() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let err = svc
            .providers_models(&anima_channel::wire::ProvidersModelsRequest {
                provider_id: Some("missing".to_string()),
            })
            .unwrap_err();
        assert_eq!(err, "provider not found");
    }

    #[test]
    fn providers_models_uses_registered_provider_and_projects_only_public_model_metadata() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let chat = svc.chat_service().unwrap();
        chat.register_client("discoverable", std::sync::Arc::new(DiscoveryProvider));
        let db = svc.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        repo.upsert(&StoredProvider {
            id: "discoverable".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({ "apiKey": "DISCOVERY-SECRET" }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();

        let reply = svc
            .providers_models(&anima_channel::wire::ProvidersModelsRequest {
                provider_id: Some("discoverable".to_string()),
            })
            .unwrap();
        let text = serde_json::to_string(&reply).unwrap();
        assert!(text.contains("public-model"));
        assert!(text.contains("public-owner"));
        assert!(!text.contains("DISCOVERY-SECRET"));
    }

    #[test]
    fn providers_save_padded_kind_matches_definition_and_persists() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let repo = anima_store::ProviderRepo::new(svc.db().unwrap());
        repo.upsert(&StoredProvider {
            id: "padded".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({ "model": "old-model" }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();

        svc.providers_save(&serde_json::json!({
            "id": "padded",
            "definitionId": "openai",
            "kind": "  open-ai-compatible \n",
            "model": "new-model",
        }))
        .expect("padded kind must pass the definition guard");

        let stored = repo.get("padded").unwrap().unwrap();
        assert_eq!(stored.kind, anima_store::ProviderKind::OpenAiCompatible);
        assert_eq!(stored.config["model"], "new-model");

        // Without a definitionId the same padded kind already worked; it
        // must stay valid and keep its error semantics for unknown kinds.
        let err = svc
            .providers_save(&serde_json::json!({
                "id": "padded",
                "kind": "  unknown \n",
            }))
            .expect_err("unknown kind still errors");
        assert!(err.contains("unknown provider kind"), "{err}");
    }

    #[test]
    fn providers_save_patch_preserves_extras_and_managed_credential() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        repo.upsert(&StoredProvider {
            id: "managed".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({
                "model": "old-model",
                "api_key": "MANAGED-SECRET",
                "account_id": "acct-1",
                "headers": { "x-region": "eu", "authorization": "BEARER-OLD" },
            }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();

        svc.providers_save(&serde_json::json!({
            "id": "managed",
            "kind": "open-ai-compatible",
            "model": "new-model",
            "apiKey": "CLIENT-ROTATION",
            "api_key": "CLIENT-ROTATION-SNAKE",
        }))
        .unwrap();

        let stored = repo.get("managed").unwrap().unwrap();
        assert_eq!(stored.config["model"], "new-model");
        assert_eq!(stored.config["api_key"], "MANAGED-SECRET");
        assert_eq!(stored.config["account_id"], "acct-1");
        assert_eq!(stored.config["headers"]["x-region"], "eu");
        assert_eq!(stored.config["headers"]["authorization"], "BEARER-OLD");
        assert!(!stored.config.to_string().contains("CLIENT-ROTATION"));
    }

    #[test]
    fn providers_save_explicit_rotation_replaces_managed_secret_and_keeps_extras() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        repo.upsert(&StoredProvider {
            id: "managed".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({
                "model": "old-model",
                "api_key": "MANAGED-SECRET",
                "account_id": "acct-1",
                "headers": { "x-region": "eu", "authorization": "BEARER-OLD" },
            }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();

        svc.providers_save(&serde_json::json!({
            "id": "managed",
            "kind": "open-ai-compatible",
            "model": "new-model",
            "apiKey": "ROTATED-KEY",
            "rotateSecrets": true,
        }))
        .unwrap();

        let stored = repo.get("managed").unwrap().unwrap();
        assert_eq!(stored.config["model"], "new-model");
        assert_eq!(stored.config["api_key"], "ROTATED-KEY");
        assert_eq!(stored.config["account_id"], "acct-1");
        assert_eq!(stored.config["headers"]["x-region"], "eu");
        assert_eq!(stored.config["headers"]["authorization"], "BEARER-OLD");
        assert!(!stored.config.to_string().contains("MANAGED-SECRET"));
    }

    #[test]
    fn providers_save_rejects_non_true_rotation_flag() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let repo = anima_store::ProviderRepo::new(svc.db().unwrap());
        repo.upsert(&StoredProvider {
            id: "p1".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: serde_json::json!({ "api_key": "MANAGED-KEY" }),
            enabled: true,
            updated_at: 1,
        })
        .unwrap();
        for flag in [
            serde_json::json!("true"),
            serde_json::json!(1),
            serde_json::json!(null),
        ] {
            let err = svc
                .providers_save(&serde_json::json!({
                    "id": "p1",
                    "kind": "open-ai-compatible",
                    "apiKey": "ROTATED-KEY",
                    "rotateSecrets": flag,
                }))
                .expect_err("only a boolean rotateSecrets value is valid");
            assert!(err.contains("rotateSecrets"), "{err}");
        }

        svc.providers_save(&serde_json::json!({
            "id": "p1",
            "kind": "open-ai-compatible",
            "apiKey": "NOT-ROTATED",
            "rotateSecrets": false,
        }))
        .unwrap();
        let stored = repo.get("p1").unwrap().unwrap();
        assert_eq!(
            stored.config["api_key"], "MANAGED-KEY",
            "false preserves default behavior"
        );
    }

    fn card_document() -> serde_json::Value {
        serde_json::json!({
            "spec": "chara_card_v2",
            "data": {
                "name": "Lain",
                "description": "wired",
                "extensions": { "airi": { "cognition": { "enabled": true } } },
                "x_vendor_probe": { "nested": [1, 2, 3] }
            }
        })
    }

    #[test]
    fn card_create_get_list_round_trip_full_fidelity() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let created = svc
            .card_create(&anima_channel::wire::CardCreateRequest {
                name: "Lain".to_string(),
                document: card_document(),
            })
            .unwrap();
        assert_eq!(created.name, "Lain");

        let got = svc.card_get(&created.id).unwrap().unwrap();
        assert_eq!(got, card_document());
        assert_eq!(got["data"]["x_vendor_probe"]["nested"][2], 3);

        let listed = svc.card_list(50).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id, created.id);
        assert_eq!(listed[0].name, "Lain");
    }

    #[test]
    fn card_get_unknown_id_is_none_and_blank_id_is_rejected() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        assert!(svc.card_get("nope").unwrap().is_none());
        assert_eq!(svc.card_get("   ").unwrap_err(), "missing id");
    }

    #[test]
    fn card_list_honours_limit() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        for i in 0..3 {
            svc.card_create(&anima_channel::wire::CardCreateRequest {
                name: format!("Card {i}"),
                document: serde_json::json!({ "name": format!("Card {i}") }),
            })
            .unwrap();
        }
        assert_eq!(svc.card_list(2).unwrap().len(), 2);
        assert_eq!(svc.card_list(0).unwrap().len(), 0);
    }

    #[test]
    fn card_create_rejects_blank_name() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let err = svc
            .card_create(&anima_channel::wire::CardCreateRequest {
                name: "   ".to_string(),
                document: card_document(),
            })
            .unwrap_err();
        assert_eq!(err, "missing name");
    }

    #[test]
    fn card_import_renames_on_collision_and_rewrites_document_name() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let req = anima_channel::wire::CardImportRequest {
            card: Some(card_document()),
            png_base64: None,
        };
        let first = svc.card_import(&req).unwrap();
        assert_eq!(first.name, "Lain");
        assert!(!first.renamed);

        let second = svc.card_import(&req).unwrap();
        assert!(second.renamed);
        assert_eq!(second.name, "Lain (2)");
        assert_ne!(first.id, second.id);

        // The stored document carries the unique name so export → import
        // round-trips instead of colliding again.
        let doc = svc.card_get(&second.id).unwrap().unwrap();
        assert_eq!(doc["data"]["name"], "Lain (2)");
        assert_eq!(doc["data"]["description"], "wired");
    }

    #[test]
    fn card_import_requires_exactly_one_source() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let missing = anima_channel::wire::CardImportRequest {
            card: None,
            png_base64: None,
        };
        assert_eq!(
            svc.card_import(&missing).unwrap_err(),
            "missing card or pngBase64"
        );
        let both = anima_channel::wire::CardImportRequest {
            card: Some(card_document()),
            png_base64: Some("AAAA".to_string()),
        };
        assert!(svc.card_import(&both).unwrap_err().contains("not both"));
    }

    /// A 1x1 opaque PNG, the minimum `write_card_png` accepts.
    fn minimal_png() -> Vec<u8> {
        use base64::Engine;
        base64::engine::general_purpose::STANDARD
            .decode(
                "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGP4z8DwHwAFAAH/iZk9HQAAAABJRU5ErkJggg==",
            )
            .unwrap()
    }

    #[test]
    fn card_import_from_png_extracts_embedded_card() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        // Build a real PNG with an embedded `chara` payload the same way the
        // card writer does, then import it through the base64 path.
        let card = anima_core::cards::parse_card_json(
            serde_json::to_vec(&card_document()).unwrap().as_slice(),
        )
        .unwrap();
        let png = anima_core::cards::write_card_png(&minimal_png(), &card).unwrap();
        use base64::Engine;
        let b64 = base64::engine::general_purpose::STANDARD.encode(&png);
        let imported = svc
            .card_import(&anima_channel::wire::CardImportRequest {
                card: None,
                png_base64: Some(b64),
            })
            .unwrap();
        assert_eq!(imported.name, "Lain");
        assert!(!imported.renamed);
        let doc = svc.card_get(&imported.id).unwrap().unwrap();
        assert_eq!(doc["data"]["name"], "Lain");
    }

    #[test]
    fn card_update_replaces_document_and_missing_id_is_an_error() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let created = svc
            .card_create(&anima_channel::wire::CardCreateRequest {
                name: "Old".to_string(),
                document: serde_json::json!({ "spec": "chara_card_v2", "data": { "name": "Old" } }),
            })
            .unwrap();

        let updated = svc
            .card_update(&anima_channel::wire::CardUpdateRequest {
                id: created.id.clone(),
                name: None,
                document: serde_json::json!({
                    "spec": "chara_card_v2",
                    "data": { "name": "New", "x_extra": true }
                }),
            })
            .unwrap();
        assert!(updated.updated);
        let doc = svc.card_get(&created.id).unwrap().unwrap();
        assert_eq!(doc["data"]["name"], "New");
        assert_eq!(doc["data"]["x_extra"], true);
        // No name override: the listing name is unchanged.
        assert_eq!(svc.card_list(50).unwrap()[0].name, "Old");

        let err = svc
            .card_update(&anima_channel::wire::CardUpdateRequest {
                id: "missing".to_string(),
                name: None,
                document: serde_json::json!({}),
            })
            .unwrap_err();
        assert_eq!(err, "card not found");
    }

    #[test]
    fn card_delete_is_idempotent() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let created = svc
            .card_create(&anima_channel::wire::CardCreateRequest {
                name: "Temp".to_string(),
                document: serde_json::json!({ "name": "Temp" }),
            })
            .unwrap();
        let first = svc
            .card_delete(&anima_channel::wire::CardDeleteRequest {
                id: created.id.clone(),
            })
            .unwrap();
        assert!(first.deleted);
        let second = svc
            .card_delete(&anima_channel::wire::CardDeleteRequest { id: created.id })
            .unwrap();
        assert!(!second.deleted, "already-gone is a success, not an error");
        assert!(svc.card_list(50).unwrap().is_empty());
    }

    #[test]
    fn card_io_releases_core_mutex() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let db = svc.db().unwrap();

        let (held_tx, held_rx) = std::sync::mpsc::channel();
        let (release_tx, release_rx) = std::sync::mpsc::channel::<()>();
        let holder = {
            let db = db.clone();
            std::thread::spawn(move || {
                db.with_connection(|_| {
                    held_tx.send(()).unwrap();
                    release_rx.recv().unwrap();
                    Ok(())
                })
                .unwrap();
            })
        };
        held_rx.recv().unwrap();

        let io_svc = svc.clone();
        let io = std::thread::spawn(move || io_svc.card_list(10));
        std::thread::sleep(std::time::Duration::from_millis(100));
        let core_mutex_free = svc.inner.try_lock().is_ok();

        release_tx.send(()).unwrap();
        io.join().unwrap().unwrap();
        holder.join().unwrap();

        assert!(core_mutex_free);
    }

    #[test]
    fn settings_set_merges_partial_section_without_clobbering_other_keys() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        svc.settings_set(
            "captions",
            serde_json::json!({
                "enabled": true,
                "fontSize": 140.0,
                "opacity": 55.0,
                "docking": "bottom",
            }),
        )
        .unwrap();
        // A second client edits one field of the section it loaded earlier.
        svc.settings_set("captions", serde_json::json!({ "opacity": 20.0 }))
            .unwrap();
        let reply = svc.settings_get("captions").unwrap();
        let value: serde_json::Value = serde_json::from_str(&reply.settings).unwrap();
        assert_eq!(value["enabled"], true);
        assert_eq!(value["fontSize"], 140.0);
        assert_eq!(value["opacity"], 20.0);
        assert_eq!(value["docking"], "bottom");
    }

    #[test]
    fn settings_control_strip_favorites_round_trip() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        svc.settings_set(
            "control-strip",
            serde_json::json!({
                "avatarFavoritesByChar": { "card-a": ["model-1", "model-2"] },
                "voiceFavorites": ["provider:voice-1", "provider:voice-2", "provider:voice-3"],
                "characterFavoritesGlobal": ["card-a", "card-b", "card-c"],
            }),
        )
        .unwrap();

        let reply = svc.settings_get("control-strip").unwrap();
        assert_eq!(reply.section, "control-strip");
        let value: serde_json::Value = serde_json::from_str(&reply.settings).unwrap();
        assert_eq!(
            value["avatarFavoritesByChar"],
            serde_json::json!({ "card-a": ["model-1", "model-2"] })
        );
        assert_eq!(
            value["voiceFavorites"],
            serde_json::json!(["provider:voice-1", "provider:voice-2", "provider:voice-3"])
        );
        assert_eq!(
            value["characterFavoritesGlobal"],
            serde_json::json!(["card-a", "card-b", "card-c"])
        );

        // An unrelated partial edit must not wipe the favorites.
        svc.settings_set("control-strip", serde_json::json!({ "collapsed": true }))
            .unwrap();
        let reply = svc.settings_get("control-strip").unwrap();
        let value: serde_json::Value = serde_json::from_str(&reply.settings).unwrap();
        assert_eq!(value["collapsed"], true);
        assert_eq!(
            value["voiceFavorites"],
            serde_json::json!(["provider:voice-1", "provider:voice-2", "provider:voice-3"])
        );
    }

    #[test]
    fn settings_set_keeps_unknown_wire_keys_out_of_the_stored_section() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        svc.settings_set(
            "general",
            serde_json::json!({
                "language": "ja",
                "futureField": "must-not-be-persisted",
            }),
        )
        .unwrap();
        let reply = svc.settings_get("general").unwrap();
        assert!(
            !reply.settings.contains("futureField"),
            "{}",
            reply.settings
        );
    }

    #[test]
    fn consciousness_selection_is_authoritative_for_chat_provider() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        svc.settings_set(
            "consciousness",
            serde_json::json!({
                "activeProvider": "chosen",
                "activeModel": "chosen-model",
            }),
        )
        .unwrap();
        let read = |section: &str| -> serde_json::Value {
            let reply = svc.settings_get(section).unwrap();
            serde_json::from_str(&reply.settings).unwrap()
        };
        assert_eq!(read("chat-provider")["activeProvider"], "chosen");
        assert_eq!(read("chat-provider")["activeModel"], "chosen-model");
        // Explicit chat-provider writes are mirrored to consciousness too.
        svc.settings_set(
            "chat-provider",
            serde_json::json!({
                "activeProvider": "other",
                "activeModel": "other-model",
            }),
        )
        .unwrap();
        assert_eq!(read("consciousness")["activeProvider"], "other");
        assert_eq!(read("consciousness")["activeModel"], "other-model");
        // A partial edit still preserves the authoritative model from the twin.
        svc.settings_set(
            "consciousness",
            serde_json::json!({ "activeProvider": "third" }),
        )
        .unwrap();
        assert_eq!(read("chat-provider")["activeProvider"], "third");
        assert_eq!(read("chat-provider")["activeModel"], "other-model");
    }

    /// A partially applied dual-section write would leave Providers and
    /// Modules disagreeing about the active chat provider after a crash or a
    /// rejected second write; both sections must commit or neither.
    #[test]
    fn settings_set_mirror_failure_rolls_back_primary_write() {
        let dir = tempdir().unwrap();
        let path = dir.path().to_path_buf();
        let svc = CoreService::open(Some(path.clone()));
        svc.settings_set(
            "chat-provider",
            serde_json::json!({
                "activeProvider": "before",
                "activeModel": "before-model",
            }),
        )
        .unwrap();
        // Give the twin row a future timestamp. Both typed merges succeed, but
        // the twin's upsert is rejected inside the transaction by the same
        // staleness guard `SettingsRepo::set` uses. A sequential writer would
        // have already committed "after" to the primary at that point.
        let db = anima_store::Database::open(&path.join("airi.sqlite")).unwrap();
        db.with_connection(|conn| {
            use anima_store::params;
            conn.execute(
                "update settings set updated_at = ?1 where key = ?2",
                params![i64::MAX / 2, "settings/consciousness"],
            )?;
            Ok(())
        })
        .unwrap();
        let result = svc.settings_set(
            "chat-provider",
            serde_json::json!({
                "activeProvider": "after",
                "activeModel": "after-model",
            }),
        );
        assert!(result.is_err(), "the stale twin write must fail loudly");
        let raw = |key: &str| -> String {
            db.with_connection(|conn| {
                conn.query_row(
                    "select value from settings where key = ?1",
                    anima_store::params![key],
                    |row| row.get::<_, String>(0),
                )
                .map_err(Into::into)
            })
            .unwrap()
        };
        let primary: serde_json::Value =
            serde_json::from_str(&raw("settings/chat-provider")).unwrap();
        assert_eq!(
            primary["activeProvider"], "before",
            "primary must roll back"
        );
        assert_eq!(
            primary["activeModel"], "before-model",
            "primary must roll back"
        );
    }

    #[test]
    fn providers_save_rejects_unknown_provider_definition() {
        let dir = tempdir().unwrap();
        let svc = CoreService::open(Some(dir.path().to_path_buf()));
        let err = svc
            .providers_save(&serde_json::json!({
                "id": "p1",
                "kind": "open-ai-compatible",
                "definitionId": "not-a-real-definition",
            }))
            .unwrap_err();
        assert!(err.contains("not-a-real-definition"), "{err}");
        assert!(svc.providers_list().unwrap().providers.is_empty());
        svc.providers_save(&serde_json::json!({
            "id": "p1",
            "kind": "open-ai-compatible",
            "definitionId": "openai",
        }))
        .unwrap();
        assert_eq!(svc.providers_list().unwrap().providers.len(), 1);
    }
}
