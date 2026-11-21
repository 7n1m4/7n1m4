// SPDX-License-Identifier: GPL-3.0-or-later

//! Daemon-owned `airi-core` service.
//!
//! This is the ONLY place the daemon touches core state. It opens the
//! application store using the same profile/identity rules Slint uses today
//! and fails closed on open error: no empty/temp/fallback database.
use std::path::PathBuf;
use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::sync::Mutex;

use anima_core::AppCore;
use anima_store::Database;

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
    cancels: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
}

struct CoreInner {
    core: Option<AppCore>,
    available: bool,
    reason: Option<String>,
    session_count: u64,
    message_count: u64,
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
                let sessions = anima_store::SessionRepo::new(db.clone()).list().map(|v| v.len() as u64).unwrap_or(0);
                let messages = anima_store::MessageRepo::new(db.clone()).list_all().map(|v| v.len() as u64).unwrap_or(0);
                let core = AppCore::new(db);
                Self {
                    inner: Arc::new(Mutex::new(CoreInner {
                        core: Some(core),
                        available: true,
                        reason: None,
                        session_count: sessions,
                        message_count: messages,
                    })),
                    cancels: Arc::new(Mutex::new(HashMap::new())),
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
            cancels: Arc::new(Mutex::new(HashMap::new())),
        }
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
            store_health: if snap.available { "ok".to_string() } else { "unavailable".to_string() },
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
        let infos = providers
            .into_iter()
            .map(|p| {
                let config = &p.config;
                anima_channel::wire::ProviderInfo {
                    id: p.id,
                    kind: serde_json::to_string(&p.kind)
                        .unwrap_or_else(|_| "\"unknown\"".to_string())
                        .trim_matches('"')
                        .to_string(),
                    model: config
                        .as_object()
                        .and_then(|o| o.get("model"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    base_url: config
                        .as_object()
                        .and_then(|o| o.get("baseUrl"))
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string(),
                    enabled: p.enabled,
                    updated_at: p.updated_at as i32,
                }
            })
            .collect();
        Ok(anima_channel::wire::ProvidersListReply { providers: infos })
    }

    /// Get a typed settings section.
    pub fn settings_get(&self, section: &str) -> Result<anima_channel::wire::SettingsGetReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let store = core.settings();
        let value = match section {
            "general" => serde_json::to_value(store.load_section::<anima_core::settings::GeneralSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "chat" => serde_json::to_value(store.load_section::<anima_core::settings::ChatSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "theme" => serde_json::to_value(store.load_section::<anima_core::settings::ThemeSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "control-strip" => serde_json::to_value(store.load_section::<anima_core::settings::ControlStripSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "cards" => serde_json::to_value(store.load_section::<anima_core::settings::CardsSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "stage-model" => serde_json::to_value(store.load_section::<anima_core::settings::StageModelSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "captions" => serde_json::to_value(store.load_section::<anima_core::settings::CaptionsSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "stage-window" => serde_json::to_value(store.load_section::<anima_core::settings::StageWindowSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "positioning" => serde_json::to_value(store.load_section::<anima_core::settings::PositioningSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "spine" => serde_json::to_value(store.load_section::<anima_core::settings::SpineSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "mmd" => serde_json::to_value(store.load_section::<anima_core::settings::MmdSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "live2d" => serde_json::to_value(store.load_section::<anima_core::settings::Live2dSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "audio-device" => serde_json::to_value(store.load_section::<anima_core::settings::AudioDeviceSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "user-profile" => serde_json::to_value(store.load_section::<anima_core::settings::UserProfileSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            "local-llm" => serde_json::to_value(store.load_section::<anima_core::settings::LocalLlmSettings>().map_err(|_| "load failed".to_string())?).map_err(|_| "serialize failed".to_string())?,
            _ => return Err(format!("unknown settings section: {section}")),
        };
        let value_str = serde_json::to_string(&value).map_err(|_| "serialize failed".to_string())?;
        Ok(anima_channel::wire::SettingsGetReply {
            section: section.to_string(),
            settings: value_str,
        })
    }

    /// Set a typed settings section.
    pub fn settings_set(&self, section: &str, settings: serde_json::Value) -> Result<anima_channel::wire::SettingsSetReply, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = &guard.core;
        let Some(core) = core else {
            return Err("store unavailable".to_string());
        };
        let store = core.settings();
        match section {
            "general" => {
                let s: anima_core::settings::GeneralSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "chat" => {
                let s: anima_core::settings::ChatSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "theme" => {
                let s: anima_core::settings::ThemeSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "control-strip" => {
                let s: anima_core::settings::ControlStripSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "cards" => {
                let s: anima_core::settings::CardsSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "stage-model" => {
                let s: anima_core::settings::StageModelSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "captions" => {
                let s: anima_core::settings::CaptionsSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "stage-window" => {
                let s: anima_core::settings::StageWindowSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "positioning" => {
                let s: anima_core::settings::PositioningSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "spine" => {
                let s: anima_core::settings::SpineSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "mmd" => {
                let s: anima_core::settings::MmdSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "live2d" => {
                let s: anima_core::settings::Live2dSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "audio-device" => {
                let s: anima_core::settings::AudioDeviceSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "user-profile" => {
                let s: anima_core::settings::UserProfileSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            "local-llm" => {
                let s: anima_core::settings::LocalLlmSettings = serde_json::from_value(settings).map_err(|_| "invalid settings shape".to_string())?;
                store.save_section(&s).map_err(|_| "save failed".to_string())?;
            }
            _ => return Err(format!("unknown settings section: {section}")),
        }
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
        let core = guard.core.as_ref().ok_or_else(|| "store unavailable".to_string())?;
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

    /// Replay the persisted messages of a session from the daemon-owned store.
    pub fn chat_stream(
        &self,
        session_id: &str,
    ) -> Result<Vec<anima_store::StoredMessage>, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard.core.as_ref().ok_or_else(|| "store unavailable".to_string())?;
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
        let core = guard.core.as_ref().ok_or_else(|| "store unavailable".to_string())?;
        core.provider_repo()
            .list()
            .map_err(|_| "provider list failed".to_string())
    }

    /// Request cancellation of an in-flight generation.
    pub fn chat_stop(&self, session_id: &str) -> Result<bool, String> {
        let svc = self.chat_service().ok_or_else(|| "store unavailable".to_string())?;
        let rt = tokio::runtime::Runtime::new().map_err(|e| e.to_string())?;
        rt.block_on(svc.stop(session_id.to_string()))
            .map_err(|e| e.to_string())
    }

    /// Borrow (or create) the cancel flag for `session_id` so a streaming
    /// pump can honour cancellation cooperatively.
    pub fn chat_cancel_flag(&self, session_id: &str) -> Arc<AtomicBool> {
        let mut map = self.cancels.lock().expect("cancel mutex poisoned");
        map.entry(session_id.to_string())
            .or_insert_with(|| Arc::new(AtomicBool::new(false)))
            .clone()
    }

    /// Cancel an in-flight generation for `session_id`.
    ///
    /// Sets the shared cancel flag and forwards to the daemon-owned
    /// `ChatService`. Returns `true` when a generation was in flight.
    pub fn chat_cancel(&self, session_id: &str) -> bool {
        let had_flag = {
            let map = self.cancels.lock().expect("cancel mutex poisoned");
            map.contains_key(session_id)
        };
        let flag = self.chat_cancel_flag(session_id);
        flag.store(true, Ordering::SeqCst);
        let svc_cancelled = self.chat_stop(session_id).unwrap_or(false);
        svc_cancelled || had_flag
    }
    /// Daemon-owned short-term memory (STMM) service, sharing the store and
    /// provider table. Single writer.
    pub fn stmm_service(&self) -> Option<anima_core::memory::ShortTermMemoryService> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(anima_core::memory::ShortTermMemoryService::with_shared_providers(
            core.db.clone(),
            core.providers.clone(),
            Default::default(),
        ))
    }

    /// Alias for [`Self::stmm_service`].
    pub fn short_term_memory_service(&self) -> Option<anima_core::memory::ShortTermMemoryService> {
        self.stmm_service()
    }

    /// Daemon-owned text journal service. Single writer.
    pub fn journal_service(&self) -> Option<anima_core::memory::TextJournalService> {
        let guard = self.inner.lock().ok()?;
        let core = guard.core.as_ref()?;
        Some(anima_core::memory::TextJournalService::new(core.db.clone()))
    }

    /// Alias for [`Self::journal_service`].
    pub fn text_journal_service(&self) -> Option<anima_core::memory::TextJournalService> {
        self.journal_service()
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

    /// Alias for [`Self::retrieval_service`].
    pub fn memory_retrieval(
        &self,
        embedder: std::sync::Arc<dyn anima_core::memory::embedding::Embedder>,
    ) -> Option<anima_core::memory::retrieval::MemoryRetrieval> {
        self.retrieval_service(embedder)
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

    /// Alias for [`Self::memory_indexer`].
    pub fn indexer(
        &self,
        embedder: std::sync::Arc<dyn anima_core::memory::embedding::Embedder>,
    ) -> Option<anima_core::memory::retrieval::MemoryIndexer> {
        self.memory_indexer(embedder)
    }


    /// Daemon-owned database handle (single writer).
    pub fn db(&self) -> Option<anima_store::Database> {
        let guard = self.inner.lock().ok()?;
        guard.core.as_ref().map(|c| c.db.clone())
    }

    /// Alias for [`Self::db`].
    pub fn database(&self) -> Option<anima_store::Database> {
        self.db()
    }

    /// Alias for [`Self::db`].
    pub fn store(&self) -> Option<anima_store::Database> {
        self.db()
    }

    /// Export a session and its messages as JSONL through the daemon-owned store.
    pub fn session_export_jsonl(&self, session_id: &str) -> Result<String, String> {
        let guard = self.inner.lock().map_err(|_| "lock poisoned".to_string())?;
        let core = guard.core.as_ref().ok_or_else(|| "store unavailable".to_string())?;
        anima_core::sessions::export_jsonl(&core.db, session_id)
            .map_err(|e| e.to_string())
    }

    /// Alias for [`Self::session_export_jsonl`].
    pub fn export_session_jsonl(&self, session_id: &str) -> Result<String, String> {
        self.session_export_jsonl(session_id)
    }

    /// Alias for [`Self::session_export_jsonl`].
    pub fn session_export(&self, session_id: &str) -> Result<String, String> {
        self.session_export_jsonl(session_id)
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
}
