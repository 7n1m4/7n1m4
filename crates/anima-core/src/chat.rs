// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! Streaming chat service.
//!
//! [`ChatService`] turns user input into a persisted conversation: it appends
//! the user message to the store, streams the assistant reply through an
//! `airi-llm` provider (a registered [`anima_llm::ChatClient`] looked up by
//! provider id; the native `llama-cpp-local` id is intercepted before the
//! registry and served by `airi-local-llm`; anything else falls back to
//! `anima_llm::build_client` against the static registry), persists the
//! assistant message, and broadcasts typed
//! [`ChatEvent`]s for the UI layer to pump into the UI.
//!
//! Flow is one-way: core → broadcast → the UI pump. Events carry the session and
//! message ids so subscribers can correlate deltas to a rendered bubble.
//!
//! Current limitations (later phases):
//!
//! - No tool calling yet; [`ChatStatus::WaitingOnTool`] is reserved for the
//!   tool round trip to land with the LLM worker's `ToolSpec` API.
//! - The assistant message is persisted once the stream finishes (or is
//!   stopped); deltas are *not* written incrementally because
//!   `airi-store`'s `MessageRepo` has no update path yet.
//! - On stop, the partially accumulated text is persisted when non-empty and
//!   no `MessageDone` is emitted (no message exists to complete); a
//!   `StatusChanged { status: Idle }` always follows.

use std::collections::HashMap;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anima_llm::{
    build_client, ChatMessage, ChatProvider, ChatRequest, ProviderConfig, ProviderRegistry, Role,
};
use anima_store::{
    CardRepo, Database, MessageRepo, ProviderRepo, SessionRepo, SettingsRepo, StoredMessage,
    StoredSession, SummaryRepo,
};
use anyhow::{anyhow, Context, Result};
use futures_util::StreamExt;
use serde::{Deserialize, Serialize};
use tokio::sync::broadcast;

use crate::cards::{parse_card_json, AiriExtension};
use crate::compaction::{
    cap_winnow_survivors_to_budget, estimate_message_list_tokens, extract_compaction_message_text,
    CompactionMessage, MessageContent, WINNOW_TARGET_BUDGET_RATIO,
};
use crate::grounding::{assemble, GroundingBlock, GroundingBudget, SemanticMemoryItem};
use crate::memory::embedding::{Embedder, EmbeddingClient};
use crate::memory::retrieval::MemoryRetrieval;
use crate::memory::ShortTermMemoryService;
use crate::recent_topics::{score_recent_topics, RecentTopicsInput};
#[cfg(feature = "local-llm")]
use crate::settings::LocalLlmSettings;
use crate::settings::{CardsSettings, ChatProviderSettings, SettingsSection};
use crate::{new_id, now_ms};

/// Lifecycle status of a chat session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ChatStatus {
    /// No generation in flight.
    Idle,
    /// A completion is streaming.
    Streaming,
    /// The model requested a tool call that has not completed yet.
    WaitingOnTool,
    /// The last generation failed; see the preceding [`ChatEvent::Error`].
    Error,
}

/// Typed chat events broadcast to subscribers (e.g. the UI pump).
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "kebab-case")]
pub enum ChatEvent {
    /// A text delta of the assistant reply arrived.
    Delta {
        /// session id
        session: String,
        /// assistant message id (stable for the whole generation)
        message: String,
        /// delta text to append
        delta: String,
    },
    /// The assistant message was finalized and persisted.
    MessageDone {
        /// session id
        session: String,
        /// assistant message id
        message: String,
    },
    /// Session status changed.
    StatusChanged {
        /// session id
        session: String,
        /// new status
        status: ChatStatus,
    },
    /// Generation failed.
    Error {
        /// session id
        session: String,
        /// human-readable error message
        message: String,
    },
}

/// Outcome of one streamed generation.
#[derive(Debug, Clone)]
pub struct StreamOutcome {
    /// Session the generation ran in (created on demand when the caller
    /// passed an empty or unknown id).
    pub session_id: String,
    /// Id of the persisted assistant message; `None` when the stream was
    /// stopped before any delta arrived.
    pub assistant_message_id: Option<String>,
    /// Full assistant text accumulated from deltas.
    pub content: String,
    /// Whether the generation was cancelled via [`ChatService::stop`].
    pub stopped: bool,
}

/// How often a running stream checks its stop flag while idle.
const STOP_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// Estimated-token ceiling for a turn's prompt copy. Above it the newest
/// messages that fit [`WINNOW_TARGET_BUDGET_RATIO`] of this threshold are kept.
/// This bounds only the request sent to the provider: persisted messages and
/// sessions are never trimmed, deleted, or rewritten.
const HISTORY_PROMPT_TOKEN_THRESHOLD: usize = 12_000;

/// Top-k bound for semantic-memory evidence injected into a turn. Mirrors the
/// TS `searchEngine.evidenceLimit` default (`chat.ts:820`); the retrieval
/// formatter itself drops non-positive scores, so no extra min-score knob is
/// needed here.
const RETRIEVAL_TOP_K: usize = 6;

/// Server-side instruction for the A2UI subset Flutter GenUI can render.
///
/// Applied only through the A2UI-capable turn methods, never on ordinary
/// chat turns or one-shot calls such as auto-titling. It never touches the
/// user's prompt text or persisted message content.
const A2UI_SYSTEM_PROMPT: &str = r#"Dynamic UI format (A2UI v0.9, Flutter GenUI basic catalog): when the user asks for a dynamic widget/UI, reply with A2UI JSON only (JSON lines or one fenced ```json block), no prose. Otherwise reply with plain text as usual.
Emit a createSurface message followed by an updateComponents message, both using the same surfaceId:
{"version":"v0.9","createSurface":{"surfaceId":"weather-card","catalogId":"https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json","sendDataModel":true}}
{"version":"v0.9","updateComponents":{"surfaceId":"weather-card","components":[{"id":"root","component":"Column","children":["headerText"]},{"id":"headerText","component":"Text","text":"..."}]}}
Rules: mint a new unique, stable, slug-like surfaceId per widget (e.g. "weather-card-2026-11-25"); reuse that exact surfaceId only when updating that same widget, never for a new one; never use a fixed id like "main". The root component id must be "root"; define each component once in updateComponents and connect them by id via children (never nest component objects); use only the no-asset basic catalog: Text, Column, Row, Button, Card, CheckBox, Divider, Icon, List, Modal, ChoicePicker, Slider, Tabs, TextField. No image, audio, or video."#;

/// Streaming chat service.
///
/// Cheap to clone; clones share the database, provider table, status table,
/// and event bus.
#[derive(Clone)]
pub struct ChatService {
    /// Shared database handle, used to read stored daily-summary context.
    db: Database,
    sessions: SessionRepo,
    messages: MessageRepo,
    /// Read access to `settings/local-llm` for the native llama.cpp provider.
    settings: SettingsRepo,
    /// LLM clients by provider id; checked before the static registry.
    pub providers: Arc<Mutex<HashMap<String, Arc<dyn ChatProvider>>>>,
    registry: ProviderRegistry,
    statuses: Arc<Mutex<HashMap<String, ChatStatus>>>,
    cancels: Arc<Mutex<HashMap<String, Arc<AtomicBool>>>>,
    bus: broadcast::Sender<ChatEvent>,
    /// Test-only embedder override for semantic-memory retrieval. Production
    /// builds it from daemon-owned provider config on each opt-in turn.
    retrieval_embedder: Option<Arc<dyn Embedder>>,
}

impl ChatService {
    /// Create a service with its own provider table.
    ///
    /// Clients must be registered via [`ChatService::register_client`];
    /// provider ids not present in the table are resolved through the static
    /// `anima_llm` registry and [`anima_llm::build_client`].
    pub fn new(db: Database) -> Self {
        Self::build(db, Arc::new(Mutex::new(HashMap::new())))
    }

    /// Create a service sharing an existing provider table (used by
    /// [`crate::AppCore`]).
    pub fn with_shared_providers(
        db: Database,
        providers: Arc<Mutex<HashMap<String, Arc<dyn ChatProvider>>>>,
    ) -> Self {
        Self::build(db, providers)
    }

    fn build(db: Database, providers: Arc<Mutex<HashMap<String, Arc<dyn ChatProvider>>>>) -> Self {
        let (bus, _) = broadcast::channel(64);
        let settings = SettingsRepo::new(db.clone());
        Self {
            db: db.clone(),
            sessions: SessionRepo::new(db.clone()),
            messages: MessageRepo::new(db),
            settings,
            providers,
            registry: ProviderRegistry::new(),
            statuses: Arc::new(Mutex::new(HashMap::new())),
            cancels: Arc::new(Mutex::new(HashMap::new())),
            bus,
            retrieval_embedder: None,
        }
    }

    /// Subscribe to chat events.
    pub fn subscribe(&self) -> broadcast::Receiver<ChatEvent> {
        self.bus.subscribe()
    }

    /// Current status of a session (defaults to [`ChatStatus::Idle`]).
    pub fn status(&self, session_id: &str) -> ChatStatus {
        self.statuses
            .lock()
            .expect("status mutex poisoned")
            .get(session_id)
            .copied()
            .unwrap_or(ChatStatus::Idle)
    }

    /// Register an LLM client under a provider id, replacing any previous one.
    pub fn register_client(&self, provider_id: impl Into<String>, client: Arc<dyn ChatProvider>) {
        self.providers
            .lock()
            .expect("providers mutex poisoned")
            .insert(provider_id.into(), client);
    }

    /// Inject an embedder for semantic-memory retrieval (tests only).
    ///
    /// Production always builds one from daemon-owned provider config; this
    /// seam keeps the grounding path testable without a live embeddings API.
    #[cfg(test)]
    pub(crate) fn set_retrieval_embedder(&mut self, embedder: Arc<dyn Embedder>) {
        self.retrieval_embedder = Some(embedder);
    }

    /// Clone a registered client from the shared table.
    pub fn provider(&self, provider_id: &str) -> Option<Arc<dyn ChatProvider>> {
        self.providers
            .lock()
            .expect("providers mutex poisoned")
            .get(provider_id)
            .cloned()
    }

    /// Return a copy of the service's static registry.
    pub fn registry(&self) -> ProviderRegistry {
        self.registry.clone()
    }

    /// Create a new untitled session ("New chat") and return it.
    pub fn new_session(&self) -> Result<StoredSession> {
        self.new_session_with_title("New chat")
    }

    /// Create a new session with an explicit title and return it.
    pub fn new_session_with_title(&self, title: &str) -> Result<StoredSession> {
        let id = new_id();
        self.sessions.create(&id, title)
    }

