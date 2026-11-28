// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust conformance test: every golden fixture under
//! `fixtures/golden/` must deserialize into its wire type and
//! re-serialize to a byte-equal JSON value.
//!
//! This is the Rust leg of the three-job conformance CI
//! (airi-wxp.2.8). The Dart and C# legs run the same fixtures
//! through their own codecs.
//!
//! ```sh
//! cargo test -p anima-channel --locked golden_fixtures
//! ```

#[cfg(test)]
mod golden_fixtures {
    use anima_channel::asset::{AssetCatalogManifest, AssetDownloadMetadata};
    use anima_channel::provider::ProviderValidationState;
    use anima_channel::wire::{
        CapabilitiesReply, CardCreateReply, CardCreateRequest, CardDeleteReply, CardDeleteRequest,
        CardGetReply, CardImportReply, CardImportRequest, CardListReply, CardMetadataReply,
        CardMetadataSetRequest, CardUpdateReply, CardUpdateRequest, ChatSendRequest,
        CoreStatusReply, DiscordStatusReply, EventSubscriptionReply, GatewayAuthReply,
        GatewayConfigReply, GatewayServerFrame, HeartbeatData, ProvidersListReply,
        ProvidersModelsReply, RpcErrorObject, RuntimePingReply, RuntimeStatusReply,
        SessionDeleteReply, SessionDeleteRequest, SessionImportReply, SettingsGetReply,
        SettingsSetReply, VaultStatusReply,
    };
    use serde::de::DeserializeOwned;
    use serde::Serialize;
    use std::path::{Path, PathBuf};

