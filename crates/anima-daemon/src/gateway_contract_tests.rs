// SPDX-License-Identifier: GPL-3.0-or-later

//! Wire-level contract tests against the gateway's real handler map.
//!
//! These call `Gateway::renderer_handlers` directly, so the tests fail if a
//! verb is renamed, removed, or its wire payload changes shape.

#[cfg(test)]
mod tests {
    use std::cell::Cell;
    use std::fs;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::{mpsc, Arc, Mutex};
    use std::time::Duration;

    use anima_channel::dispatch::{RendererHandlers, RpcContext, RpcError, RpcRegistry};
    use anima_channel::wire::{
        CardCreateRequest, CardGetReply, CardImportReply, CardInfo, CardListReply,
        CardMetadataReply, CatalogDescriptor, ChatSendReply, ChatSendRequest, ProviderInfo,
        ProvidersListReply, SessionDeleteReply, SessionDeleteRequest, SessionMediaScrubReply,
        VaultArchiveApplyReply, VaultArchiveInspectReply, VaultArchiveReply,
    };
    use tempfile::tempdir;

    use crate::core::CoreService;
    use crate::gateway::Gateway;

    struct Fixture {
        gateway: Gateway,
        core: CoreService,
        config_path: std::path::PathBuf,
        _tmp: tempfile::TempDir,
        // Drop order is declaration order: release the liveness token before
        // `ENV_LOCK` so a waiting test cannot observe a stale live fixture.
        _live_guard: LiveFixtureGuard,
        _env_guard: EnvGuard,
    }

    /// `ENV_LOCK` is non-reentrant: a second fixture on a thread already
    /// owning one would self-deadlock. `LIVE_FIXTURES` records the serialized
    /// fixture's liveness; the thread flag makes the same-thread case fail
    /// before we ever try to acquire `ENV_LOCK`. Other test threads may still
    /// wait on `ENV_LOCK` for their own fixture.
    static LIVE_FIXTURES: AtomicUsize = AtomicUsize::new(0);
    thread_local! {
        static THREAD_HAS_FIXTURE: Cell<bool> = const { Cell::new(false) };
    }

    struct LiveFixtureGuard;

    impl Drop for LiveFixtureGuard {
        fn drop(&mut self) {
            LIVE_FIXTURES.fetch_sub(1, Ordering::AcqRel);
            THREAD_HAS_FIXTURE.with(|flag| flag.set(false));
        }
    }

    /// `AIRI_SERVER_CHANNEL_CONFIG` is process-global; serialize fixtures that
    /// set it so parallel tests cannot steal each other's config path.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    type EnvGuard = std::sync::MutexGuard<'static, ()>;

    const SECOND_FIXTURE_PANIC: &str =
        "isolated_gateway() called twice on one test thread; reuse the existing fixture";

    /// Restore process-global provider env vars even when a test panics.
    /// Other gateway tests read the same variables through provider resolution.
    struct ProviderEnvGuard {
        provider: Option<std::ffi::OsString>,
        model: Option<std::ffi::OsString>,
    }

    impl ProviderEnvGuard {
        fn override_with(provider: &str, model: &str) -> Self {
            let guard = Self {
                provider: std::env::var_os("AIRI_SLINT_PROVIDER"),
                model: std::env::var_os("AIRI_SLINT_MODEL"),
            };
            std::env::set_var("AIRI_SLINT_PROVIDER", provider);
            std::env::set_var("AIRI_SLINT_MODEL", model);
            guard
        }
    }

    impl Drop for ProviderEnvGuard {
        fn drop(&mut self) {
            for (key, value) in [
                ("AIRI_SLINT_PROVIDER", self.provider.take()),
                ("AIRI_SLINT_MODEL", self.model.take()),
            ] {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
        }
    }

    fn isolated_gateway() -> Fixture {
        if THREAD_HAS_FIXTURE.with(Cell::get) {
            panic!("{SECOND_FIXTURE_PANIC}");
        }
        let guard: EnvGuard = match ENV_LOCK.lock() {
            Ok(guard) => guard,
            Err(poisoned) => {
                // Preserve the historical poison recovery: the mutex state is
                // irrelevant to fixture setup, so resume with the inner guard.
                poisoned.into_inner()
            }
        };
        let tmp = tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        fs::create_dir_all(&dir).unwrap();
        let config_path = dir.join("config.json");
        let mut config = anima_channel::ChannelConfig::healed();
        config.allow_actions = None;
        fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        std::env::set_var("AIRI_SERVER_CHANNEL_CONFIG", &config_path);
        // `start_with_core` binds an ephemeral gateway using the config path
        // above via AIRI_SERVER_CHANNEL_CONFIG; no real network port is used.
        let core = CoreService::open(Some(tmp.path().to_path_buf()));
        let gateway = Gateway::start_with_core(Some(0), None, core.clone());
        assert_eq!(
            LIVE_FIXTURES.fetch_add(1, Ordering::AcqRel),
            0,
            "ENV_LOCK must serialize live fixtures"
        );
        THREAD_HAS_FIXTURE.with(|flag| flag.set(true));
        Fixture {
            gateway,
            core,
            config_path,
            _tmp: tmp,
            _live_guard: LiveFixtureGuard,
            _env_guard: guard,
        }
    }