    /// Delete a session and its messages; cancels any in-flight generation.
    /// Returns `true` when the session existed.
    pub async fn delete_session(&self, id: String) -> Result<bool> {
        let _ = self.stop(id.clone()).await;
        let removed = self.sessions.delete(&id)?;
        self.statuses
            .lock()
            .expect("status mutex poisoned")
            .remove(&id);
        Ok(removed)
    }

    /// Request cancellation of the in-flight generation for `session_id`.
    ///
    /// Returns `true` when a generation was flagged; `false` when the session
    /// had nothing streaming. Cancellation is cooperative and takes effect at
    /// the next stream poll (see [`STOP_POLL_INTERVAL`]).
    pub async fn stop(&self, session_id: String) -> Result<bool> {
        let flag = self
            .cancels
            .lock()
            .expect("cancel mutex poisoned")
            .get(&session_id)
            .cloned();
        match flag {
            Some(flag) => {
                flag.store(true, Ordering::SeqCst);
                Ok(true)
            }
            None => Ok(false),
        }
    }

    /// Append `text` as a user message and stream the assistant reply.
    ///
    /// `session_id` may be `None`, an empty string, or an unknown id — a new
    /// session is created in that case (titled from the message text). The
    /// returned outcome reports the effective session id.
    pub async fn send_message(
        &self,
        session_id: Option<&str>,
        provider_id: &str,
        config: ProviderConfig,
        model: &str,
        text: &str,
    ) -> Result<StreamOutcome> {
        self.send_message_with_assistant_id(
            session_id,
            provider_id,
            config,
            model,
            text,
            None,
            Arc::new(AtomicBool::new(false)),
        )
        .await
    }

    /// Like [`Self::send_message`] but lets the caller supply a pre-minted
    /// assistant message id (used by the daemon so the ack's `message_id`
    /// matches the deltas and persisted row). `None` mints one internally.
    pub async fn send_message_with_assistant_id(
        &self,
        session_id: Option<&str>,
        provider_id: &str,
        config: ProviderConfig,
        model: &str,
        text: &str,
        assistant_message_id: Option<&str>,
        cancel: Arc<AtomicBool>,
    ) -> Result<StreamOutcome> {
        self.send_message_inner(
            session_id,
            provider_id,
            config,
            model,
            text,
            assistant_message_id,
            cancel,
            false,
        )
        .await
    }

    /// Like [`Self::send_message_with_assistant_id`], but adds the A2UI system
    /// instruction for clients that can render GenUI surfaces.
    pub async fn send_message_with_a2ui(
        &self,
        session_id: Option<&str>,
        provider_id: &str,
        config: ProviderConfig,
        model: &str,
        text: &str,
        assistant_message_id: Option<&str>,
        cancel: Arc<AtomicBool>,
    ) -> Result<StreamOutcome> {
        self.send_message_inner(
            session_id,
            provider_id,
            config,
            model,
            text,
            assistant_message_id,
            cancel,
            true,
        )
        .await
    }

    async fn send_message_inner(
        &self,
        session_id: Option<&str>,
        provider_id: &str,
        config: ProviderConfig,
        model: &str,
        text: &str,
        assistant_message_id: Option<&str>,
        cancel: Arc<AtomicBool>,
        a2ui: bool,
    ) -> Result<StreamOutcome> {
        let session_id = self.ensure_session(session_id.unwrap_or(""), text)?;
        self.register_cancel(&session_id, &cancel);
        let user_message = StoredMessage {
            id: new_id(),
            session_id: session_id.clone(),
            role: "user".to_string(),
            content: text.to_string(),
            created_at: now_ms(),
            metadata: serde_json::json!({}),
        };
        self.messages.insert(&user_message)?;

        let history = self.messages.list(&session_id)?;
        // Bound only the prompt copy. The pure compaction helpers cannot fail,
        // so this never aborts the turn, and `history` is borrowed, never
        // mutated — every persisted row stays exactly where it was.
        let messages = cap_prompt_history(&history);
        let system = self.build_system_prompt(&session_id, text, a2ui).await?;
        self.run_stream(
            session_id,
            assistant_message_id.map(str::to_string),
            provider_id,
            config,
            ChatRequest {
                model: model.to_string(),
                messages,
                system,
                temperature: None,
                max_tokens: None,
                tools: Vec::new(),
            },
            cancel,
        )
        .await
    }

    /// Load the active card's `extensions.airi`, normalized from either the
    /// editor envelope or a spec-wrapped CC v2/v3 document. Cards are stored
    /// verbatim, so both grounding gates parse through the same seam.
    fn active_airi_extension(&self) -> Option<AiriExtension> {
        let Ok(Some(cards)) = self.settings.get::<CardsSettings>(CardsSettings::KEY) else {
            return None;
        };
        if cards.active_card_id.is_empty() {
            return None;
        }
        let Ok(Some(card)) = CardRepo::new(self.db.clone()).get(&cards.active_card_id) else {
            return None;
        };
        parse_card_json(card.document.as_bytes())
            .ok()
            .and_then(|card| card.airi_extension().cloned())
    }

    /// Recent-topic grounding is opt-in per card, mirroring the TS
    /// `extensions.airi.groundingTopicsEnabled` check in chat.ts:841.
    fn grounding_topics_enabled(&self) -> bool {
        self.active_airi_extension()
            .and_then(|airi| airi.grounding_topics_enabled)
            .unwrap_or(false)
    }

    /// Semantic-memory grounding is opt-in per card, mirroring the TS
    /// `extensions.airi.groundingMemoryEnabled` check in chat.ts:790.
    fn grounding_memory_enabled(&self) -> bool {
        let Some(airi) = self.active_airi_extension() else {
            return false;
        };
        if airi.grounding_memory_enabled.unwrap_or(false) {
            return true;
        }
        // TS also enables retrieval through these three card paths
        // (chat.ts:790-793); a card using one of them must not be ignored.
        if airi
            .universe_rag
            .as_ref()
            .and_then(|rag| rag.enabled)
            .unwrap_or(false)
        {
            return true;
        }
        if airi.first_hop_processor == Some(crate::cards::AiriFirstHopProcessor::UniverseRag) {
            return true;
        }
        airi.cognition
            .as_ref()
            .and_then(|cognition| cognition.search_engine.as_ref())
            .and_then(|engine| engine.universe_rag_enabled)
            .unwrap_or(false)
    }

    /// Embedder for retrieval: the test override when present, otherwise one
    /// built from the daemon-owned provider table and selection. Credentials,
    /// base URL and model never come from the chat request.
    fn retrieval_embedder(&self) -> Option<Arc<dyn Embedder>> {
        if let Some(embedder) = &self.retrieval_embedder {
            return Some(embedder.clone());
        }
        let rows = ProviderRepo::new(self.db.clone()).list().ok()?;
        let selection = self
            .settings
            .get::<ChatProviderSettings>(ChatProviderSettings::KEY)
            .ok()
            .flatten()
            .unwrap_or_default();
        let resolution = crate::providers::resolve_provider_selection(
            |key| std::env::var(key).ok(),
            &rows,
            &selection.active_provider,
            &selection.active_model,
        )?;
        // The chat model is not an embedding model; use the client's default
        // rather than inventing a dedicated settings section.
        let client = EmbeddingClient::from_provider_config(&resolution.config, "").ok()?;
        Some(Arc::new(client))
    }

    /// Assemble the turn's system prompt: the A2UI instruction when requested,
    /// followed by stored continuity, opt-in semantic memories, and recent
    /// topics routed through the grounding formatter. `query` is the current
    /// user turn, used for retrieval. With no grounding at all the prompt shape
    /// is unchanged (`None` for ordinary turns).
    async fn build_system_prompt(
        &self,
        session_id: &str,
        query: &str,
        a2ui: bool,
    ) -> Result<Option<String>> {
        let days = recent_utc_day_keys(now_ms() / 1000);
        // Continuity is best-effort: a locked/busy summary store must never
        // abort a turn or discard the user's message.
        let context = ShortTermMemoryService::new(self.db.clone())
            .build_context(&days)
            .unwrap_or_default();
        let mut blocks = Vec::new();
        if !context.is_empty() {
            blocks.push(GroundingBlock::short_term_memory(context));
        }

        // TS injects retrieved memories only for cards that opt in
        // (chat.ts:790). Best-effort throughout: no provider, an empty index,
        // or a locked DB just skips the block and never aborts the turn.
        // Retrieved text is untrusted; `assemble` applies the 7000-char budget.
        // shortcut: memory_embeddings has no character/universe column yet, so
        // a shared index can surface another card's text; scoping needs a store
        // schema change (tracked in airi-at80). The card gate still bounds who
        // gets retrieval at all.
        if self.grounding_memory_enabled() {
            if let Some(embedder) = self.retrieval_embedder() {
                let retrieval = MemoryRetrieval::new(self.db.clone(), embedder);
                match retrieval.build_prompt_block(query, RETRIEVAL_TOP_K).await {
                    Ok(block) if !block.is_empty() => {
                        blocks.push(GroundingBlock::SemanticMemories {
                            memories: vec![SemanticMemoryItem {
                                content: block,
                                ..SemanticMemoryItem::default()
                            }],
                        });
                    }
                    Ok(_) => {}
                    Err(err) => tracing::debug!("semantic memory grounding skipped: {err:#}"),
                }
            }
        }

        // TS injects topics only for cards that opt in (chat.ts:841). Both
        // topic sources are best-effort for the same reason as continuity.
        if self.grounding_topics_enabled() {
            let turns = self
                .messages
                .list(session_id)
                .unwrap_or_default()
                .into_iter()
                .filter(|m| m.role == "user" || m.role == "assistant")
                .map(|m| m.content)
                .collect();
            let summaries = SummaryRepo::new(self.db.clone());
            let mut summary_texts = Vec::new();
            // `days` and TS's `stmBlocks` are newest-first: index 0 gets the
            // best distance, so the newest day must be scored first.
            // Summaries have no character column; scope known rows to this
            // session and keep legacy rows with no source list.
            for day in &days {
                if let Ok(rows) = summaries.list_by_day(day) {
                    summary_texts.extend(
                        rows.into_iter()
                            .filter(|s| {
                                s.source_session_ids.is_empty()
                                    || s.source_session_ids.iter().any(|id| id == session_id)
                            })
                            .map(|s| s.content),
                    );
                }
            }
            // shortcut: no Rust echo-chip store exists yet, so chips stay empty.
            let topics = score_recent_topics(&RecentTopicsInput {
                turns,
                summaries: summary_texts,
                echo_chips: Vec::new(),
            });
            if !topics.is_empty() {
                blocks.push(GroundingBlock::RecentTopics { topics });
            }
        }

        let grounding = if blocks.is_empty() {
            String::new()
        } else {
            // STMM is a single block holding up to three daily summaries with
            // its own per-day budget; TS's generic 2500-char per-block cap
            // would discard the newest day, so let the whole total budget through.
            assemble(
                &blocks,
                GroundingBudget {
                    max_per_block_chars: 7000,
                    ..GroundingBudget::default()
                },
            )
        };
        if grounding.is_empty() {
            return Ok(a2ui.then(|| A2UI_SYSTEM_PROMPT.to_string()));
        }
        let mut system = a2ui
            .then(|| A2UI_SYSTEM_PROMPT.to_string())
            .unwrap_or_default();
        if !system.is_empty() {
            system.push_str("\n\n");
        }
        system.push_str(&grounding);
        Ok(Some(system))
    }

