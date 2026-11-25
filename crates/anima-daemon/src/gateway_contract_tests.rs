// SPDX-License-Identifier: GPL-3.0-or-later

//! Wire-level contract tests against the gateway's real handler map.
//!
//! These call `Gateway::renderer_handlers` directly, so the tests fail if a
//! verb is renamed, removed, or its wire payload changes shape.

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::{Arc, Mutex};

    use anima_channel::dispatch::{RendererHandlers, RpcContext, RpcError, RpcRegistry};
    use anima_channel::wire::{
        CardCreateRequest, CardGetReply, CardImportReply, CardInfo, CardListReply,
        CardMetadataReply, ChatSendReply, ChatSendRequest, ProviderInfo, ProvidersListReply,
        SessionDeleteReply, SessionDeleteRequest,
    };
    use tempfile::tempdir;

    use crate::core::CoreService;
    use crate::gateway::Gateway;

    struct Fixture {
        gateway: Gateway,
        core: CoreService,
        config_path: std::path::PathBuf,
        _tmp: tempfile::TempDir,
        _env_guard: EnvGuard,
    }

    /// `AIRI_SERVER_CHANNEL_CONFIG` is process-global; serialize fixtures that
    /// set it so parallel tests cannot steal each other's config path.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    type EnvGuard = std::sync::MutexGuard<'static, ()>;

    fn isolated_gateway() -> Fixture {
        let guard: EnvGuard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
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
        Fixture {
            gateway,
            core,
            config_path,
            _tmp: tmp,
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
}