    fn enable_actions(fixture: &Fixture) {
        let mut value: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&fixture.config_path).unwrap()).unwrap();
        value["allowActions"] = serde_json::json!(true);
        fs::write(
            &fixture.config_path,
            serde_json::to_string_pretty(&value).unwrap(),
        )
        .unwrap();
    }

    fn verbs(fixture: &Fixture) -> RendererHandlers {
        Gateway::renderer_handlers(
            &fixture.core,
            &fixture.gateway.publisher(),
            &fixture.config_path,
            "127.0.0.1",
        )
    }

    fn dispatch(
        fixture: &Fixture,
        method: &str,
        payload: &serde_json::Value,
    ) -> Result<serde_json::Value, RpcError> {
        let handlers: Arc<_> = Arc::new(verbs(fixture));
        RpcRegistry::dispatch(
            &RpcContext::new("127.0.0.1", 6121),
            method,
            payload,
            &handlers,
        )
    }

    fn call(fixture: &Fixture, method: &str, payload: serde_json::Value) -> serde_json::Value {
        dispatch(fixture, method, &payload).unwrap_or_else(|e| panic!("{method} failed: {e}"))
    }

    fn card_document(name: &str) -> serde_json::Value {
        serde_json::json!({
            "spec": "chara_card_v2",
            "data": {
                "name": name,
                "description": "full fidelity description",
                "personality": "curious",
                "extensions": { "airi": { "model": "vrm", "outfits": ["casual", "formal"] } },
                "unknown_extension": { "nested": [1, 2, 3] }
            }
        })
    }

    fn send(fixture: &Fixture, session_id: &str, content: &str) -> ChatSendReply {
        let request = ChatSendRequest {
            session_id: session_id.to_string(),
            content: content.to_string(),
            gen_ui: false,
        };
        let ack = call(
            fixture,
            "chat.send",
            serde_json::to_value(&request).unwrap(),
        );
        serde_json::from_value(ack.clone())
            .unwrap_or_else(|e| panic!("typed ChatSendReply must decode {ack}: {e}"))
    }

    /// `chat.send` acknowledges before the background generation writes the
    /// user turn, so count-sensitive assertions wait for the writer.
    fn wait_for_history(fixture: &Fixture, session_id: &str, expected: usize) {
        for _ in 0..100 {
            let history = call(
                fixture,
                "chat.history",
                serde_json::json!({ "session_id": session_id, "limit": 10 }),
            );
            if history["messages"].as_array().unwrap().len() == expected {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        panic!("chat.history for {session_id} never reached {expected} messages");
    }

    #[test]
    fn cards_list_round_trips_full_fidelity_card() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let created = call(
            &fixture,
            "cards.create",
            serde_json::to_value(CardCreateRequest {
                name: "Aria".to_string(),
                document: card_document("Aria"),
            })
            .unwrap(),
        );
        let id = created["id"].as_str().unwrap().to_string();

        let listed = call(&fixture, "cards.list", serde_json::json!({ "limit": 10 }));
        let list: CardListReply = serde_json::from_value(listed.clone())
            .unwrap_or_else(|e| panic!("typed CardListReply must decode {listed}: {e}"));
        assert!(!list.truncated);
        assert!(
            list.cards.iter().any(|c| c
                == &CardInfo {
                    id: id.clone(),
                    name: "Aria".to_string()
                }),
            "cards.list must expose the created card: {listed}"
        );

        let got = call(&fixture, "cards.get", serde_json::json!({ "id": &id }));
        let card = got["card"]
            .as_object()
            .expect("full-fidelity card document");
        assert_eq!(card["data"]["name"], "Aria");
        assert_eq!(card["data"]["description"], "full fidelity description");
        assert_eq!(card["data"]["personality"], "curious");
        assert_eq!(card["data"]["extensions"]["airi"]["model"], "vrm");
        assert_eq!(card["data"]["extensions"]["airi"]["outfits"][1], "formal");
        assert_eq!(card["data"]["unknown_extension"]["nested"][2], 3);

        let meta = call(&fixture, "cards.metadata", serde_json::json!({ "id": &id }));
        let meta: CardMetadataReply = serde_json::from_value(meta).unwrap();
        assert_eq!(meta.id, id);
        assert!(!meta.liked && !meta.bookmarked);

        let deleted = call(&fixture, "cards.delete", serde_json::json!({ "id": &id }));
        assert_eq!(deleted["deleted"], true);
        let gone = call(&fixture, "cards.get", serde_json::json!({ "id": &id }));
        let gone: CardGetReply = serde_json::from_value(gone).unwrap();
        assert!(gone.card.is_none(), "deleted card must not round-trip");
    }

    #[test]
    fn cards_get_missing_returns_not_found_not_stub() {
        let fixture = isolated_gateway();
        let reply = call(
            &fixture,
            "cards.get",
            serde_json::json!({ "id": "definitely-missing" }),
        );
        let reply: CardGetReply = serde_json::from_value(reply.clone())
            .unwrap_or_else(|e| panic!("typed CardGetReply must decode {reply}: {e}"));
        assert!(
            reply.card.is_none(),
            "missing card must be null, not a fabricated document: {reply:?}"
        );

        for payload in [serde_json::json!({ "id": "   " }), serde_json::json!({})] {
            let err = dispatch(&fixture, "cards.get", &payload)
                .expect_err("missing or blank id must be rejected");
            assert_eq!(err.code(), "rpc_handler_error");
        }
    }

    #[test]
    fn cards_import_idempotent_does_not_duplicate() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let payload = serde_json::json!({
            "card": { "spec": "chara_card_v2", "data": { "name": "Imported Twice" } }
        });
        let first = call(&fixture, "cards.import", payload.clone());
        let first: CardImportReply = serde_json::from_value(first).unwrap();
        assert!(!first.renamed);
        assert_eq!(first.name, "Imported Twice");

        let second = call(&fixture, "cards.import", payload);
        let second: CardImportReply = serde_json::from_value(second).unwrap();
        assert!(second.renamed);
        assert_eq!(second.name, "Imported Twice (2)");
        assert_ne!(first.id, second.id);

        let listed = call(&fixture, "cards.list", serde_json::json!({ "limit": 10 }));
        let listed: CardListReply = serde_json::from_value(listed).unwrap();
        assert_eq!(listed.cards.len(), 2);
        let original = call(&fixture, "cards.get", serde_json::json!({ "id": first.id }));
        assert_eq!(original["card"]["data"]["name"], "Imported Twice");
        let renamed = call(
            &fixture,
            "cards.get",
            serde_json::json!({ "id": second.id }),
        );
        assert_eq!(renamed["card"]["data"]["name"], "Imported Twice (2)");
    }

    #[test]
    fn sessions_list_excludes_deleted_session() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        send(&fixture, "keep-session", "keep me");
        send(&fixture, "drop-session", "delete me");

        let before = call(
            &fixture,
            "sessions.list",
            serde_json::json!({ "limit": 10 }),
        );
        let before: Vec<String> = before["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["id"].as_str().unwrap().to_string())
            .collect();
        assert!(before.contains(&"keep-session".to_string()));
        assert!(before.contains(&"drop-session".to_string()));

        let payload = serde_json::to_value(SessionDeleteRequest {
            session_id: "drop-session".to_string(),
        })
        .unwrap();
        let deleted = call(&fixture, "sessions.delete", payload);
        let deleted: SessionDeleteReply = serde_json::from_value(deleted).unwrap();
        assert!(deleted.deleted);

        let after = call(
            &fixture,
            "sessions.list",
            serde_json::json!({ "limit": 10 }),
        );
        let after: Vec<String> = after["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|s| s["id"].as_str().unwrap().to_string())
            .collect();
        assert!(after.contains(&"keep-session".to_string()));
        assert!(!after.contains(&"drop-session".to_string()));
    }

    #[test]
    fn session_delete_message_count_zero_after_delete() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        send(&fixture, "deleted-messages", "one");
        send(&fixture, "deleted-messages", "two");

        wait_for_history(&fixture, "deleted-messages", 2);

        let request = serde_json::to_value(SessionDeleteRequest {
            session_id: "deleted-messages".to_string(),
        })
        .unwrap();
        let deleted = call(&fixture, "sessions.delete", request.clone());
        assert_eq!(deleted["deleted"], true);

        let status = call(&fixture, "core.status", serde_json::json!({}));
        assert_eq!(status["messageCount"], 0);
        assert_eq!(status["sessionCount"], 0);
        let history = call(
            &fixture,
            "chat.history",
            serde_json::json!({ "session_id": "deleted-messages", "limit": 10 }),
        );
        assert!(history["messages"].as_array().unwrap().is_empty());

        let second = call(&fixture, "sessions.delete", request);
        let second: SessionDeleteReply = serde_json::from_value(second).unwrap();
        assert!(!second.deleted, "second delete must be idempotent");
    }

    #[test]
    fn chat_send_rpc_ack_shape() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let request = ChatSendRequest {
            session_id: "ack-session".to_string(),
            content: "hello over RPC".to_string(),
            gen_ui: false,
        };
        let ack = call(
            &fixture,
            "chat.send",
            serde_json::to_value(&request).unwrap(),
        );
        let reply: ChatSendReply = serde_json::from_value(ack.clone())
            .unwrap_or_else(|e| panic!("typed ChatSendReply must decode {ack}: {e}"));
        assert_eq!(reply.session_id, "ack-session");
        assert!(reply.accepted);
        assert!(!reply.message_id.is_empty(), "ack must carry assistant id");
        assert!(
            ack.get("sessionId").is_some() && ack.get("messageId").is_some(),
            "wire uses camelCase field names: {ack}"
        );

        wait_for_history(&fixture, "ack-session", 1);
        let history = call(
            &fixture,
            "chat.history",
            serde_json::json!({ "session_id": "ack-session", "limit": 10 }),
        );
        assert_eq!(history["messages"][0]["content"], "hello over RPC");

        let anonymous = send(&fixture, "", "anonymous turn");
        assert!(
            !anonymous.session_id.is_empty(),
            "ack must mint a session id"
        );
    }

    /// airi-vfea: `chat.send` must ignore client-supplied selection fields and
    /// resolve from the daemon-owned `chat-provider` section. A recording
    /// ChatProvider proves the selected provider/model actually receives the
    /// stream, winning over env and row order; a stale selection fails closed.
    #[test]
    fn chat_send_uses_daemon_selection_over_env_and_row_order() {
        use async_trait::async_trait;
        use futures_util::stream;
        use std::sync::Arc;

        use anima_llm::{ChatChunk, ChatRequest, ChatStream, ModelInfo};

        #[derive(Clone)]
        struct RecordingProvider {
            id: String,
            routed: Arc<Mutex<Vec<(String, String)>>>,
        }

        #[async_trait]
        impl anima_llm::ChatProvider for RecordingProvider {
            fn id(&self) -> &str {
                &self.id
            }
            async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(&self, req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
                self.routed
                    .lock()
                    .unwrap()
                    .push((self.id().to_string(), req.model));
                Ok(Box::pin(stream::iter(vec![
                    Ok(ChatChunk::text("routed")),
                    Ok(ChatChunk::finish("stop")),
                ])))
            }
        }

        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let _provider_env = ProviderEnvGuard::override_with("env-provider", "env-model");

        let routed: Arc<Mutex<Vec<(String, String)>>> = Arc::new(Mutex::new(Vec::new()));
        fixture
            .core
            .chat_service()
            .expect("chat service")
            .register_client(
                "chosen-provider",
                Arc::new(RecordingProvider {
                    id: "chosen-provider".to_string(),
                    routed: routed.clone(),
                }),
            );

        // The first-enabled row would win without a stored selection.
        call(
            &fixture,
            "providers.save",
            serde_json::json!({
                "id": "first-enabled",
                "kind": "open-ai-compatible",
                "model": "first-model",
                "enabled": true
            }),
        );
        call(
            &fixture,
            "providers.save",
            serde_json::json!({
                "id": "chosen-provider",
                "kind": "open-ai-compatible",
                "model": "stored-model",
                "enabled": true
            }),
        );
        call(
            &fixture,
            "settings.set",
            serde_json::json!({
                "section": "chat-provider",
                "settings": {
                    "activeProvider": "chosen-provider",
                    "activeModel": "picked-model"
                }
            }),
        );

        let ack = call(
            &fixture,
            "chat.send",
            serde_json::json!({
                "sessionId": "selection-session",
                "content": "route me",
                "genUi": false,
                "activeProvider": "first-enabled",
                "activeModel": "client-model"
            }),
        );
        let reply: ChatSendReply = serde_json::from_value(ack).unwrap();
        assert_eq!(reply.session_id, "selection-session");
        wait_for_history(&fixture, "selection-session", 2);
        assert_eq!(
            routed.lock().unwrap().as_slice(),
            &[("chosen-provider".to_string(), "picked-model".to_string())],
            "the daemon selection, not the client/env/first row, must reach the provider"
        );

        // A stale selection fails closed: the turn is persisted, but no
        // generation is started for a provider the user did not select.
        call(
            &fixture,
            "settings.set",
            serde_json::json!({
                "section": "chat-provider",
                "settings": { "activeProvider": "gone", "activeModel": "" }
            }),
        );
        let stale = call(
            &fixture,
            "chat.send",
            serde_json::json!({
                "sessionId": "stale-session",
                "content": "do not fall back",
                "genUi": false
            }),
        );
        let stale: ChatSendReply = serde_json::from_value(stale).unwrap();
        assert_eq!(stale.session_id, "stale-session");
        wait_for_history(&fixture, "stale-session", 1);
        assert_eq!(
            routed.lock().unwrap().len(),
            1,
            "a stale selection must not route to env or first-enabled provider"
        );
    }

    #[test]
    fn chat_send_empty_content_rejected() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        for content in ["", "   \n  "] {
            let request = ChatSendRequest {
                session_id: "empty-content".to_string(),
                content: content.to_string(),
                gen_ui: false,
            };
            let err = dispatch(
                &fixture,
                "chat.send",
                &serde_json::to_value(request).unwrap(),
            )
            .expect_err("empty content must be rejected");
            assert_eq!(err.code(), "rpc_handler_error");
        }
        let status = call(&fixture, "core.status", serde_json::json!({}));
        assert_eq!(status["sessionCount"], 0);
        assert_eq!(status["messageCount"], 0);
    }

    #[test]
    fn providers_list_returns_registered_providers() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let empty = call(&fixture, "providers.list", serde_json::json!({}));
        let empty: ProvidersListReply = serde_json::from_value(empty).unwrap();
        assert!(empty.providers.is_empty());

        let saved = call(
            &fixture,
            "providers.save",
            serde_json::json!({
                "id": "contract-provider",
                "kind": "open-ai-compatible",
                "model": "gpt-test",
                "baseUrl": "https://example.test/v1",
                "apiKey": "secret-never-on-wire",
                "enabled": true
            }),
        );
        assert_eq!(saved["ok"], true);
        assert_eq!(saved["id"], "contract-provider");
        assert!(
            !serde_json::to_string(&saved)
                .unwrap()
                .contains("secret-never-on-wire"),
            "write reply must be secret-free"
        );

        let listed = call(&fixture, "providers.list", serde_json::json!({}));
        let reply: ProvidersListReply = serde_json::from_value(listed.clone())
            .unwrap_or_else(|e| panic!("typed ProvidersListReply must decode {listed}: {e}"));
        let info = reply
            .providers
            .iter()
            .find(|p| p.id == "contract-provider")
            .expect("registered provider must be listed");
        assert_eq!(
            info,
            &ProviderInfo {
                id: "contract-provider".to_string(),
                kind: "open-ai-compatible".to_string(),
                model: "gpt-test".to_string(),
                base_url: "https://example.test/v1".to_string(),
                enabled: true,
                updated_at: info.updated_at,
            }
        );
        assert!(info.updated_at > 0);
        assert!(
            !serde_json::to_string(&reply)
                .unwrap()
                .contains("secret-never-on-wire"),
            "providers.list must never echo secrets"
        );
    }

    #[test]
    fn providers_create_update_delete_round_trip() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let saved = call(
            &fixture,
            "providers.save",
            serde_json::json!({
                "id": "round-trip-provider",
                "kind": "open-ai-compatible",
                "model": "first-model",
                "baseUrl": "https://first.test/v1",
                "apiKey": "write-only-secret",
                "enabled": true
            }),
        );
        assert_eq!(saved["ok"], true);
        assert!(!serde_json::to_string(&saved)
            .unwrap()
            .contains("write-only-secret"));

        let listed = call(&fixture, "providers.list", serde_json::json!({}));
        let reply: ProvidersListReply = serde_json::from_value(listed).unwrap();
        let info = reply
            .providers
            .iter()
            .find(|p| p.id == "round-trip-provider")
            .unwrap();
        assert_eq!(info.model, "first-model");
        assert_eq!(info.base_url, "https://first.test/v1");
        assert!(info.enabled);

        // Partial update preserves secret and unrelated config.
        dispatch(
            &fixture,
            "providers.save",
            &serde_json::json!({ "id": "round-trip-provider", "model": "second-model" }),
        )
        .unwrap();
        let listed = call(&fixture, "providers.list", serde_json::json!({}));
        let reply: ProvidersListReply = serde_json::from_value(listed).unwrap();
        let info = reply
            .providers
            .iter()
            .find(|p| p.id == "round-trip-provider")
            .unwrap();
        assert_eq!(info.model, "second-model");
        assert_eq!(info.base_url, "https://first.test/v1");

        let deleted = call(
            &fixture,
            "providers.delete",
            serde_json::json!({ "id": "round-trip-provider" }),
        );
        assert_eq!(deleted["ok"], true);
        assert_eq!(deleted["deleted"], true);
        let listed = call(&fixture, "providers.list", serde_json::json!({}));
        let reply: ProvidersListReply = serde_json::from_value(listed).unwrap();
        assert!(reply.providers.is_empty());
        let second = call(
            &fixture,
            "providers.delete",
            serde_json::json!({ "id": "round-trip-provider" }),
        );
        assert_eq!(second["deleted"], false);
    }

    #[test]
    fn rpc_unknown_method_for_cards_returns_rpc_unknown_method() {
        let fixture = isolated_gateway();
        for method in ["cards.unknown", "cards.getUnknown", "cardz.list"] {
            let err = dispatch(&fixture, method, &serde_json::json!({}))
                .expect_err("{method} must not be registered");
            assert_eq!(
                err.code(),
                "rpc_unknown_method",
                "{method}: unexpected code {} ({})",
                err.code(),
                err.message()
            );
            assert!(err.message().contains(method));
        }
        let verbs = verbs(&fixture);
        for method in [
            "cards.list",
            "cards.get",
            "cards.import",
            "cards.create",
            "cards.update",
            "cards.delete",
            "cards.metadata",
        ] {
            assert!(verbs.contains_key(method), "{method} must be registered");
        }
    }

    /// A collect → inspect → apply round trip using a real temp-dir store.
    /// The archive is carried as base64 with no credential fields on the wire.
    #[test]
    fn vault_archive_collect_inspect_apply_round_trip() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        // A real message row, written through the gateway like a thin client.
        send(&fixture, "archive-session", "archive me");

        let collected = call(
            &fixture,
            "vault.archive.collect",
            serde_json::json!({ "domains": ["chats", "memory"] }),
        );
        let archive: VaultArchiveReply = serde_json::from_value(collected.clone())
            .unwrap_or_else(|e| panic!("typed VaultArchiveReply must decode {collected}: {e}"));
        assert_eq!(archive.domains, ["chats", "memory"]);
        assert!(archive.bytes > 0);
        let serialized = serde_json::to_string(&archive).unwrap();
        for forbidden in ["apiKey", "api_key", "secret", "authToken", "token"] {
            assert!(
                !serialized.contains(forbidden),
                "archive reply leaks {forbidden}"
            );
        }

        let inspected = call(
            &fixture,
            "vault.archive.inspect",
            serde_json::json!({ "archive": archive.archive }),
        );
        let report: VaultArchiveInspectReply = serde_json::from_value(inspected.clone())
            .unwrap_or_else(|e| {
                panic!("typed VaultArchiveInspectReply must decode {inspected}: {e}")
            });
        assert_eq!(report.format, "airi-vault");
        assert!(!report.includes_secrets);
        assert_eq!(report.session_count, 1);

        let applied = call(
            &fixture,
            "vault.archive.apply",
            serde_json::json!({ "archive": archive.archive }),
        );
        let report: VaultArchiveApplyReply = serde_json::from_value(applied.clone())
            .unwrap_or_else(|e| panic!("typed VaultArchiveApplyReply must decode {applied}: {e}"));
        // Existing rows win: the session already present is skipped, nothing
        // is fabricated from an empty archive.
        assert_eq!(report.sessions_skipped, 1);
        assert_eq!(report.sessions_inserted, 0);
        assert!(report.applied.contains(&"chats".to_string()));
    }

    #[test]
    fn vault_archive_rejects_provider_domain_and_credentials() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let err = dispatch(
            &fixture,
            "vault.archive.collect",
            &serde_json::json!({ "domains": ["providers"] }),
        )
        .expect_err("provider domain must never cross the wire");
        assert_eq!(err.code(), "rpc_handler_error");
        assert!(err.message().contains("providers"));

        // An archive claiming provider credentials is inspectable (metadata
        // only) but must never be applied locally.
        let with_secrets = secret_marked_archive(&fixture);
        let inspected = call(
            &fixture,
            "vault.archive.inspect",
            serde_json::json!({ "archive": with_secrets }),
        );
        let report: VaultArchiveInspectReply = serde_json::from_value(inspected).unwrap();
        assert!(report.includes_secrets);
        let err = dispatch(
            &fixture,
            "vault.archive.apply",
            &serde_json::json!({ "archive": with_secrets }),
        )
        .expect_err("credential-bearing archives must be rejected");
        assert_eq!(err.code(), "rpc_handler_error");
        assert!(!err.message().contains("apiKey"));
    }

    #[test]
    fn vault_archive_writes_are_action_gated() {
        let fixture = isolated_gateway();
        // Every verb that mutates local state must be behind allowActions.
        // Each payload is valid for its handler, so the gate is the first
        // thing to refuse it (not request-shape validation).
        let card = card_document("gate-card");
        for (method, payload) in [
            (
                "vault.archive.collect",
                serde_json::json!({ "domains": ["chats"] }),
            ),
            (
                "vault.archive.apply",
                serde_json::json!({ "archive": "YWJj" }),
            ),
            (
                "sessions.media.scrub",
                serde_json::json!({ "createBackup": false }),
            ),
            ("stmm.upsert", serde_json::json!({ "blocks": [] })),
            ("stmm.rebuild", serde_json::json!({})),
            ("journal.append", serde_json::json!({})),
            ("journal.delete", serde_json::json!({ "id": "j1" })),
            (
                "cards.import",
                serde_json::json!({ "card": card.clone(), "pngBase64": null }),
            ),
            (
                "cards.create",
                serde_json::json!({ "name": "Gate", "document": card.clone() }),
            ),
            (
                "cards.update",
                serde_json::json!({ "id": "c1", "document": card.clone() }),
            ),
            ("cards.delete", serde_json::json!({ "id": "c1" })),
            (
                "cards.metadata.set",
                serde_json::json!({ "id": "c1", "liked": true, "bookmarked": false }),
            ),
            ("sessions.delete", serde_json::json!({ "session_id": "s1" })),
            ("sessions.import", serde_json::json!({ "jsonl": "" })),
            (
                "sessions.universe.set",
                serde_json::json!({ "session_id": "s1", "universe_id": "u1" }),
            ),
        ] {
            let err = dispatch(&fixture, method, &payload)
                .expect_err(&format!("{method} must be denied without allowActions"));
            assert_eq!(err.code(), "rpc_actions_disabled", "{method}: {err:?}");
        }
        // The inspect verb is metadata-only and stays available without the
        // write opt-in.
        let reply = secret_marked_archive(&fixture);
        let inspected = call(
            &fixture,
            "vault.archive.inspect",
            serde_json::json!({ "archive": reply }),
        );
        let _: VaultArchiveInspectReply = serde_json::from_value(inspected).unwrap();
    }

    #[test]
    fn vault_archive_reply_is_rejected_before_it_can_overflow_a_frame() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        // The reply envelope includes the base64 archive plus metadata.
        // A payload at (or above) the socket limit must never be written:
        // `vault.archive.collect` returns a typed error before that happens.
        // Build the largest legal request and assert that a normal reply
        // still fits, so the guard cannot break valid exports.
        let collected = call(
            &fixture,
            "vault.archive.collect",
            serde_json::json!({ "domains": ["chats", "memory"] }),
        );
        let encoded = serde_json::to_string(&collected).unwrap();
        assert!(
            (encoded.len() as u64) <= anima_channel::ws::MAX_WS_PAYLOAD_BYTES,
            "normal archive reply must fit one frame"
        );
    }

    #[test]
    fn vault_archive_inbound_is_bounded_by_the_ws_frame_limit() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        // 1 MiB of base64 is a legal single frame on the socket, but is far
        // above the decoded vault cap; reject with a typed handler error
        // instead of attempting ZIP parsing or a large allocation.
        let oversized = "A".repeat(anima_channel::ws::MAX_WS_PAYLOAD_BYTES as usize);
        let err = dispatch(
            &fixture,
            "vault.archive.inspect",
            &serde_json::json!({ "archive": oversized }),
        )
        .expect_err("oversized archive must be rejected before decoding");
        assert_eq!(err.code(), "rpc_handler_error");
        assert!(err.message().contains("byte limit"), "{err:?}");
    }

    #[test]
    fn sessions_media_scrub_reports_zero_without_images() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        send(&fixture, "scrub-image-session", "plain text only");
        wait_for_history(&fixture, "scrub-image-session", 1);
        let reply = call(
            &fixture,
            "sessions.media.scrub",
            serde_json::json!({ "createBackup": false }),
        );
        let report: SessionMediaScrubReply = serde_json::from_value(reply.clone())
            .unwrap_or_else(|e| panic!("typed SessionMediaScrubReply must decode {reply}: {e}"));
        assert_eq!(report.images_found, 0);
        assert_eq!(report.bytes_extracted, 0);
        assert_eq!(report.sessions_scanned, 0);
        assert!(report.backup_path.is_none());

        // A second session with a real inline image must be detected and
        // extracted. The payload is 96 base64 chars (>64), matching the
        // scanner's minimum, and decodes to non-zero bytes.
        send(
            &fixture,
            "scrub-image-session",
            &format!("here is an image: data:image/png;base64,{}", "A".repeat(96)),
        );
        wait_for_history(&fixture, "scrub-image-session", 2);
        let report: SessionMediaScrubReply = serde_json::from_value(call(
            &fixture,
            "sessions.media.scrub",
            serde_json::json!({ "createBackup": false }),
        ))
        .expect("typed SessionMediaScrubReply must decode scrub report");
        assert_eq!(report.images_found, 1);
        assert!(report.bytes_extracted > 0);
        assert_eq!(report.sessions_scanned, 1);

        let err = dispatch(&fixture, "sessions.media.scrub", &serde_json::json!({}))
            .expect_err("missing create_backup must be rejected");
        assert_eq!(err.code(), "rpc_handler_error");
    }

    #[test]
    fn sessions_media_scrub_is_action_gated() {
        let fixture = isolated_gateway();
        let err = dispatch(
            &fixture,
            "sessions.media.scrub",
            &serde_json::json!({ "createBackup": false }),
        )
        .expect_err("scrub must be denied without allowActions");
        assert_eq!(err.code(), "rpc_actions_disabled");
    }

    /// Build an archive whose manifest advertises credentials without ever
    /// putting credential material on the wire or in the test source. The
    /// manifest is rebuilt so the ZIP CRC stays valid.
    fn secret_marked_archive(fixture: &Fixture) -> String {
        use base64::Engine as _;
        // Build a minimal airi-vault manifest with a `true` secrets flag.
        // No credential bytes ever enter the archive or the wire.
        let mut manifest: serde_json::Value = serde_json::from_str(
            r#"{"format":"airi-vault","version":1,"created_at":1,"includes_secrets":false,"domains":[],"counts":{},"notes":[]}"#,
        )
        .unwrap();
        manifest["includes_secrets"] = serde_json::json!(true);
        let bytes = anima_core::vault::zip_stored(&[(
            "manifest.json",
            serde_json::to_vec(&manifest).unwrap().as_slice(),
        )])
        .unwrap();
        base64::engine::general_purpose::STANDARD.encode(&bytes)
    }

    #[test]
    fn rpc_settings_set_stage_model_and_display_model_resolve() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);

        let descriptor = serde_json::json!({
            "id": "model-1",
            "name": "Model One",
            "format": "vrm",
            "source": "file",
            "file": "/tmp/model.vrm",
            "url": ""
        });

        call(
            &fixture,
            "settings.set",
            serde_json::json!({
                "section": "stage-model",
                "settings": { "catalog": [descriptor.clone()] }
            }),
        );

        let resolved = call(
            &fixture,
            "display-model.resolve",
            serde_json::json!({ "id": "model-1" }),
        );
        let catalog: CatalogDescriptor = serde_json::from_value(resolved).unwrap();
        assert_eq!(catalog.id, "model-1");

        let err = dispatch(
            &fixture,
            "display-model.resolve",
            &serde_json::json!({ "id": "nope" }),
        )
        .expect_err("unknown id must fail");
        assert!(err.message().contains("unknown display model id"));
    }
    #[test]
    fn journal_delete_removes_only_the_named_entry() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let append = |content: &str| -> String {
            let reply = call(
                &fixture,
                "journal.append",
                serde_json::json!({ "content": content }),
            );
            reply["id"].as_str().unwrap().to_string()
        };
        let removed = append("user asked to forget this");
        let _kept = append("this entry stays");
        let search = |query: &str| -> serde_json::Value {
            call(
                &fixture,
                "journal.search",
                serde_json::json!({ "query": query }),
            )
        };
        assert_eq!(
            search("forget this")["entries"].as_array().unwrap().len(),
            1
        );

        let deleted = call(
            &fixture,
            "journal.delete",
            serde_json::json!({ "id": &removed }),
        );
        assert_eq!(deleted["deleted"], true);
        assert!(search("forget this")["entries"]
            .as_array()
            .unwrap()
            .is_empty());
        assert_eq!(
            search("this entry stays")["entries"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        assert_eq!(
            call(
                &fixture,
                "journal.delete",
                serde_json::json!({ "id": &removed })
            )["deleted"],
            false,
            "delete is idempotent"
        );
    }

    #[test]
    fn stmm_list_defaults_to_a_finite_ceiling() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        for index in 0..600 {
            call(
                &fixture,
                "stmm.upsert",
                serde_json::json!({
                    "blocks": [{
                        "id": format!("summary-{index}"),
                        "day": format!("2026-11-{:02}", index % 28 + 1),
                        "content": "block",
                    }]
                }),
            );
        }
        let listed = call(&fixture, "stmm.list", serde_json::json!({}));
        assert_eq!(
            listed["summaries"].as_array().unwrap().len(),
            50,
            "legacy default stays"
        );
        let full = call(
            &fixture,
            "stmm.list",
            serde_json::json!({ "limit": u64::MAX }),
        );
        assert_eq!(full["summaries"].as_array().unwrap().len(), 500);
    }

    /// Companion module sections are daemon-owned. Each round trip must pass
    /// through the registered `settings_section()` type, with camelCase wire
    /// keys and Vue-matching defaults on first read.
    #[test]
    fn module_settings_sections_round_trip_via_rpc() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);

        // airi-wkfa: one faculty is enough to pin the camelCase wire shape;
        // the other three fall back to their factory-safe defaults on read.
        let faculties = serde_json::json!({
            "consciousness": {
                "primaryProvider": "kilo",
                "primaryModel": "kilo-auto/free",
                "primaryVoiceId": "",
                "fallbackProvider": "web-llm",
                "fallbackModel": "",
                "fallbackVoiceId": "",
                "autoFailover": true,
                "failoverTriggers": ["auth", "quota", "server_error", "timeout"],
                "notificationStyle": "toast",
                "recoveryIntervalMinutes": 15
            }
        });
        let cases: Vec<(&str, serde_json::Value, serde_json::Value, &str)> = vec![
            (
                "consciousness",
                serde_json::json!({
                    "activeProvider": "anthropic",
                    "activeModel": "claude-x",
                    "activeCustomModel": "custom-llm",
                }),
                serde_json::json!({
                    "activeProvider": "anthropic",
                    "activeModel": "claude-x",
                    "activeCustomModel": "custom-llm",
                }),
                "activeProvider",
            ),
            (
                "speech",
                serde_json::json!({
                    "activeProvider": "piper",
                    "voice": "aria",
                    "pitch": 1.5,
                    "rate": 0.8,
                    "ssmlEnabled": true,
                    "language": "ja-JP",
                }),
                serde_json::json!({
                    "activeProvider": "piper",
                    "activeModel": "",
                    "voice": "aria",
                    "outputVolume": 1.0,
                    "enabled": true,
                    "pitch": 1.5,
                    "rate": 0.8,
                    "ssmlEnabled": true,
                    "language": "ja-JP",
                    "voiceProfiles": [],
                }),
                "voice",
            ),
            (
                "hearing",
                serde_json::json!({
                    "activeProvider": "whisper-local",
                    "autoSendEnabled": false,
                    "autoSendDelay": 750,
                    "detectionMode": "manual",
                    "vadThreshold": 0.9,
                }),
                serde_json::json!({
                    "activeProvider": "whisper-local",
                    "activeModel": "",
                    "activeCustomModel": "",
                    "autoSendEnabled": false,
                    "autoSendDelay": 750,
                    "detectionMode": "manual",
                    "tapToTalk": true,
                    "voiceInputMode": "dictation",
                    "vadThreshold": 0.9,
                    "speechProviderSettings": {},
                    "transcriptionProviderSettings": {},
                }),
                "autoSendDelay",
            ),
            (
                "vision",
                serde_json::json!({
                    "strategy": "forward",
                    "contextWindow": 3,
                    "witnessEnabled": true,
                    "respectSchedule": false,
                }),
                serde_json::json!({
                    "strategy": "forward",
                    "activeProvider": "",
                    "activeModel": "",
                    "contextWindow": 3,
                    "activeAdvanced": {},
                    "witnessEnabled": true,
                    "respectSchedule": false,
                }),
                "contextWindow",
            ),
            (
                "faculties",
                faculties.clone(),
                faculties.clone(),
                "consciousness",
            ),
            ("faculties", faculties.clone(), faculties, "speech"),
        ];

        for (section, incoming, expected, probe) in cases {
            let set_reply = call(
                &fixture,
                "settings.set",
                serde_json::json!({ "section": section, "settings": incoming }),
            );
            assert_eq!(set_reply["ok"], true, "{section}");

            let get_reply = call(
                &fixture,
                "settings.get",
                serde_json::json!({ "section": section }),
            );
            assert_eq!(get_reply["section"], section);
            let settings: serde_json::Value =
                serde_json::from_str(get_reply["settings"].as_str().unwrap()).unwrap();
            for (key, expected_value) in expected.as_object().unwrap() {
                assert_eq!(&settings[key], expected_value, "{section}.{key}");
            }
            assert!(settings.get(probe).is_some(), "{section}.{probe}");
            // Ephemeral keys never travel through the typed section.
            assert!(settings.get("lastHeartbeat").is_none());
            assert!(settings.get("micOwner").is_none());
        }
    }

    #[test]
    fn partial_settings_writes_keep_object_fields_as_objects() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let first = call(
            &fixture,
            "settings.get",
            serde_json::json!({ "section": "hearing" }),
        );
        let first_settings: serde_json::Value =
            serde_json::from_str(first["settings"].as_str().unwrap()).unwrap();
        assert_eq!(
            first_settings["speechProviderSettings"],
            serde_json::json!({})
        );
        assert_eq!(
            first_settings["transcriptionProviderSettings"],
            serde_json::json!({})
        );
        let first = call(
            &fixture,
            "settings.get",
            serde_json::json!({ "section": "vision" }),
        );
        let first_settings: serde_json::Value =
            serde_json::from_str(first["settings"].as_str().unwrap()).unwrap();
        assert_eq!(first_settings["activeAdvanced"], serde_json::json!({}));

        call(
            &fixture,
            "settings.set",
            serde_json::json!({ "section": "hearing", "settings": { "vadThreshold": 0.8 } }),
        );
        let after = call(
            &fixture,
            "settings.get",
            serde_json::json!({ "section": "hearing" }),
        );
        let after_settings: serde_json::Value =
            serde_json::from_str(after["settings"].as_str().unwrap()).unwrap();
        assert_eq!(
            after_settings["speechProviderSettings"],
            serde_json::json!({})
        );
        assert_eq!(
            after_settings["transcriptionProviderSettings"],
            serde_json::json!({})
        );
        assert_eq!(after_settings["vadThreshold"], 0.8);

        call(
            &fixture,
            "settings.set",
            serde_json::json!({ "section": "vision", "settings": { "contextWindow": 3 } }),
        );
        let after = call(
            &fixture,
            "settings.get",
            serde_json::json!({ "section": "vision" }),
        );
        let after_settings: serde_json::Value =
            serde_json::from_str(after["settings"].as_str().unwrap()).unwrap();
        assert_eq!(after_settings["activeAdvanced"], serde_json::json!({}));
        assert_eq!(after_settings["contextWindow"], 3);
    }

    #[test]
    fn module_settings_reject_invalid_values_and_stay_action_gated() {
        // Writes are gated by allowActions; reads are not.
        let gated = isolated_gateway();
        for section in ["consciousness", "speech", "hearing", "vision"] {
            let err = dispatch(
                &gated,
                "settings.set",
                &serde_json::json!({ "section": section, "settings": {} }),
            )
            .expect_err("settings.set must be denied without allowActions");
            assert_eq!(err.code(), "rpc_actions_disabled", "{section}: {err:?}");
        }

        // Reuse the same fixture: creating a second gateway while the first
        // holds the process-global config path deadlocks fixture setup.
        enable_actions(&gated);
        for (section, settings) in [
            ("speech", serde_json::json!({ "rate": "fast" })),
            ("hearing", serde_json::json!({ "autoSendDelay": "soon" })),
            ("vision", serde_json::json!({ "contextWindow": "many" })),
        ] {
            let err = dispatch(
                &gated,
                "settings.set",
                &serde_json::json!({ "section": section, "settings": settings }),
            )
            .expect_err("invalid numbers must not reach the store");
            assert_eq!(err.code(), "rpc_handler_error", "{section}: {err:?}");
            assert!(err.message().contains("invalid settings shape"));
        }
    }

    // ROOT CAUSE:
    //
    // `AIRI_SERVER_CHANNEL_CONFIG` is process-global and `ENV_LOCK` is a
    // non-reentrant `Mutex`. A second `isolated_gateway()` while the first
    // fixture is alive blocks forever trying to lock the same mutex from the
    // same test thread. The guard must reject that request before locking.
    #[test]
    fn second_isolated_gateway_fails_fast_on_one_test_thread() {
        let (tx, rx) = mpsc::channel();
        let worker = std::thread::spawn(move || {
            let first = isolated_gateway();
            let outcome = std::panic::catch_unwind(|| isolated_gateway());
            let message = match outcome {
                Ok(_) => "second fixture was created".to_string(),
                Err(panic) => panic
                    .downcast_ref::<String>()
                    .cloned()
                    .or_else(|| panic.downcast_ref::<&str>().map(|s| (*s).to_string()))
                    .unwrap_or_default(),
            };
            // Report only after the first fixture is fully dropped so the
            // caller sees a released thread-local token and lock guard.
            drop(first);
            let token_released = !THREAD_HAS_FIXTURE.with(Cell::get);
            let _ = tx.send((message, token_released));
        });
        let (message, token_released) = rx
            .recv_timeout(Duration::from_secs(10))
            .expect("second isolated_gateway() must fail fast instead of deadlocking");
        worker
            .join()
            .expect("fixture worker must not panic outside catch_unwind");
        assert_eq!(message, SECOND_FIXTURE_PANIC);
        assert!(token_released, "first fixture must drop cleanly");
        assert!(
            !ENV_LOCK.is_poisoned(),
            "a rejected second fixture must not poison ENV_LOCK"
        );
    }
}