    /// Stream a completion over an explicit message list.
    ///
    /// Unlike [`ChatService::send_message`], this does **not** persist any
    /// user message; the caller owns the history. The session is created on
    /// demand when `session` is empty or unknown. The assistant reply is
    /// persisted and events are broadcast exactly as in `send_message`.
    pub async fn stream(
        &self,
        session: String,
        provider_id: String,
        config: ProviderConfig,
        model: String,
        messages: Vec<ChatMessage>,
        cancel: Arc<AtomicBool>,
    ) -> Result<StreamOutcome> {
        self.stream_inner(session, provider_id, config, model, messages, cancel, false)
            .await
    }

    /// Like [`Self::stream`], but adds the A2UI system instruction for clients
    /// that can render GenUI surfaces.
    pub async fn stream_with_a2ui(
        &self,
        session: String,
        provider_id: String,
        config: ProviderConfig,
        model: String,
        messages: Vec<ChatMessage>,
        cancel: Arc<AtomicBool>,
    ) -> Result<StreamOutcome> {
        self.stream_inner(session, provider_id, config, model, messages, cancel, true)
            .await
    }

    async fn stream_inner(
        &self,
        session: String,
        provider_id: String,
        config: ProviderConfig,
        model: String,
        messages: Vec<ChatMessage>,
        cancel: Arc<AtomicBool>,
        a2ui: bool,
    ) -> Result<StreamOutcome> {
        let session_id = self.ensure_session(&session, "New chat")?;
        self.register_cancel(&session_id, &cancel);
        self.run_stream(
            session_id,
            None,
            &provider_id,
            config,
            ChatRequest {
                model,
                messages,
                system: a2ui.then(|| A2UI_SYSTEM_PROMPT.to_string()),
                temperature: None,
                max_tokens: None,
                tools: Vec::new(),
            },
            cancel,
        )
        .await
    }

    /// Load the session or create it on demand.
    fn ensure_session(&self, session_id: &str, title_hint: &str) -> Result<String> {
        if !session_id.is_empty() {
            if let Some(existing) = self.sessions.get(session_id)? {
                return Ok(existing.id);
            }
        }
        let title: String = title_hint.chars().take(48).collect();
        let title = title.trim();
        let session =
            self.new_session_with_title(if title.is_empty() { "New chat" } else { title })?;
        Ok(session.id)
    }

    fn set_status(&self, session_id: &str, status: ChatStatus) {
        self.statuses
            .lock()
            .expect("status mutex poisoned")
            .insert(session_id.to_string(), status);
        let _ = self.bus.send(ChatEvent::StatusChanged {
            session: session_id.to_string(),
            status,
        });
    }

    async fn resolve_client(
        &self,
        provider_id: &str,
        config: ProviderConfig,
    ) -> Result<Arc<dyn ChatProvider>> {
        resolve_provider(
            &self.providers,
            &self.registry,
            provider_id,
            config,
            Some(&self.settings),
        )
        .await
    }

    /// Install the caller's flag as this session's active turn cancel.
    ///
    /// Call this before spawning a background turn so a cancel arriving right
    /// after the send ack already reaches the generation. The same `Arc` must
    /// be passed into `send_message_with_assistant_id` / `stream`.
    pub fn register_cancel(&self, session_id: &str, cancel: &Arc<AtomicBool>) {
        self.cancels
            .lock()
            .expect("cancel mutex poisoned")
            .insert(session_id.to_string(), cancel.clone());
    }

    async fn run_stream(
        &self,
        session_id: String,
        assistant_message_id: Option<String>,
        provider_id: &str,
        config: ProviderConfig,
        request: ChatRequest,
        cancel: Arc<AtomicBool>,
    ) -> Result<StreamOutcome> {
        let assistant_message_id = assistant_message_id.unwrap_or_else(new_id);
        self.set_status(&session_id, ChatStatus::Streaming);

        let result = self
            .run_stream_inner(
                &session_id,
                &assistant_message_id,
                provider_id,
                config,
                request,
                &cancel,
            )
            .await;

        self.cancels
            .lock()
            .expect("cancel mutex poisoned")
            .remove(&session_id);

        match result {
            Ok(outcome) => {
                self.set_status(&session_id, ChatStatus::Idle);
                Ok(outcome)
            }
            Err(err) => {
                self.set_status(&session_id, ChatStatus::Error);
                let _ = self.bus.send(ChatEvent::Error {
                    session: session_id.clone(),
                    message: format!("{err:#}"),
                });
                Err(err)
            }
        }
    }

    async fn run_stream_inner(
        &self,
        session_id: &str,
        assistant_message_id: &str,
        provider_id: &str,
        config: ProviderConfig,
        request: ChatRequest,
        cancel: &AtomicBool,
    ) -> Result<StreamOutcome> {
        // Captured before `resolve_client` consumes `config` and `stream`
        // consumes `request` — needed for the post-reply auto-title call.
        let config_for_title = config.clone();
        let model_for_title = request.model.clone();
        let client = self.resolve_client(provider_id, config).await?;
        let mut stream = client.stream(request).await?;
        let mut content = String::new();
        let mut finish_reason: Option<String> = None;
        let mut stopped = false;

        let mut ticker = tokio::time::interval(STOP_POLL_INTERVAL);
        ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);

        loop {
            tokio::select! {
                maybe = stream.next() => {
                    match maybe {
                        Some(Ok(chunk)) => {
                            if !chunk.delta.is_empty() {
                                content.push_str(&chunk.delta);
                                let _ = self.bus.send(ChatEvent::Delta {
                                    session: session_id.to_string(),
                                    message: assistant_message_id.to_string(),
                                    delta: chunk.delta,
                                });
                            }
                            if let Some(reason) = chunk.finish_reason {
                                finish_reason = Some(reason);
                            }
                            // `reasoning` deltas (providers with a separate
                            // thinking channel) are dropped for now; a
                            // Reasoning SSE event can be added later.
                        }
                        Some(Err(err)) => {
                            return Err(anyhow!(err).context("llm stream failed"));
                        }
                        None => break,
                    }
                }
                _ = ticker.tick() => {
                    if cancel.load(Ordering::SeqCst) {
                        stopped = true;
                        break;
                    }
                }
            }
        }
        drop(stream);

        let persisted_id = if content.is_empty() {
            None
        } else {
            let message = StoredMessage {
                id: assistant_message_id.to_string(),
                session_id: session_id.to_string(),
                role: "assistant".to_string(),
                content: content.clone(),
                created_at: now_ms(),
                metadata: serde_json::json!({
                    "providerId": provider_id,
                    "finishReason": finish_reason,
                }),
            };
            self.messages.insert(&message)?;
            let _ = self.bus.send(ChatEvent::MessageDone {
                session: session_id.to_string(),
                message: assistant_message_id.to_string(),
            });
            Some(assistant_message_id.to_string())
        };

        // After the assistant's first reply completes, rename a default
        // "New chat" session via a bounded LLM call. Failure keeps the
        // existing title; an unconfigured provider skips silently.
        if persisted_id.is_some() && !stopped {
            match self
                .maybe_auto_title(session_id, provider_id, config_for_title, &model_for_title)
                .await
            {
                Ok(_) => {}
                Err(err) => {
                    tracing::warn!("auto-title failed; keeping existing title: {err:#}")
                }
            }
        }

        Ok(StreamOutcome {
            session_id: session_id.to_string(),
            assistant_message_id: persisted_id,
            content,
            stopped,
        })
    }

    /// Auto-title a session whose title is still the empty/default
    /// "New chat" placeholder, using the same provider/model that produced
    /// the assistant reply.
    ///
    /// Renames only on the session's first assistant reply; a custom title,
    /// an assistant-count other than 1, an unresolvable provider, or any
    /// provider failure (including a 10s timeout) keeps the existing title.
    /// Returns `true` when the title was changed.
    async fn maybe_auto_title(
        &self,
        session_id: &str,
        provider_id: &str,
        config: ProviderConfig,
        model: &str,
    ) -> Result<bool> {
        let session = self
            .sessions
            .get(session_id)?
            .with_context(|| format!("session vanished during auto-title: {session_id}"))?;
        if !is_default_title(&session.title) {
            return Ok(false);
        }

        let history = self.messages.list(session_id)?;
        let assistant_count = history.iter().filter(|m| m.role == "assistant").count();
        if assistant_count != 1 {
            return Ok(false);
        }

        let first_user = history
            .iter()
            .find(|m| m.role == "user")
            .map(|m| m.content.trim())
            .unwrap_or("");
        let first_assistant = history
            .iter()
            .find(|m| m.role == "assistant")
            .map(|m| m.content.trim())
            .unwrap_or("");
        let excerpt = |text: &str| text.chars().take(1000).collect::<String>();
        let transcript = format!(
            "User: {}\n\nAssistant: {}",
            excerpt(first_user),
            excerpt(first_assistant)
        );

        let messages = vec![
            ChatMessage {
                role: Role::System,
                content: "You write short, specific conversation titles. Reply with a 3-5 word title for this conversation. No quotes, no trailing punctuation, no preamble.".to_string(),
                tool_call_id: None,
            },
            ChatMessage {
                role: Role::User,
                content: format!("Reply with a 3-5 word title for this conversation.\n\n{transcript}"),
                tool_call_id: None,
            },
        ];
        let request = ChatRequest {
            model: model.to_string(),
            messages,
            system: None,
            temperature: None,
            max_tokens: Some(32),
            tools: Vec::new(),
        };

        // Provider unconfigured or missing credentials: skip silently and
        // keep the existing title.
        let client = match resolve_provider(
            &self.providers,
            &self.registry,
            provider_id,
            config,
            Some(&self.settings),
        )
        .await
        {
            Ok(client) => client,
            Err(err) => {
                tracing::debug!("auto-title skipped (provider unavailable): {err:#}");
                return Ok(false);
            }
        };
        let work = collect_completion(&*client, request);
        let raw = match tokio::time::timeout(AUTO_TITLE_TIMEOUT, work).await {
            Ok(result) => result?,
            Err(_) => {
                anyhow::bail!("title completion timed out after {AUTO_TITLE_TIMEOUT:?}")
            }
        };

        let title = sanitize_title(&raw);
        if title.is_empty() {
            return Ok(false);
        }

        // Re-check before writing so a concurrent rename (e.g. user edited
        // the title while the model call was in flight) is never clobbered.
        let current = self
            .sessions
            .get(session_id)?
            .with_context(|| format!("session vanished during auto-title: {session_id}"))?;
        if !is_default_title(&current.title) {
            return Ok(false);
        }
        self.sessions.update(session_id, Some(&title), None)
    }
}