    fn fixtures_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden")
    }

    /// Load a fixture file as pretty JSON text and parse it.
    fn load_json(name: &str) -> serde_json::Value {
        let path = fixtures_dir().join(format!("{name}.json"));
        let text = std::fs::read_to_string(&path)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
        serde_json::from_str(&text)
            .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
    }

    /// Round-trip helper: deserialize `value` into `T`, re-serialize, and
    /// assert both directions are byte-equal to the original.
    fn round_trip<T>(name: &str, value: &serde_json::Value)
    where
        T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug,
    {
        let decoded: T = serde_json::from_value(value.clone())
            .unwrap_or_else(|e| panic!("{name}: deserialize failed: {e}"));
        let re_encoded = serde_json::to_value(&decoded)
            .unwrap_or_else(|e| panic!("{name}: serialize failed: {e}"));
        assert_eq!(
            value, &re_encoded,
            "{name}: round-trip mismatch\n  expected: {value}\n  got: {re_encoded}"
        );
    }

    // ----------------------------------------------------------------
    // Event frame fixtures (wrapped in GatewayServerFrame::Event)
    // ----------------------------------------------------------------

    #[test]
    fn event_lip_sync_rms_fixtures() {
        for name in &[
            "event.lip_sync_rms.silence",
            "event.lip_sync_rms.basic",
            "event.lip_sync_rms.peak",
        ] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(name, &value);
        }
    }

    #[test]
    fn event_emotion_tag_fixtures() {
        for name in &[
            "event.emotion_tag.emotion",
            "event.emotion_tag.motion_no_duration",
            "event.emotion_tag.vfx",
            "event.emotion_tag.with_session",
        ] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(name, &value);
        }
    }

    #[test]
    fn event_token_delta_fixtures() {
        for name in &["event.token_delta.partial", "event.token_delta.final"] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(name, &value);
        }
    }

    #[test]
    fn event_presence_changed_fixtures() {
        for name in &[
            "event.presence_changed.online",
            "event.presence_changed.offline",
        ] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(name, &value);
        }
    }

    #[test]
    fn event_status_changed_fixtures() {
        for name in &[
            "event.status_changed.healthy",
            "event.status_changed.unhealthy",
        ] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(name, &value);
        }
    }

    // ----------------------------------------------------------------
    // Core DTO fixtures (standalone JSON objects)
    // ----------------------------------------------------------------

    #[test]
    fn core_status_reply_fixture() {
        let value = load_json("core_status.reply");
        round_trip::<CoreStatusReply>("core_status.reply", &value);
        assert_eq!(value["app"], "anima-daemon");
    }

    #[test]
    fn runtime_ping_reply_fixture() {
        let value = load_json("runtime_ping.reply");
        round_trip::<RuntimePingReply>("runtime_ping.reply", &value);
    }

    #[test]
    fn runtime_status_reply_fixture() {
        let value = load_json("runtime_status.reply");
        round_trip::<RuntimeStatusReply>("runtime_status.reply", &value);
        assert_eq!(value["app"], "airi-slint");
    }

    #[test]
    fn providers_list_reply_fixture() {
        let value = load_json("providers_list.reply");
        round_trip::<ProvidersListReply>("providers_list.reply", &value);
        let decoded: ProvidersListReply = serde_json::from_value(value).unwrap();
        assert_eq!(decoded.providers[0].kind, "open-ai-compatible");
        assert_eq!(decoded.providers[0].updated_at, 1_700_000_000_000);
    }

    #[test]
    fn providers_models_reply_fixture() {
        let value = load_json("providers.models.reply");
        round_trip::<ProvidersModelsReply>("providers.models.reply", &value);
    }

    #[test]
    fn settings_get_reply_fixture() {
        let value = load_json("settings_get.reply");
        round_trip::<SettingsGetReply>("settings_get.reply", &value);
    }

    #[test]
    fn settings_set_reply_fixture() {
        let value = load_json("settings_set.reply");
        round_trip::<SettingsSetReply>("settings_set.reply", &value);
    }

    #[test]
    fn discord_status_reply_fixture_is_token_free() {
        let value = load_json("discord_status.reply");
        round_trip::<DiscordStatusReply>("discord_status.reply", &value);
        assert!(
            value.get("token").is_none(),
            "discord.status must have no token key"
        );
        assert!(value["hasToken"].is_boolean());
    }

    #[test]
    fn capabilities_reply_fixture_is_secret_free() {
        let value = load_json("capabilities.reply");
        round_trip::<CapabilitiesReply>("capabilities.reply", &value);
        // Readiness is expressed as `has_*` bits only; no credential, path,
        // prompt or raw config may cross the gateway wire.
        assert!(value["hasExpressions"].is_boolean());
        assert!(value["hasMotions"].is_boolean());
        for key in ["authToken", "token", "apiKey", "path", "prompt", "config"] {
            assert!(
                value.get(key).is_none(),
                "capabilities.reply must not carry `{key}`"
            );
        }
    }

    #[test]
    fn vault_status_reply_fixture() {
        let value = load_json("vault_status.reply");
        round_trip::<VaultStatusReply>("vault_status.reply", &value);
    }

    #[test]
    fn gateway_config_reply_fixture() {
        let value = load_json("gateway_config.reply");
        round_trip::<GatewayConfigReply>("gateway_config.reply", &value);
    }

    #[test]
    fn gateway_auth_reply_fixture() {
        let value = load_json("gateway_auth.reply");
        round_trip::<GatewayAuthReply>("gateway_auth.reply", &value);
    }

    #[test]
    fn event_subscribe_reply_fixture() {
        let value = load_json("event_subscribe.reply");
        round_trip::<EventSubscriptionReply>("event_subscribe.reply", &value);
    }

    #[test]
    fn heartbeat_pong_fixture() {
        let value = load_json("heartbeat.pong");
        round_trip::<HeartbeatData>("heartbeat.pong", &value);
    }

    #[test]
    fn heartbeat_ping_fixture() {
        let value = load_json("heartbeat.ping");
        round_trip::<HeartbeatData>("heartbeat.ping", &value);
    }

    #[test]
    fn rpc_error_fixture() {
        let value = load_json("rpc.error.invalid_token");
        round_trip::<RpcErrorObject>("rpc.error.invalid_token", &value);
    }

    #[test]
    fn card_metadata_fixtures() {
        let reply = load_json("cards.metadata.reply");
        round_trip::<CardMetadataReply>("cards.metadata.reply", &reply);
        let set = load_json("cards.metadata.set.request");
        round_trip::<CardMetadataSetRequest>("cards.metadata.set.request", &set);
    }

    #[test]
    fn cards_list_reply_fixture() {
        let reply = load_json("cards.list.reply");
        // The golden is authoritative: a non-empty page must carry a
        // well-formed keyset cursor (gateway.rs list_next_cursor).
        let cursor = reply
            .get("cursor")
            .expect("a non-empty cards.list page must carry a keyset cursor");
        assert!(
            cursor["updatedAt"].is_i64() && cursor["rowId"].is_i64(),
            "keyset cursor shape drifted: {cursor}"
        );
        round_trip::<CardListReply>("cards.list.reply", &reply);
    }

    #[test]
    fn cards_get_reply_fixture() {
        let reply = load_json("cards.get.reply");
        round_trip::<CardGetReply>("cards.get.reply", &reply);
    }

    #[test]
    fn cards_import_request_reply_fixtures() {
        let request = load_json("cards.import.request");
        round_trip::<CardImportRequest>("cards.import.request", &request);
        let reply = load_json("cards.import.reply");
        round_trip::<CardImportReply>("cards.import.reply", &reply);
    }

    #[test]
    fn cards_create_request_reply_fixtures() {
        let request = load_json("cards.create.request");
        round_trip::<CardCreateRequest>("cards.create.request", &request);
        let reply = load_json("cards.create.reply");
        round_trip::<CardCreateReply>("cards.create.reply", &reply);
    }

    #[test]
    fn cards_update_request_reply_fixtures() {
        let request = load_json("cards.update.request");
        round_trip::<CardUpdateRequest>("cards.update.request", &request);
        let reply = load_json("cards.update.reply");
        round_trip::<CardUpdateReply>("cards.update.reply", &reply);
    }

    #[test]
    fn cards_delete_request_reply_fixtures() {
        let request = load_json("cards.delete.request");
        round_trip::<CardDeleteRequest>("cards.delete.request", &request);
        let reply = load_json("cards.delete.reply");
        round_trip::<CardDeleteReply>("cards.delete.reply", &reply);
    }

    #[test]
    fn chat_send_request_fixture_locks_camel_case_session_id() {
        let value = load_json("chat.send.request");
        round_trip::<ChatSendRequest>("chat.send.request", &value);
        assert!(
            value.get("sessionId").is_some(),
            "chat.send.request: camelCase `sessionId` must cross the wire"
        );
        assert!(
            value.get("session_id").is_none(),
            "chat.send.request: snake_case `session_id` is not the wire shape"
        );
    }

    #[test]
    fn chat_send_attachments_request_fixture_locks_descriptor_wire_shape() {
        let value = load_json("chat.send.attachments.request");
        round_trip::<ChatSendRequest>("chat.send.attachments.request", &value);

        // Additive golden: only the three serde-emitted top-level keys, no
        // `genUi` (serde skips the default false), camelCase descriptors.
        let mut top_keys: Vec<&str> = value
            .as_object()
            .expect("request is an object")
            .keys()
            .map(String::as_str)
            .collect();
        top_keys.sort_unstable();
        assert_eq!(top_keys, vec!["attachments", "content", "sessionId"]);
        assert!(value.get("genUi").is_none(), "`genUi` must be skipped");

        let attachments = value["attachments"].as_array().expect("attachments array");
        assert_eq!(attachments.len(), 1);
        let mut descriptor_keys: Vec<&str> = attachments[0]
            .as_object()
            .expect("descriptor is an object")
            .keys()
            .map(String::as_str)
            .collect();
        descriptor_keys.sort_unstable();
        assert_eq!(descriptor_keys, vec!["data", "fileName", "mimeType", "url"]);
        assert_eq!(attachments[0]["mimeType"], "image/png");
        assert_eq!(attachments[0]["data"], "aGVsbG8=");
        assert_eq!(attachments[0]["fileName"], "a.png");
    }

    // Contract: `sessions.delete` is a write: the daemon refuses it until the
    // operator opts in, and an unknown verb must never be reported as a
    // successful delete.
    #[test]
    fn sessions_delete_is_a_registered_write_verb() {
        let source = std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../anima-daemon/src/gateway.rs"),
        )
        .expect("daemon gateway source is present in the workspace");
        assert!(
            source.contains("\"sessions.delete\".to_string()"),
            "sessions.delete must stay registered"
        );
        let start = source
            .find("\"sessions.delete\".to_string()")
            .expect("registration present");
        // The verb is wrapped in `gated(config_path, hostname, …)`, which is the
        // fail-closed `allowActions` check. The window stops at the next verb
        // so a neighbouring `gated` cannot satisfy the assertion.
        let window = &source[start..start + 300];
        assert!(
            window.contains("gated("),
            "sessions.delete must be wrapped in the allowActions gate"
        );
    }

    #[test]
    fn session_delete_fixtures_lock_camel_case_session_id() {
        let request = load_json("sessions.delete.request");
        round_trip::<SessionDeleteRequest>("sessions.delete.request", &request);
        assert!(
            request.get("sessionId").is_some(),
            "sessions.delete.request: camelCase `sessionId` must cross the wire"
        );
        assert!(
            request.get("session_id").is_none(),
            "sessions.delete.request: snake_case `session_id` is not the wire shape"
        );

        let reply = load_json("sessions.delete.reply");
        round_trip::<SessionDeleteReply>("sessions.delete.reply", &reply);
        assert_eq!(reply["deleted"], true);
    }

    #[test]
    fn session_import_reply_fixture() {
        let value = load_json("sessions.import.reply");
        round_trip::<SessionImportReply>("sessions.import.reply", &value);
    }

    // ----------------------------------------------------------------
    // Secret-free negative control shared by the additive provider/asset DTOs.
    // Forbidden keys: authToken, token, apiKey, secret, config, path, prompt.
    // ----------------------------------------------------------------

    fn assert_secret_free(name: &str, value: &serde_json::Value) {
        for key in [
            "authToken",
            "token",
            "apiKey",
            "secret",
            "config",
            "path",
            "prompt",
        ] {
            assert!(value.get(key).is_none(), "{name} must not carry `{key}`");
        }
    }

    #[test]
    fn provider_validation_state_fixture_is_secret_free() {
        let value = load_json("provider.validation.state");
        round_trip::<ProviderValidationState>("provider.validation.state", &value);
        assert_secret_free("provider.validation.state", &value);
        assert!(value["validated"].is_boolean());
        assert!(value["validationBypassed"].is_boolean());
    }

    #[test]
    fn asset_catalog_manifest_fixture_is_secret_free() {
        let value = load_json("asset.catalog.manifest");
        round_trip::<AssetCatalogManifest>("asset.catalog.manifest", &value);
        assert_secret_free("asset.catalog.manifest", &value);
        // A manifest carries entry metadata and caps only — never binary bytes.
        for entry in value["entries"].as_array().expect("entries array") {
            assert!(
                entry.get("data").is_none(),
                "manifest entries carry no bytes"
            );
        }
    }

    #[test]
    fn asset_download_metadata_fixture_is_secret_free() {
        let value = load_json("asset.download.metadata");
        round_trip::<AssetDownloadMetadata>("asset.download.metadata", &value);
        assert_secret_free("asset.download.metadata", &value);
        assert_eq!(
            value["maxDataBytes"].as_u64(),
            Some(1024 * 1024 - 8192),
            "wire data budget must reserve the RPC envelope inside the 1 MiB frame cap"
        );
    }

    // ----------------------------------------------------------------
    // Cross-cutting: every fixture file must be valid JSON
    // ----------------------------------------------------------------

    #[test]
    fn every_golden_fixture_is_valid_json() {
        let dir = fixtures_dir();
        let entries: Vec<_> = std::fs::read_dir(&dir)
            .unwrap_or_else(|e| panic!("cannot read {}: {e}", dir.display()))
            .filter_map(|e| e.ok())
            .filter(|e| e.path().extension().is_some_and(|ext| ext == "json"))
            .collect();
        assert!(!entries.is_empty(), "no golden fixtures found");
        for entry in &entries {
            let path = entry.path();
            let text = std::fs::read_to_string(&path)
                .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
            let value: serde_json::Value = serde_json::from_str(&text)
                .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()));
            assert!(
                value.is_object(),
                "{}: expected JSON object, got {}",
                path.display(),
                value
            );
        }
    }
}
