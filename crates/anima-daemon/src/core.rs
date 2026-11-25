// SPDX-License-Identifier: GPL-3.0-or-later

//! Daemon-owned `airi-core` service.
//!
//! This is the ONLY place the daemon touches core state. It opens the
//! application store using the same profile/identity rules Slint uses today
//! and fails closed on open error: no empty/temp/fallback database.
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::Mutex;

use anima_core::AppCore;
use anima_store::{Database, StoredProvider};

type SettingsLoadFn = fn(&anima_core::settings::SettingsStore) -> Result<serde_json::Value, String>;
type SettingsSaveFn =
    fn(&anima_core::settings::SettingsStore, serde_json::Value) -> Result<(), String>;

/// Resolve a settings-section name to its typed load/save operations.
///
/// Single source of truth for the supported sections: `settings_get` and
/// `settings_set` both route through here, so registering a section is one edit.
fn settings_section(section: &str) -> Option<(SettingsLoadFn, SettingsSaveFn)> {
    fn load<S: anima_core::settings::SettingsSection>(
        store: &anima_core::settings::SettingsStore,
    ) -> Result<serde_json::Value, String> {
        serde_json::to_value(
            store
                .load_section::<S>()
                .map_err(|_| "load failed".to_string())?,
        )
        .map_err(|_| "serialize failed".to_string())
    }

    fn save<S: anima_core::settings::SettingsSection>(
        store: &anima_core::settings::SettingsStore,
        value: serde_json::Value,
    ) -> Result<(), String> {
        let parsed: S =
            serde_json::from_value(value).map_err(|_| "invalid settings shape".to_string())?;
        store
            .save_section(&parsed)
            .map_err(|_| "save failed".to_string())
    }

    Some(match section {
        "general" => (
            load::<anima_core::settings::GeneralSettings>,
            save::<anima_core::settings::GeneralSettings>,
        ),
        "chat" => (
            load::<anima_core::settings::ChatSettings>,
            save::<anima_core::settings::ChatSettings>,
        ),
        "theme" => (
            load::<anima_core::settings::ThemeSettings>,
            save::<anima_core::settings::ThemeSettings>,
        ),
        "control-strip" => (
            load::<anima_core::settings::ControlStripSettings>,
            save::<anima_core::settings::ControlStripSettings>,
        ),
        "cards" => (
            load::<anima_core::settings::CardsSettings>,
            save::<anima_core::settings::CardsSettings>,
        ),
        "stage-model" => (
            load::<anima_core::settings::StageModelSettings>,
            save::<anima_core::settings::StageModelSettings>,
        ),
        "captions" => (
            load::<anima_core::settings::CaptionsSettings>,
            save::<anima_core::settings::CaptionsSettings>,
        ),
        "stage-window" => (
            load::<anima_core::settings::StageWindowSettings>,
            save::<anima_core::settings::StageWindowSettings>,
        ),
        "positioning" => (
            load::<anima_core::settings::PositioningSettings>,
            save::<anima_core::settings::PositioningSettings>,
        ),
        "spine" => (
            load::<anima_core::settings::SpineSettings>,
            save::<anima_core::settings::SpineSettings>,
        ),
        "mmd" => (
            load::<anima_core::settings::MmdSettings>,
            save::<anima_core::settings::MmdSettings>,
        ),
        "live2d" => (
            load::<anima_core::settings::Live2dSettings>,
            save::<anima_core::settings::Live2dSettings>,
        ),
        "audio-device" => (
            load::<anima_core::settings::AudioDeviceSettings>,
            save::<anima_core::settings::AudioDeviceSettings>,
        ),
        "user-profile" => (
            load::<anima_core::settings::UserProfileSettings>,
            save::<anima_core::settings::UserProfileSettings>,
        ),
        "local-llm" => (
            load::<anima_core::settings::LocalLlmSettings>,
            save::<anima_core::settings::LocalLlmSettings>,
        ),
        _ => return None,
    })
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
        let kind_text = payload
            .get("kind")
            .and_then(|v| v.as_str())
            .ok_or_else(|| "missing kind".to_string())?;
        let kind: anima_store::ProviderKind =
            serde_json::from_value(serde_json::Value::String(kind_text.to_string()))
                .map_err(|_| format!("unknown provider kind: {kind_text}"))?;
        let rotate_secrets = payload
            .get("rotateSecrets")
            .map(|v| {
                v.as_bool()
                    .ok_or_else(|| "rotateSecrets must be a boolean".to_string())
            })
            .transpose()?
            .unwrap_or(false);

        let existing = repo
            .get(id)
            .map_err(|_| "provider query failed".to_string())?;
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
        let (_, save) = settings_section(section)
            .ok_or_else(|| format!("unknown settings section: {section}"))?;
        save(&store, settings)?;
        Ok(anima_channel::wire::SettingsSetReply { ok: true })
    }

    /// Get vault statistics.
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
        core.append_message(session_id, "user", content)
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
    pub fn chat_stop(&self, session_id: &str) -> Result<bool, String> {
        let svc = self
            .chat_service()
            .ok_or_else(|| "store unavailable".to_string())?;
        let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
        rt.block_on(svc.stop(session_id.to_string()))
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
}
#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

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
}