/// How long auto-titling may take past the first reply completing.
/// The provider call is bounded with `tokio::time::timeout`; on expiry the
/// existing title is kept.
const AUTO_TITLE_TIMEOUT: Duration = Duration::from_secs(10);

/// Resolve a registered client or build one from the static registry.
///
/// The native `llama-cpp-local` provider id is intercepted *before* the
/// static registry: it is not an OpenAI-compatible HTTP endpoint and has
/// nowhere to point, so `airi-local-llm::LlamaChatProvider` is constructed
/// directly from `AIRI_QT_LLAMA_MODEL` / `settings/local-llm` instead.
pub async fn resolve_provider(
    providers: &Arc<Mutex<HashMap<String, Arc<dyn ChatProvider>>>>,
    registry: &ProviderRegistry,
    provider_id: &str,
    config: ProviderConfig,
    local_llm: Option<&SettingsRepo>,
) -> Result<Arc<dyn ChatProvider>> {
    #[cfg(not(feature = "local-llm"))]
    let _ = local_llm; // kept in the signature: stable call-site API across features
    if let Some(client) = providers
        .lock()
        .expect("providers mutex poisoned")
        .get(provider_id)
        .cloned()
    {
        return Ok(client);
    }
    #[cfg(feature = "local-llm")]
    if provider_id == anima_local_llm::PROVIDER_ID {
        return llama_cpp_provider(local_llm);
    }
    let def = registry.get(provider_id).with_context(|| {
        format!("provider not registered and unknown to registry: {provider_id}")
    })?;
    let client: Arc<dyn ChatProvider> = build_client(def, config)
        .with_context(|| format!("failed to build client for {provider_id}"))?;
    Ok(client)
}

/// Build the native llama.cpp GGUF provider from the environment and the
/// `settings/local-llm` section. `AIRI_QT_LLAMA_MODEL` wins over the stored
/// `modelPath`; the remaining fields always come from settings (spec
/// defaults apply when the section was never written).
#[cfg(feature = "local-llm")]
fn llama_cpp_provider(local_llm: Option<&SettingsRepo>) -> Result<Arc<dyn ChatProvider>> {
    let stored = local_llm
        .and_then(|repo| {
            repo.get::<LocalLlmSettings>(LocalLlmSettings::KEY)
                .ok()
                .flatten()
        })
        .unwrap_or_default();
    let model_path = std::env::var("AIRI_QT_LLAMA_MODEL")
        .ok()
        .map(|path| path.trim().to_string())
        .filter(|path| !path.is_empty())
        .unwrap_or(stored.model_path);
    if model_path.trim().is_empty() {
        anyhow::bail!(
            "llama-cpp-local: no model configured; set AIRI_QT_LLAMA_MODEL or \
             settings/local-llm.modelPath"
        );
    }
    Ok(Arc::new(anima_local_llm::LlamaChatProvider::new(
        anima_local_llm::LocalLlmConfig {
            model_path,
            context_size: stored.context_size,
            temperature: stored.temperature,
            max_tokens: stored.max_tokens,
            gpu_layers: stored.gpu_layers,
            seed: anima_local_llm::DEFAULT_SEED,
        },
    )))
}

/// Drain a streaming chat provider into a single completion string.
///
/// Used for non-streaming one-shot calls (auto-titling, summarization).
/// Reasoning-channel deltas are dropped; text deltas are concatenated.
pub(crate) async fn collect_completion(
    client: &dyn ChatProvider,
    request: ChatRequest,
) -> Result<String> {
    let mut stream = client.stream(request).await.map_err(anyhow::Error::from)?;
    let mut out = String::new();
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|err| anyhow!(err).context("llm stream failed"))?;
        out.push_str(&chunk.delta);
    }
    Ok(out)
}

/// Whether a session title is empty or the default "New chat" placeholder.
fn is_default_title(title: &str) -> bool {
    let trimmed = title.trim();
    trimmed.is_empty() || trimmed.eq_ignore_ascii_case("new chat")
}

/// Sanitize a raw model-produced title: first non-empty line, no wrapping
/// quotes, single-spaced, trailing punctuation stripped, capped at 6 words
/// and 64 characters. Returns an empty string when nothing usable remains.
fn sanitize_title(raw: &str) -> String {
    let first_line = raw
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or("");
    let unquoted = first_line
        .trim_matches(|c| c == '"' || c == '\'' || c == '`')
        .trim();
    let mut stripped = unquoted.trim_end_matches(['.', '!', '?', ',', ';', ':']);
    while stripped.ends_with(char::is_whitespace) {
        stripped = stripped.trim_end();
        stripped = stripped.trim_end_matches(['.', '!', '?', ',', ';', ':']);
    }
    let collapsed = stripped.split_whitespace().collect::<Vec<_>>().join(" ");
    let capped = collapsed.split(' ').take(6).collect::<Vec<_>>().join(" ");
    if capped.chars().count() > 64 {
        return capped
            .chars()
            .take(64)
            .collect::<String>()
            .trim_end()
            .to_string();
    }
    capped
}

/// Day keys for today and the previous two days in UTC (`YYYY-MM-DD`).
fn recent_utc_day_keys(now_unix_secs: i64) -> Vec<String> {
    let today = now_unix_secs.div_euclid(86_400);
    (0..3)
        .map(|back| {
            let (year, month, day) = civil_from_days(today - back);
            format!("{year:04}-{month:02}-{day:02}")
        })
        .collect()
}

/// Howard Hinnant's civil-from-days conversion (std-only, UTC).
fn civil_from_days(z: i64) -> (i64, u32, u32) {
    let z = z + 719_468;
    let era = if z >= 0 { z } else { z - 146_096 } / 146_097;
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = (doy - (153 * mp + 2) / 5 + 1) as u32;
    let m = if mp < 10 { mp + 3 } else { mp - 9 } as u32;
    (if m <= 2 { y + 1 } else { y }, m, d)
}

/// Build the prompt copy of a persisted history.
///
/// Short histories are converted unchanged. Long ones are winnowed with the
/// pure helpers so the request stays under [`HISTORY_PROMPT_TOKEN_THRESHOLD`];
/// only the returned vector is affected, never `history` or its store rows.
///
/// The last row is the current user turn just inserted by the caller: it is
/// pinned unconditionally, even when it alone exceeds the budget, so the
/// provider always receives the question. Winnowing applies only to the older
/// prefix. Rows with unsupported roles (imported JSONL sessions can carry
/// arbitrary role strings) are dropped *before* costing, so they cannot evict
/// real history from the budget.
fn cap_prompt_history(history: &[StoredMessage]) -> Vec<ChatMessage> {
    let Some((current, older)) = history.split_last() else {
        return Vec::new();
    };
    let as_candidate = |msg: &StoredMessage| CompactionMessage {
        role: msg.role.clone(),
        content: MessageContent::Text(msg.content.clone()),
    };
    let candidates: Vec<CompactionMessage> = older
        .iter()
        .filter(|msg| chat_role(&msg.role).is_some())
        .map(as_candidate)
        .collect();
    let kept = if estimate_message_list_tokens(&candidates) > HISTORY_PROMPT_TOKEN_THRESHOLD {
        cap_winnow_survivors_to_budget(
            &candidates,
            0,
            Some(HISTORY_PROMPT_TOKEN_THRESHOLD),
            WINNOW_TARGET_BUDGET_RATIO,
        )
    } else {
        candidates
    };
    let mut messages: Vec<ChatMessage> = kept.into_iter().filter_map(to_chat_message).collect();
    // Pin the current turn outside the winnow; `send_message_inner` guarantees
    // it is the user's question, so it must always reach the provider.
    if let Some(message) = to_chat_message(as_candidate(current)) {
        messages.push(message);
    }
    messages
}

/// Recognized persisted role labels. Unknown roles (e.g. app-internal rows
/// from imported sessions) are skipped; `tool` maps to [`Role::Tool`].
fn chat_role(role: &str) -> Option<Role> {
    match role {
        "system" => Some(Role::System),
        "user" => Some(Role::User),
        "assistant" => Some(Role::Assistant),
        "tool" => Some(Role::Tool),
        _ => None,
    }
}

/// Map a compaction candidate back into an LLM chat message, skipping
/// unrecognized roles.
fn to_chat_message(message: CompactionMessage) -> Option<ChatMessage> {
    Some(ChatMessage {
        role: chat_role(&message.role)?,
        content: extract_compaction_message_text(Some(&message)),
        tool_call_id: None,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cards::{AiriCard, AiriCardExtensions};
    use crate::memory::embedding::EmbeddingError;
    use crate::memory::retrieval::MemoryIndexer;
    use anima_llm::{ChatChunk, ChatStream, ModelInfo};
    use anima_store::{StoredSummary, SummaryRepo};
    use async_trait::async_trait;
    use tempfile::tempdir;

    /// Scripted mock provider: emits the given deltas, or pends forever
    /// (for stop testing), or fails the stream on first poll.
    struct MockChatClient {
        deltas: Vec<String>,
        pace: Duration,
        fail_on_stream: bool,
        requests: Option<Arc<Mutex<Vec<ChatRequest>>>>,
    }

    impl MockChatClient {
        fn scripted(deltas: &[&str]) -> Self {
            Self {
                deltas: deltas.iter().map(|d| d.to_string()).collect(),
                pace: Duration::ZERO,
                fail_on_stream: false,
                requests: None,
            }
        }

        /// Record every request reaching the provider so tests can inspect
        /// the exact `ChatRequest` that would be sent to the LLM.
        fn recording(deltas: &[&str]) -> (Self, Arc<Mutex<Vec<ChatRequest>>>) {
            let requests = Arc::new(Mutex::new(Vec::new()));
            let client = Self {
                deltas: deltas.iter().map(|d| d.to_string()).collect(),
                pace: Duration::ZERO,
                fail_on_stream: false,
                requests: Some(requests.clone()),
            };
            (client, requests)
        }

        fn pending() -> Self {
            Self {
                deltas: Vec::new(),
                pace: Duration::MAX,
                fail_on_stream: false,
                requests: None,
            }
        }

        fn failing() -> Self {
            Self {
                deltas: Vec::new(),
                pace: Duration::ZERO,
                fail_on_stream: true,
                requests: None,
            }
        }
    }

    #[async_trait]
    impl ChatProvider for MockChatClient {
        fn id(&self) -> &str {
            "mock"
        }

        async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
            Ok(vec![ModelInfo {
                id: "mock-model".to_string(),
                owned_by: None,
            }])
        }

        async fn stream(&self, req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
            if let Some(requests) = &self.requests {
                requests.lock().unwrap().push(req.clone());
            }
            if self.fail_on_stream {
                return Err(anima_llm::LlmError::Provider(
                    "mock provider boom".to_string(),
                ));
            }
            if self.pace == Duration::MAX {
                // Never yields; the stop flag is exercised via the poll ticker.
                return Ok(Box::pin(futures_util::stream::pending()));
            }
            let mut events: Vec<Result<ChatChunk, anima_llm::LlmError>> = Vec::new();
            for delta in &self.deltas {
                events.push(Ok(ChatChunk::text(delta.clone())));
            }
            events.push(Ok(ChatChunk::finish("stop")));
            let _ = req;
            Ok(Box::pin(futures_util::stream::iter(events)))
        }
    }

    fn test_db() -> (tempfile::TempDir, Database) {
        let dir = tempdir().unwrap();
        let db = Database::open(&dir.path().join("chat.sqlite")).unwrap();
        (dir, db)
    }

    /// Opt the active card into recent-topic grounding, as the TS card flag does.
    fn enable_grounding_topics(db: &Database) {
        SettingsRepo::new(db.clone())
            .set(
                CardsSettings::KEY,
                &CardsSettings {
                    active_card_id: "card-1".to_string(),
                },
            )
            .unwrap();
        let card = AiriCard {
            extensions: Some(AiriCardExtensions {
                airi: Some(AiriExtension {
                    grounding_topics_enabled: Some(true),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        CardRepo::new(db.clone())
            .insert(
                "card-1",
                &serde_json::to_string(&card).unwrap(),
                "Test card",
            )
            .unwrap();
    }

    /// Install an active card carrying the given AIRI extension.
    fn set_active_airi(db: &Database, airi: AiriExtension) {
        SettingsRepo::new(db.clone())
            .set(
                CardsSettings::KEY,
                &CardsSettings {
                    active_card_id: "card-1".to_string(),
                },
            )
            .unwrap();
        let card = AiriCard {
            extensions: Some(AiriCardExtensions {
                airi: Some(airi),
                ..Default::default()
            }),
            ..Default::default()
        };
        CardRepo::new(db.clone())
            .insert(
                "card-1",
                &serde_json::to_string(&card).unwrap(),
                "Test card",
            )
            .unwrap();
    }

    /// Opt the active card into both semantic-memory and recent-topic grounding.
    fn enable_grounding_memory(db: &Database) {
        set_active_airi(
            db,
            AiriExtension {
                grounding_memory_enabled: Some(true),
                grounding_topics_enabled: Some(true),
                ..Default::default()
            },
        );
    }

    /// Every text maps to the same unit vector, so indexed rows score above
    /// the retrieval formatter's positive-score cutoff.
    struct ConstantEmbedder;

    #[async_trait]
    impl Embedder for ConstantEmbedder {
        async fn embed(&self, texts: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError> {
            Ok(texts.iter().map(|_| vec![1.0, 0.0]).collect())
        }
    }

    struct BrokenEmbedder;

    #[async_trait]
    impl Embedder for BrokenEmbedder {
        async fn embed(&self, _texts: &[String]) -> Result<Vec<Vec<f32>>, EmbeddingError> {
            Err(EmbeddingError::Empty)
        }
    }

    async fn seed_semantic_memory(db: &Database) {
        let embedder: Arc<dyn Embedder> = Arc::new(ConstantEmbedder);
        MemoryIndexer::new(db.clone(), embedder)
            .index_journal_entry("j1", "The user's cat is named Miso")
            .await
            .unwrap();
    }

    fn drain_events(rx: &mut broadcast::Receiver<ChatEvent>) -> Vec<ChatEvent> {
        let mut events = Vec::new();
        loop {
            match rx.try_recv() {
                Ok(ev) => events.push(ev),
                Err(broadcast::error::TryRecvError::Empty) => break,
                Err(broadcast::error::TryRecvError::Lagged(_)) => continue,
                Err(broadcast::error::TryRecvError::Closed) => break,
            }
        }
        events
    }

    #[tokio::test]
    async fn send_message_streams_persists_and_broadcasts() {
        let (_dir, db) = test_db();
        let verify_db = db.clone();
        let service = ChatService::new(db);
        let mut rx = service.subscribe();
        service.register_client(
            "mock",
            Arc::new(MockChatClient::scripted(&["Hello", ", ", "world"])),
        );

        let outcome = service
            .send_message(
                None,
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "hi there",
            )
            .await
            .unwrap();

        assert_eq!(outcome.content, "Hello, world");
        assert!(!outcome.stopped);
        assert!(outcome.assistant_message_id.is_some());

        // User + assistant messages persisted in order.
        let messages = anima_store::MessageRepo::new(verify_db)
            .list(&outcome.session_id)
            .unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0].role, "user");
        assert_eq!(messages[0].content, "hi there");
        assert_eq!(messages[1].role, "assistant");
        assert_eq!(messages[1].content, "Hello, world");
        assert_eq!(
            Some(messages[1].id.as_str()),
            outcome.assistant_message_id.as_deref()
        );

        // Broadcast sequence: Streaming → Delta*3 → MessageDone → Idle.
        let events = drain_events(&mut rx);
        let deltas: Vec<&str> = events
            .iter()
            .filter_map(|ev| match ev {
                ChatEvent::Delta { delta, .. } => Some(delta.as_str()),
                _ => None,
            })
            .collect();
        assert_eq!(deltas, vec!["Hello", ", ", "world"]);

        let status_flow: Vec<ChatStatus> = events
            .iter()
            .filter_map(|ev| match ev {
                ChatEvent::StatusChanged { status, .. } => Some(*status),
                _ => None,
            })
            .collect();
        assert_eq!(status_flow, vec![ChatStatus::Streaming, ChatStatus::Idle]);

        let done = events.iter().find_map(|ev| match ev {
            ChatEvent::MessageDone { session, message } => Some((session.clone(), message.clone())),
            _ => None,
        });
        assert_eq!(
            done,
            Some((
                outcome.session_id.clone(),
                outcome.assistant_message_id.unwrap()
            ))
        );

        assert_eq!(service.status(&outcome.session_id), ChatStatus::Idle);
    }

    #[tokio::test]
    async fn stream_uses_explicit_messages_and_persists_assistant() {
        let (_dir, db) = test_db();
        let verify_db = db.clone();
        let service = ChatService::new(db);
        service.register_client("mock", Arc::new(MockChatClient::scripted(&["pong"])));

        let outcome = service
            .stream(
                String::new(),
                "mock".to_string(),
                ProviderConfig::default(),
                "mock-model".to_string(),
                vec![ChatMessage {
                    role: Role::User,
                    content: "ping".to_string(),
                    tool_call_id: None,
                }],
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();

        // Session was auto-created; only the assistant reply is persisted.
        let messages = anima_store::MessageRepo::new(verify_db)
            .list(&outcome.session_id)
            .unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].role, "assistant");
        assert_eq!(messages[0].content, "pong");
    }

    #[tokio::test]
    async fn a2ui_turns_inject_unique_surface_prompt_without_changing_user_messages() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        let (client, requests) = MockChatClient::recording(&["plain reply"]);
        service.register_client("mock", Arc::new(client));

        // `stream_with_a2ui` owns its history, so it creates a separate
        // session; the two `send_message*` turns share this one.
        let session = service.new_session_with_title("Custom title").unwrap();
        // An ordinary turn must not receive the widget instruction.
        let plain = service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "ordinary question",
            )
            .await
            .unwrap();
        assert_eq!(plain.content, "plain reply");

        let outcome = service
            .send_message_with_a2ui(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "hi there",
                None,
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();
        assert_eq!(outcome.content, "plain reply");

        let explicit = vec![ChatMessage {
            role: Role::User,
            content: "another question".to_string(),
            tool_call_id: None,
        }];
        let streamed = service
            .stream_with_a2ui(
                String::new(),
                "mock".to_string(),
                ProviderConfig::default(),
                "mock-model".to_string(),
                explicit.clone(),
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();
        assert_ne!(streamed.session_id, session.id);

        let recorded = requests.lock().unwrap();
        // The assistant's first reply may trigger a separate bounded
        // auto-title call; select only the two chat turns by prompt text.
        let turn_for = |text: &str| {
            recorded
                .iter()
                .find(|req| req.messages.iter().any(|m| m.content == text))
                .unwrap_or_else(|| panic!("no provider request for {text:?}"))
        };
        let plain_request = turn_for("ordinary question");
        assert!(
            !plain_request
                .system
                .as_deref()
                .unwrap_or_default()
                .contains("v0.9"),
            "ordinary turns must not get the A2UI instruction"
        );

        let sent_request = turn_for("hi there");
        let streamed_request = turn_for("another question");
        for request in [sent_request, streamed_request] {
            let system = request
                .system
                .as_deref()
                .expect("A2UI-capable turn needs a system prompt");
            assert!(system.contains("v0.9"));
            assert!(
                system.contains("https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json")
            );
            assert!(system.contains(r#""id":"root""#));
            assert!(system.contains("createSurface"));
            assert!(system.contains("updateComponents"));
            assert!(system.contains("unique, stable, slug-like surfaceId"));
            assert!(!system.contains(r#""surfaceId":"main""#));
            assert!(
                request.messages.iter().all(|m| m.role != Role::System),
                "system instruction must stay in ChatRequest.system"
            );
        }
        assert_eq!(plain_request.messages.len(), 1);
        assert_eq!(plain_request.messages[0].role, Role::User);
        assert_eq!(sent_request.messages.len(), 3);
        assert_eq!(sent_request.messages[0].content, "ordinary question");
        assert_eq!(sent_request.messages[1].content, "plain reply");
        assert_eq!(sent_request.messages[2].content, "hi there");
        assert!(sent_request
            .messages
            .iter()
            .all(|m| m.role == Role::User || m.role == Role::Assistant));
        assert_eq!(streamed_request.messages.len(), 1);
        assert_eq!(streamed_request.messages[0].role, Role::User);

        let repo = MessageRepo::new(db);
        let sent = repo.list(&session.id).unwrap();
        assert_eq!(sent.len(), 4);
        assert_eq!(sent[0].role, "user");
        assert_eq!(sent[0].content, "ordinary question");
        assert_eq!(sent[1].role, "assistant");
        assert_eq!(sent[2].content, "hi there");
        assert_eq!(sent[3].role, "assistant");
        assert_eq!(sent[3].content, "plain reply");
        let streamed_messages = repo.list(&streamed.session_id).unwrap();
        assert_eq!(streamed_messages.len(), 1);
        assert_eq!(streamed_messages[0].content, "plain reply");
        assert!(
            sent.iter()
                .chain(streamed_messages.iter())
                .all(|m| !m.content.contains("a2ui.org")),
            "system prompt must never leak into persisted/user-visible messages"
        );
    }

    #[tokio::test]
    async fn send_message_injects_stored_daily_summaries_into_system() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));

        let summaries = SummaryRepo::new(db);
        for day in recent_utc_day_keys(now_ms() / 1000) {
            summaries
                .insert(&StoredSummary {
                    id: new_id(),
                    day,
                    content: "Daily note: rebuild the deck on Saturday".to_string(),
                    source_session_ids: vec![],
                    token_estimate: 9,
                    created_at: now_ms(),
                })
                .unwrap();
        }

        // A custom title avoids an auto-title request in the recording.
        let session = service.new_session_with_title("Custom title").unwrap();
        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "plain continuity check",
            )
            .await
            .unwrap();
        service
            .send_message_with_a2ui(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "widget continuity check",
                None,
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();

        let recorded = requests.lock().unwrap();
        let system_for = |text: &str| {
            recorded
                .iter()
                .find(|req| req.messages.iter().any(|m| m.content == text))
                .and_then(|req| req.system.clone())
                .unwrap_or_else(|| panic!("no provider request for {text:?}"))
        };
        let plain = system_for("plain continuity check");
        assert!(plain.contains("[PAST CONTINUITY / DAILY SUMMARIES]"));
        assert!(plain.contains("Daily note: rebuild the deck on Saturday"));
        assert!(!plain.contains("v0.9"));

        let a2ui = system_for("widget continuity check");
        assert!(a2ui.contains("[PAST CONTINUITY / DAILY SUMMARIES]"));
        assert!(a2ui.contains("Daily note: rebuild the deck on Saturday"));
        // The A2UI instruction survives the merge.
        assert!(a2ui.contains("v0.9"));
        assert!(a2ui.contains("createSurface"));
        assert!(a2ui.contains("https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"));
    }

    #[tokio::test]
    async fn build_system_prompt_routes_continuity_through_grounding_assembler() {
        let (_dir, db) = test_db();
        enable_grounding_topics(&db);
        let service = ChatService::new(db.clone());
        let session = service.new_session_with_title("Custom title").unwrap();
        MessageRepo::new(db.clone())
            .insert(&StoredMessage {
                id: new_id(),
                session_id: session.id.clone(),
                role: "user".to_string(),
                content: "garden roses bloom".to_string(),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();
        let summaries = SummaryRepo::new(db);
        summaries
            .insert(&StoredSummary {
                id: new_id(),
                day: recent_utc_day_keys(now_ms() / 1000)[0].clone(),
                content: "Daily note: assemble via grounding".to_string(),
                source_session_ids: vec![],
                token_estimate: 6,
                created_at: now_ms(),
            })
            .unwrap();

        let plain = service
            .build_system_prompt(&session.id, "garden roses bloom", false)
            .await
            .unwrap()
            .expect("continuity and topics must produce a system prompt");
        assert!(plain.starts_with("[PAST CONTINUITY / DAILY SUMMARIES]"));
        assert!(plain.contains("Daily note: assemble via grounding"));
        assert!(plain.contains("[RECENT TOPICS]\n"));
        // One turn at distance 0 gives bigrams their full 1.5 weight.
        assert!(plain.contains("garden roses (weight: 1.50)"));
        assert!(!plain.contains("v0.9"));

        let a2ui = service
            .build_system_prompt(&session.id, "garden roses bloom", true)
            .await
            .unwrap()
            .expect("A2UI turn must keep both blocks");
        assert!(a2ui.starts_with(A2UI_SYSTEM_PROMPT));
        assert!(a2ui.contains("\n\n[PAST CONTINUITY / DAILY SUMMARIES]"));
        assert!(a2ui.contains("garden roses (weight: 1.50)"));
    }

    #[tokio::test]
    async fn build_system_prompt_with_empty_session_keeps_shape_unchanged() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db);
        assert_eq!(
            service
                .build_system_prompt("", "anything", false)
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            service
                .build_system_prompt("", "anything", true)
                .await
                .unwrap()
                .as_deref(),
            Some(A2UI_SYSTEM_PROMPT)
        );
    }

    #[tokio::test]
    async fn build_system_prompt_respects_card_topics_opt_in() {
        let (_dir, db) = test_db();
        let session = ChatService::new(db.clone())
            .new_session_with_title("Topics gate")
            .unwrap();
        MessageRepo::new(db.clone())
            .insert(&StoredMessage {
                id: new_id(),
                session_id: session.id.clone(),
                role: "user".to_string(),
                content: "garden roses bloom".to_string(),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();
        let service = ChatService::new(db.clone());
        let without_flag = service
            .build_system_prompt(&session.id, "anything", false)
            .await
            .unwrap()
            .unwrap_or_default();
        assert!(
            !without_flag.contains("[RECENT TOPICS]"),
            "topics must stay off until the card opts in"
        );

        enable_grounding_topics(&db);
        let with_flag = service
            .build_system_prompt(&session.id, "anything", false)
            .await
            .unwrap()
            .expect("opted-in card must emit topics");
        assert!(with_flag.contains("[RECENT TOPICS]"));
    }

    #[tokio::test]
    async fn continuity_read_is_best_effort_when_summary_store_fails() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        let summaries = SummaryRepo::new(db.clone());
        summaries
            .insert(&StoredSummary {
                id: new_id(),
                day: recent_utc_day_keys(now_ms() / 1000)[0].clone(),
                content: "stored before the failure".to_string(),
                source_session_ids: vec![],
                token_estimate: 4,
                created_at: now_ms(),
            })
            .unwrap();
        // Simulate the locked/busy summary DB that previously aborted 13 chat
        // tests after the user turn had already been persisted.
        db.with_connection(|conn| Ok(conn.execute_batch("DROP TABLE summaries")?))
            .unwrap();

        assert_eq!(
            service
                .build_system_prompt("", "anything", false)
                .await
                .unwrap(),
            None,
            "a failed continuity read must degrade to no extra system prompt"
        );

        let (client, _requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));
        let session = service.new_session_with_title("Custom title").unwrap();
        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "turn survives a broken summary store",
            )
            .await
            .expect("the user turn must still be accepted");
    }

    #[tokio::test]
    async fn build_system_prompt_honors_wrapped_card_topics_opt_in() {
        let (_dir, db) = test_db();
        let session = ChatService::new(db.clone())
            .new_session_with_title("Wrapped card")
            .unwrap();
        MessageRepo::new(db.clone())
            .insert(&StoredMessage {
                id: new_id(),
                session_id: session.id.clone(),
                role: "user".to_string(),
                content: "garden roses bloom".to_string(),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();
        SettingsRepo::new(db.clone())
            .set(
                CardsSettings::KEY,
                &CardsSettings {
                    active_card_id: "wrapped".to_string(),
                },
            )
            .unwrap();
        let card = serde_json::json!({
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Wrapped",
                "extensions": { "airi": { "groundingTopicsEnabled": true } },
            },
        });
        CardRepo::new(db.clone())
            .insert("wrapped", &card.to_string(), "Wrapped")
            .unwrap();

        let service = ChatService::new(db);
        let system = service
            .build_system_prompt(&session.id, "anything", false)
            .await
            .unwrap()
            .expect("a spec-wrapped card must still opt in");
        assert!(system.contains("[RECENT TOPICS]"));
    }

    #[tokio::test]
    async fn all_universe_rag_card_paths_enable_retrieval() {
        use crate::cards::{AiriCognition, AiriCognitionSearchEngine, AiriUniverseRag};

        let cases: [(&str, AiriExtension); 3] = [
            (
                "universeRag.enabled",
                AiriExtension {
                    universe_rag: Some(AiriUniverseRag {
                        enabled: Some(true),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
            (
                "firstHopProcessor",
                AiriExtension {
                    first_hop_processor: Some(crate::cards::AiriFirstHopProcessor::UniverseRag),
                    ..Default::default()
                },
            ),
            (
                "cognition.searchEngine.universeRagEnabled",
                AiriExtension {
                    cognition: Some(AiriCognition {
                        search_engine: Some(AiriCognitionSearchEngine {
                            universe_rag_enabled: Some(true),
                            ..Default::default()
                        }),
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            ),
        ];
        for (name, extension) in cases {
            let (_dir, db) = test_db();
            set_active_airi(&db, extension);
            seed_semantic_memory(&db).await;
            let mut service = ChatService::new(db);
            service.set_retrieval_embedder(Arc::new(ConstantEmbedder));
            let system = service
                .build_system_prompt("", "cat", false)
                .await
                .unwrap()
                .unwrap_or_default();
            assert!(
                system.contains("[GROUNDED LONG-TERM MEMORIES]"),
                "{name} must enable retrieval: {system}"
            );
        }
    }

    #[tokio::test]
    async fn semantic_grounding_with_no_hits_leaves_prompt_shape_unchanged() {
        let (_dir, db) = test_db();
        enable_grounding_memory(&db);
        let mut service = ChatService::new(db);
        service.set_retrieval_embedder(Arc::new(ConstantEmbedder));

        assert_eq!(
            service
                .build_system_prompt("", "what is my cat's name", false)
                .await
                .unwrap(),
            None
        );
        assert_eq!(
            service
                .build_system_prompt("", "what is my cat's name", true)
                .await
                .unwrap()
                .as_deref(),
            Some(A2UI_SYSTEM_PROMPT)
        );
    }

    #[tokio::test]
    async fn opted_in_card_injects_semantic_block_before_recent_topics() {
        let (_dir, db) = test_db();
        enable_grounding_memory(&db);
        seed_semantic_memory(&db).await;
        let embedder: Arc<dyn Embedder> = Arc::new(ConstantEmbedder);
        let mut service = ChatService::new(db.clone());
        service.set_retrieval_embedder(embedder);
        let session = service.new_session_with_title("Custom title").unwrap();
        MessageRepo::new(db.clone())
            .insert(&StoredMessage {
                id: new_id(),
                session_id: session.id.clone(),
                role: "user".to_string(),
                content: "garden roses bloom".to_string(),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();

        let plain = service
            .build_system_prompt(&session.id, "tell me about the cat", false)
            .await
            .unwrap()
            .expect("semantic memory must produce a system prompt");
        assert!(plain.contains("[GROUNDED LONG-TERM MEMORIES]"), "{plain}");
        assert!(plain.contains("The user's cat is named Miso"), "{plain}");
        assert!(plain.contains("[RECENT TOPICS]"), "{plain}");
        let semantic = plain.find("[GROUNDED LONG-TERM MEMORIES]").unwrap();
        let topics = plain.find("[RECENT TOPICS]").unwrap();
        assert!(
            semantic < topics,
            "semantic memories must precede recent topics"
        );
    }

    #[tokio::test]
    async fn card_gate_off_emits_no_semantic_block() {
        let (_dir, db) = test_db();
        // Topics opt in; memory does not.
        enable_grounding_topics(&db);
        seed_semantic_memory(&db).await;
        let embedder: Arc<dyn Embedder> = Arc::new(ConstantEmbedder);
        let mut service = ChatService::new(db.clone());
        service.set_retrieval_embedder(embedder);
        let session = service.new_session_with_title("Custom title").unwrap();
        MessageRepo::new(db.clone())
            .insert(&StoredMessage {
                id: new_id(),
                session_id: session.id.clone(),
                role: "user".to_string(),
                content: "garden roses bloom".to_string(),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();

        let plain = service
            .build_system_prompt(&session.id, "tell me about the cat", false)
            .await
            .unwrap()
            .expect("topics still produce a system prompt");
        assert!(plain.contains("[RECENT TOPICS]"));
        assert!(!plain.contains("[GROUNDED LONG-TERM MEMORIES]"), "{plain}");
        assert!(!plain.contains("The user's cat is named Miso"), "{plain}");
    }

    #[tokio::test]
    async fn embedding_failure_does_not_abort_the_turn() {
        let (_dir, db) = test_db();
        enable_grounding_memory(&db);
        seed_semantic_memory(&db).await;
        let mut service = ChatService::new(db);
        service.set_retrieval_embedder(Arc::new(BrokenEmbedder));
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));
        let session = service.new_session_with_title("Custom title").unwrap();

        let outcome = service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "totally unrelated qqq",
            )
            .await
            .expect("embedding failure must not abort the turn");
        assert_eq!(outcome.content, "reply");

        let recorded = requests.lock().unwrap();
        let request = recorded
            .iter()
            .find(|req| {
                req.messages
                    .iter()
                    .any(|m| m.content == "totally unrelated qqq")
            })
            .expect("no provider request for the user turn");
        assert!(
            !request
                .system
                .as_deref()
                .unwrap_or_default()
                .contains("[GROUNDED LONG-TERM MEMORIES]"),
            "a failed embedder with no lexical overlap must not inject memories"
        );
    }

    #[tokio::test]
    async fn send_message_without_summaries_adds_only_recent_topics() {
        let (_dir, db) = test_db();
        enable_grounding_topics(&db);
        let service = ChatService::new(db);
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));

        let session = service.new_session_with_title("Custom title").unwrap();
        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "plain no memory",
            )
            .await
            .unwrap();
        service
            .send_message_with_a2ui(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "widget no memory",
                None,
                Arc::new(AtomicBool::new(false)),
            )
            .await
            .unwrap();

        let recorded = requests.lock().unwrap();
        let request_for = |text: &str| {
            recorded
                .iter()
                .find(|req| req.messages.iter().any(|m| m.content == text))
                .unwrap_or_else(|| panic!("no provider request for {text:?}"))
        };
        let plain = request_for("plain no memory")
            .system
            .as_deref()
            .expect("recent topics ground even a turn with no summaries");
        assert!(plain.contains("[RECENT TOPICS]"));
        assert!(plain.contains("plain memory (weight: 1.50)"));
        assert!(!plain.contains("[PAST CONTINUITY / DAILY SUMMARIES]"));
        assert!(!plain.contains("v0.9"));

        let a2ui = request_for("widget no memory")
            .system
            .as_deref()
            .expect("A2UI turn still needs its system prompt");
        assert!(a2ui.starts_with(A2UI_SYSTEM_PROMPT));
        assert!(a2ui.contains("\n\n[RECENT TOPICS]"));
        assert!(!a2ui.contains("[PAST CONTINUITY / DAILY SUMMARIES]"));
    }

    #[test]
    fn recent_utc_day_keys_cover_today_and_previous_two_days() {
        // 2026-11-26T00:00:00Z
        let midnight = 1_795_651_200;
        assert_eq!(
            recent_utc_day_keys(midnight),
            vec!["2026-11-26", "2026-11-25", "2026-11-24"]
        );
        // Late in the same UTC day must not roll over.
        assert_eq!(recent_utc_day_keys(midnight + 86_399)[0], "2026-11-26");
    }

    #[tokio::test]
    async fn stop_cancels_a_pending_stream() {
        let (_dir, db) = test_db();
        let verify_db = db.clone();
        let service = ChatService::new(db);
        let mut rx = service.subscribe();
        service.register_client("mock", Arc::new(MockChatClient::pending()));

        let svc = service.clone();
        let handle = tokio::spawn(async move {
            svc.send_message(None, "mock", ProviderConfig::default(), "mock-model", "hi")
                .await
        });

        // Wait until the generation registered its stop flag.
        let mut session_id = None;
        for _ in 0..100 {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let guard = service.cancels.lock().unwrap();
            if let Some(id) = guard.keys().next() {
                session_id = Some(id.clone());
                break;
            }
        }
        let session_id = session_id.expect("stream never registered a stop flag");
        assert!(service.stop(session_id.clone()).await.unwrap());

        let outcome = handle.await.unwrap().unwrap();
        assert!(outcome.stopped);
        assert_eq!(outcome.session_id, session_id);
        assert_eq!(outcome.content, "");
        assert!(outcome.assistant_message_id.is_none());
        assert_eq!(service.status(&session_id), ChatStatus::Idle);

        // Stopping again reports nothing in flight.
        assert!(!service.stop(session_id).await.unwrap());

        // Only the user message was persisted.
        let messages = anima_store::MessageRepo::new(verify_db)
            .list(&outcome.session_id)
            .unwrap();
        assert_eq!(messages.len(), 1);
        assert_eq!(messages[0].role, "user");

        let events = drain_events(&mut rx);
        assert!(events.iter().any(|ev| matches!(
            ev,
            ChatEvent::StatusChanged {
                status: ChatStatus::Idle,
                ..
            }
        )));
    }

    #[tokio::test]
    async fn preregistered_cancel_stops_a_stream_before_it_registers() {
        // The daemon arms this flag in its chat.send handler, before the
        // background turn starts. A cancel immediately after the ack can
        // arrive before the stream polls its flag; the generation must still
        // stop and must not persist an assistant message.
        let (_dir, db) = test_db();
        let verify_db = db.clone();
        let service = ChatService::new(db);
        service.register_client("mock", Arc::new(MockChatClient::pending()));
        let cancel = Arc::new(AtomicBool::new(false));
        let session = service.new_session().unwrap();
        cancel.store(true, Ordering::SeqCst);
        service.register_cancel(&session.id, &cancel);

        assert!(service.stop(session.id.clone()).await.unwrap());
        let outcome = service
            .send_message_with_assistant_id(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "stop me",
                None,
                cancel,
            )
            .await
            .unwrap();

        assert!(outcome.stopped);
        assert_eq!(outcome.content, "");
        assert!(outcome.assistant_message_id.is_none());
        assert_eq!(service.status(&session.id), ChatStatus::Idle);
        let messages = MessageRepo::new(verify_db).list(&session.id).unwrap();
        assert_eq!(
            messages.len(),
            1,
            "cancelled turn must not persist an assistant message"
        );
        assert_eq!(messages[0].role, "user");
    }

    #[tokio::test]
    async fn provider_error_sets_error_status_and_broadcasts() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db);
        let mut rx = service.subscribe();
        service.register_client("mock", Arc::new(MockChatClient::failing()));

        let err = service
            .send_message(None, "mock", ProviderConfig::default(), "mock-model", "hi")
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("mock provider boom"));

        let events = drain_events(&mut rx);
        assert!(events
            .iter()
            .any(|ev| matches!(ev, ChatEvent::Error { .. })));
        assert_eq!(service.status(&drain_session(&events)), ChatStatus::Error);
    }

    fn drain_session(events: &[ChatEvent]) -> String {
        events
            .iter()
            .find_map(|ev| match ev {
                ChatEvent::StatusChanged { session, .. } => Some(session.clone()),
                _ => None,
            })
            .unwrap_or_default()
    }

    #[tokio::test]
    async fn unknown_provider_without_registration_errors() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db);
        let err = service
            .send_message(
                None,
                "no-such-provider",
                ProviderConfig::default(),
                "m",
                "hi",
            )
            .await
            .unwrap_err();
        assert!(format!("{err:#}").contains("no-such-provider"));
    }

    #[tokio::test]
    async fn delete_session_removes_messages() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        service.register_client("mock", Arc::new(MockChatClient::scripted(&["done"])));

        let outcome = service
            .send_message(None, "mock", ProviderConfig::default(), "mock-model", "hi")
            .await
            .unwrap();

        assert!(service
            .delete_session(outcome.session_id.clone())
            .await
            .unwrap());
        let messages = anima_store::MessageRepo::new(db)
            .list(&outcome.session_id)
            .unwrap();
        assert!(messages.is_empty());
        assert_eq!(service.status(&outcome.session_id), ChatStatus::Idle);
    }

    #[test]
    fn is_default_title_recognizes_placeholder() {
        assert!(is_default_title("New chat"));
        assert!(is_default_title("  "));
        assert!(is_default_title("NEW CHAT"));
        assert!(is_default_title(""));
        assert!(!is_default_title("My chat"));
        assert!(!is_default_title("new chatbot"));
    }

    #[test]
    fn sanitize_title_strips_quotes_punctuation_and_caps() {
        assert_eq!(sanitize_title("\"My Weekend Plans.\""), "My Weekend Plans");
        assert_eq!(sanitize_title("hello world"), "hello world");
        assert_eq!(sanitize_title(""), "");
        assert_eq!(sanitize_title("   \n  "), "");
        assert_eq!(
            sanitize_title("one two three four five six seven eight nine"),
            "one two three four five six"
        );
        let long = format!("{} {} {}", "a".repeat(30), "b".repeat(30), "c".repeat(30));
        assert!(sanitize_title(&long).chars().count() <= 64);
    }

    #[tokio::test]
    async fn auto_title_renames_default_title_after_first_reply() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        service.register_client(
            "mock",
            Arc::new(MockChatClient::scripted(&["Mock Title Here"])),
        );

        let session = service.new_session().unwrap();
        assert_eq!(session.title, "New chat");
        let outcome = service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "hello",
            )
            .await
            .unwrap();
        assert!(outcome.assistant_message_id.is_some());

        let stored = anima_store::SessionRepo::new(db)
            .get(&session.id)
            .unwrap()
            .unwrap();
        assert_eq!(stored.title, "Mock Title Here");
    }

    #[tokio::test]
    async fn auto_title_keeps_custom_title() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        service.register_client(
            "mock",
            Arc::new(MockChatClient::scripted(&["Mock Title Here"])),
        );

        let session = service.new_session_with_title("My custom title").unwrap();
        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "hello",
            )
            .await
            .unwrap();

        let stored = anima_store::SessionRepo::new(db)
            .get(&session.id)
            .unwrap()
            .unwrap();
        assert_eq!(stored.title, "My custom title");
    }

    #[tokio::test]
    async fn maybe_auto_title_skips_unconfigured_provider_and_multi_reply_sessions() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());

        // No provider registered and none in the static registry: silent skip.
        let session = service.new_session().unwrap();
        let renamed = service
            .maybe_auto_title(
                &session.id,
                "no-such-provider",
                ProviderConfig::default(),
                "m",
            )
            .await
            .unwrap();
        assert!(!renamed);
        assert_eq!(
            anima_store::SessionRepo::new(db.clone())
                .get(&session.id)
                .unwrap()
                .unwrap()
                .title,
            "New chat"
        );

        // Two assistant messages already: not the first reply, no rename.
        service.register_client("mock", Arc::new(MockChatClient::scripted(&["Some Title"])));
        let session2 = service.new_session().unwrap();
        for role in ["user", "assistant", "user", "assistant"] {
            anima_store::MessageRepo::new(db.clone())
                .insert(&anima_store::StoredMessage {
                    id: new_id(),
                    session_id: session2.id.clone(),
                    role: role.to_string(),
                    content: format!("{role} content"),
                    created_at: now_ms(),
                    metadata: serde_json::json!({}),
                })
                .unwrap();
        }
        let renamed = service
            .maybe_auto_title(
                &session2.id,
                "mock",
                ProviderConfig::default(),
                "mock-model",
            )
            .await
            .unwrap();
        assert!(!renamed);
        assert_eq!(
            anima_store::SessionRepo::new(db)
                .get(&session2.id)
                .unwrap()
                .unwrap()
                .title,
            "New chat"
        );
    }

    #[tokio::test]
    #[cfg(feature = "local-llm")]
    async fn llama_cpp_local_resolves_from_settings() {
        let (_dir, db) = test_db();
        let settings = SettingsRepo::new(db);
        settings
            .set(
                LocalLlmSettings::KEY,
                &LocalLlmSettings {
                    model_path: "/models/test-model.gguf".to_string(),
                    context_size: 1024,
                    temperature: 0.4,
                    max_tokens: 64,
                    gpu_layers: -1,
                },
            )
            .unwrap();
        let providers = Arc::new(Mutex::new(HashMap::new()));
        let registry = ProviderRegistry::new();
        let client = resolve_provider(
            &providers,
            &registry,
            "llama-cpp-local",
            ProviderConfig::default(),
            Some(&settings),
        )
        .await
        .expect("llama-cpp-local resolves from settings");
        assert_eq!(client.id(), "llama-cpp-local");
    }

    #[tokio::test]
    #[cfg(feature = "local-llm")]
    async fn llama_cpp_local_without_model_configured_is_an_error() {
        let (_dir, db) = test_db();
        let settings = SettingsRepo::new(db);
        // Deterministic regardless of the developer's shell.
        std::env::remove_var("AIRI_QT_LLAMA_MODEL");
        let providers = Arc::new(Mutex::new(HashMap::new()));
        let registry = ProviderRegistry::new();
        let err = resolve_provider(
            &providers,
            &registry,
            "llama-cpp-local",
            ProviderConfig::default(),
            Some(&settings),
        )
        .await
        .err()
        .expect("must fail without a configured model");
        let message = format!("{err:#}");
        assert!(
            message.contains("AIRI_QT_LLAMA_MODEL") && message.contains("settings/local-llm"),
            "unexpected error: {message}"
        );
    }

    #[tokio::test]
    async fn long_history_is_capped_in_the_prompt_but_persisted_rows_survive() {
        let (_dir, db) = test_db();
        let verify_db = db.clone();
        let service = ChatService::new(db.clone());
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));

        let session = service.new_session_with_title("Custom title").unwrap();
        let repo = MessageRepo::new(db);
        // 20 × ~753 estimated tokens ≈ 15 050, above the 12 000 threshold.
        // The 75% target (9 000 tokens) fits only the newest 12 messages.
        for i in 0..20 {
            repo.insert(&StoredMessage {
                id: format!("seed-{i}"),
                session_id: session.id.clone(),
                role: if i % 2 == 0 { "user" } else { "assistant" }.to_string(),
                content: format!("seed {i}: {}", "x".repeat(3000)),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();
        }
        assert_eq!(repo.list(&session.id).unwrap().len(), 20);

        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "final question",
            )
            .await
            .unwrap();

        let recorded = requests.lock().unwrap();
        let request = recorded
            .iter()
            .find(|req| req.messages.iter().any(|m| m.content == "final question"))
            .expect("no provider request for the final user turn");
        // Uncapped, the request would carry all 20 seeded rows plus this turn.
        // The exact cut point depends on the estimator heuristic; assert the
        // real invariant: a contiguous newest suffix, with the current turn
        // pinned after it.
        assert!(
            request.messages.len() > 1 && request.messages.len() <= 20,
            "prompt was not capped to a suffix plus the current turn"
        );
        assert_eq!(
            request.messages.last().unwrap().content,
            "final question",
            "the current turn must be pinned last"
        );
        let prefix = &request.messages[..request.messages.len() - 1];
        let first_index: usize = prefix[0]
            .content
            .strip_prefix("seed ")
            .and_then(|rest| rest.split(':').next())
            .and_then(|n| n.parse().ok())
            .expect("capped prefix must start with a seeded message");
        assert!(
            first_index > 0,
            "reverse selection should drop the oldest messages first"
        );
        let expected_prefix: Vec<String> = (first_index..20)
            .map(|i| format!("seed {i}: {}", "x".repeat(3000)))
            .collect();
        assert_eq!(
            prefix
                .iter()
                .map(|m| m.content.as_str())
                .collect::<Vec<_>>(),
            expected_prefix
                .iter()
                .map(String::as_str)
                .collect::<Vec<_>>(),
            "kept history must be a contiguous newest-first suffix"
        );
        assert!(
            request
                .messages
                .iter()
                .all(|m| !m.content.starts_with("seed 0:")),
            "the oldest seeded message must not reach the provider"
        );
        drop(recorded);

        // The cap touched only the prompt copy: every persisted row remains,
        // including the oldest ones that fell out of the request.
        let persisted = MessageRepo::new(verify_db).list(&session.id).unwrap();
        assert_eq!(
            persisted.len(),
            22,
            "20 seeded + user turn + assistant reply"
        );
        assert_eq!(persisted[0].id, "seed-0");
        assert_eq!(
            persisted[0].content,
            format!("seed 0: {}", "x".repeat(3000))
        );
        assert_eq!(persisted[19].id, "seed-19");
        assert_eq!(persisted[20].content, "final question");
        assert_eq!(persisted[21].content, "reply");
    }

    #[tokio::test]
    async fn oversized_current_turn_is_pinned_even_when_it_exceeds_the_budget() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));

        let session = service.new_session_with_title("Custom title").unwrap();
        // One ordinary seeded row: if the current turn were winnowed out,
        // this would be the provider's last message (the regression).
        let repo = MessageRepo::new(db);
        repo.insert(&StoredMessage {
            id: "seed-old".to_string(),
            session_id: session.id.clone(),
            role: "user".to_string(),
            content: "seed question".to_string(),
            created_at: now_ms(),
            metadata: serde_json::json!({}),
        })
        .unwrap();

        // 50 000 ASCII chars -> ~12 500 tokens, above the 12 000 threshold
        // and far above the 9 000 winnow target.
        let current_turn = format!("final question: {}", "z".repeat(50_000));
        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                &current_turn,
            )
            .await
            .unwrap();

        let recorded = requests.lock().unwrap();
        let request = recorded
            .iter()
            .find(|req| req.messages.iter().any(|m| m.content == "seed question"))
            .expect("no provider request for the seeded session");
        assert_eq!(
            request.messages.last().unwrap().content,
            current_turn,
            "the current user turn must never be winnowed out"
        );
        assert_eq!(request.messages.first().unwrap().content, "seed question");
    }

    #[tokio::test]
    async fn unknown_roles_do_not_consume_the_prompt_budget() {
        let (_dir, db) = test_db();
        let service = ChatService::new(db.clone());
        let (client, requests) = MockChatClient::recording(&["reply"]);
        service.register_client("mock", Arc::new(client));

        let session = service.new_session_with_title("Custom title").unwrap();
        let repo = MessageRepo::new(db);
        repo.insert(&StoredMessage {
            id: "old-real".to_string(),
            session_id: session.id.clone(),
            role: "user".to_string(),
            content: "keep me: older question".to_string(),
            created_at: now_ms(),
            metadata: serde_json::json!({}),
        })
        .unwrap();
        // 30 imported rows at ~750 tokens each (~22 500 total) with an
        // unsupported role. Before filtering they fill the 9 000-token
        // target and evict the real message, then get dropped by the mapper.
        for i in 0..30 {
            repo.insert(&StoredMessage {
                id: format!("unknown-{i}"),
                session_id: session.id.clone(),
                role: "imported-role".to_string(),
                content: format!("junk {i}: {}", "y".repeat(3000)),
                created_at: now_ms(),
                metadata: serde_json::json!({}),
            })
            .unwrap();
        }

        service
            .send_message(
                Some(&session.id),
                "mock",
                ProviderConfig::default(),
                "mock-model",
                "final question",
            )
            .await
            .unwrap();

        let recorded = requests.lock().unwrap();
        let request = recorded
            .iter()
            .find(|req| req.messages.iter().any(|m| m.content == "final question"))
            .expect("no provider request for the final user turn");
        assert!(
            request
                .messages
                .iter()
                .any(|m| m.content == "keep me: older question"),
            "older real history must survive the cap"
        );
        assert!(
            request
                .messages
                .iter()
                .all(|m| !m.content.starts_with("junk ")),
            "unknown-role rows must not reach the provider"
        );
        assert_eq!(request.messages.last().unwrap().content, "final question");
    }
}
