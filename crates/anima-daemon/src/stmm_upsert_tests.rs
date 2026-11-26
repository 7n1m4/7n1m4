// SPDX-License-Identifier: GPL-3.0-or-later

//! Contract tests for the gated `stmm.upsert` verb.
//!
//! These call `Gateway::renderer_handlers` directly, so the tests fail if the
//! verb is renamed, removed, ungated, or its wire payload changes shape.

#[cfg(test)]
mod tests {
    use std::fs;
    use std::sync::Mutex;

    use anima_channel::dispatch::RendererHandlers;
    use tempfile::tempdir;

    use crate::core::CoreService;
    use crate::gateway::Gateway;

    const STMM_UPSERT_MAX_BLOCKS: usize = 100;
    const STMM_UPSERT_MAX_CONTENT_BYTES: usize = 64 * 1024;
    const STMM_UPSERT_MAX_ID_BYTES: usize = 256;
    const STMM_UPSERT_MAX_SOURCE_SESSION_IDS: usize = 32;

    struct Fixture {
        gateway: Gateway,
        core: CoreService,
        config_path: std::path::PathBuf,
        _tmp: tempfile::TempDir,
        _env_guard: std::sync::MutexGuard<'static, ()>,
    }

    /// `AIRI_SERVER_CHANNEL_CONFIG` is process-global; serialize fixtures that
    /// set it so parallel tests cannot steal each other's config path.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn isolated_gateway() -> Fixture {
        let guard = ENV_LOCK.lock().unwrap_or_else(|e| e.into_inner());
        let tmp = tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        fs::create_dir_all(&dir).unwrap();
        let config_path = dir.join("config.json");
        let mut config = anima_channel::ChannelConfig::healed();
        config.allow_actions = None;
        fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).unwrap();

        std::env::set_var("AIRI_SERVER_CHANNEL_CONFIG", &config_path);
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

    // Contract: `stmm.upsert` persists daily summary blocks through the
    // daemon-owned store and reports how many landed.
    #[test]
    fn stmm_upsert_inserts_blocks_and_reports_count() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        let upsert = handlers.get("stmm.upsert").unwrap();

        let reply = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [
                    {
                        "id": "sum-1",
                        "day": "2026-11-10",
                        "content": "discussed Miso",
                        "sourceSessionIds": ["s1"],
                        "tokenEstimate": 4,
                        "createdAt": 10
                    },
                    { "id": "sum-2", "day": "2026-11-10", "content": "second block" }
                ]
            }),
        )
        .unwrap();
        assert_eq!(reply["upserted"], 2);

        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        let summaries = listed["summaries"].as_array().unwrap();
        assert_eq!(summaries.len(), 2);
        let first = summaries
            .iter()
            .find(|s| s["id"] == "sum-1")
            .expect("sum-1 stored");
        assert_eq!(first["day"], "2026-11-10");
        assert_eq!(first["content"], "discussed Miso");
        assert_eq!(first["token_estimate"], 4);
        assert_eq!(first["created_at"], 10);
        assert_eq!(first["source_session_ids"], serde_json::json!(["s1"]));
    }

    // Contract: malformed blocks are a typed boundary failure, never a
    // partial write, and oversized payloads are refused.
    #[test]
    fn stmm_upsert_rejects_invalid_blocks() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        let upsert = handlers.get("stmm.upsert").unwrap();

        let many_blocks: Vec<serde_json::Value> = (0..STMM_UPSERT_MAX_BLOCKS + 1)
            .map(|i| {
                serde_json::json!({
                    "id": format!("s{i}"),
                    "day": "2026-11-10",
                    "content": "x"
                })
            })
            .collect();
        let cases: Vec<serde_json::Value> = vec![
            serde_json::json!({ "blocks": [{ "day": "2026-11-10", "content": "x" }] }),
            serde_json::json!({ "blocks": [{ "id": "  ", "day": "2026-11-10", "content": "x" }] }),
            serde_json::json!({ "blocks": [{ "id": "s", "day": "2026-11", "content": "x" }] }),
            serde_json::json!({ "blocks": [{ "id": "s", "day": "2026-11-10" }] }),
            serde_json::json!({ "blocks": [{ "id": "s", "day": "2026-11-10", "content": "   " }] }),
            serde_json::json!({ "blocks": [{ "id": "s", "day": "2026-11-10", "content": "x".repeat(STMM_UPSERT_MAX_CONTENT_BYTES + 1) }] }),
            serde_json::json!({ "blocks": [{ "id": "x".repeat(STMM_UPSERT_MAX_ID_BYTES + 1), "day": "2026-11-10", "content": "x" }] }),
            serde_json::json!({}),
            serde_json::json!({ "blocks": [] }),
            serde_json::json!({ "blocks": many_blocks }),
        ];
        for case in cases {
            assert!(
                upsert("stmm.upsert", &case).is_err(),
                "expected error, got ok for {case}"
            );
        }

        // Nothing was written by any rejected request.
        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        assert!(listed["summaries"].as_array().unwrap().is_empty());
    }

    // ROOT CAUSE:
    //
    // The old handler wrote each parsed block immediately, so a valid first
    // block followed by an invalid second block left the first committed.
    // Validate the whole batch first, then commit it in one transaction.
    #[test]
    fn stmm_upsert_late_invalid_block_writes_nothing() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        let upsert = handlers.get("stmm.upsert").unwrap();

        let err = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [
                    { "id": "valid-first", "day": "2026-11-10", "content": "should not land" },
                    { "id": "invalid-second", "day": "2026-11", "content": "bad day" },
                ]
            }),
        )
        .expect_err("late invalid block must reject the whole batch");
        assert!(err.contains("block 1"), "error must name the bad block: {err}");
        assert!(!err.contains("2026-11"), "error must not echo payload content: {err}");
        assert!(!err.contains("should not land"), "error must not echo payload content: {err}");

        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        assert!(
            listed["summaries"].as_array().unwrap().is_empty(),
            "a rejected batch must not leave earlier rows committed"
        );
    }

    #[test]
    fn stmm_delete_removes_a_block_durably() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        handlers.get("stmm.upsert").unwrap()(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [
                    { "id": "gone", "day": "2026-11-10", "content": "delete me" },
                    { "id": "kept", "day": "2026-11-10", "content": "keep me" },
                ]
            }),
        )
        .unwrap();

        let deleted = handlers.get("stmm.delete").unwrap()(
            "stmm.delete",
            &serde_json::json!({ "id": "gone" }),
        )
        .unwrap();
        assert_eq!(deleted["deleted"], true);
        assert_eq!(
            handlers.get("stmm.delete").unwrap()(
                "stmm.delete",
                &serde_json::json!({ "id": "gone" }),
            )
            .unwrap()["deleted"],
            false,
            "delete must be idempotent"
        );
        assert!(handlers.get("stmm.delete").unwrap()(
            "stmm.delete",
            &serde_json::json!({ "id": "  " }),
        ).is_err());

        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        let ids: Vec<_> = listed["summaries"].as_array().unwrap()
            .iter().map(|row| row["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["kept"]);
        // A prune-only rebuild must not resurrect the deleted row.
        handlers.get("stmm.rebuild").unwrap()("stmm.rebuild", &serde_json::json!({})).unwrap();
        let after = handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({})).unwrap();
        let ids: Vec<_> = after["summaries"].as_array().unwrap()
            .iter().map(|row| row["id"].as_str().unwrap()).collect();
        assert_eq!(ids, vec!["kept"]);
    }

    #[test]
    fn stmm_delete_is_action_gated() {
        let fixture = isolated_gateway();
        let handlers = verbs(&fixture);
        let err = handlers.get("stmm.delete").unwrap()(
            "stmm.delete",
            &serde_json::json!({ "id": "x" }),
        )
        .expect_err("delete must be gated");
        assert!(err.starts_with(crate::gateway::ACTIONS_DISABLED_PREFIX), "{err}");
    }

    // Contract: numeric fields are clamped, never trusted, and the source
    // session id list is bounded.
    #[test]
    fn stmm_upsert_clamps_numeric_fields() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        let upsert = handlers.get("stmm.upsert").unwrap();

        let many: Vec<String> = (0..STMM_UPSERT_MAX_SOURCE_SESSION_IDS + 5)
            .map(|i| format!("s{i}"))
            .collect();
        let reply = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [
                    {
                        "id": "clamp-1",
                        "day": "2026-11-10",
                        "content": "big",
                        "tokenEstimate": u64::MAX,
                        "createdAt": u64::MAX,
                        "sourceSessionIds": many,
                    },
                    {
                        "id": "clamp-2",
                        "day": "2026-11-10",
                        "content": "negative",
                        "tokenEstimate": -5,
                        "createdAt": "not-a-number",
                    }
                ]
            }),
        )
        .unwrap();
        assert_eq!(reply["upserted"], 2);

        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        let summaries = listed["summaries"].as_array().unwrap();
        let one = summaries
            .iter()
            .find(|s| s["id"] == "clamp-1")
            .expect("clamp-1 stored");
        assert_eq!(one["token_estimate"], i64::MAX);
        assert_eq!(one["created_at"], i64::MAX);
        assert_eq!(
            one["source_session_ids"].as_array().unwrap().len(),
            STMM_UPSERT_MAX_SOURCE_SESSION_IDS
        );
        let two = summaries
            .iter()
            .find(|s| s["id"] == "clamp-2")
            .expect("clamp-2 stored");
        assert_eq!(two["token_estimate"], 0);
        assert_eq!(two["created_at"], 0);
    }

    // Contract: `stmm.upsert` is a write, so it stays denied until the
    // operator opts in with `allowActions`.
    #[test]
    fn stmm_upsert_is_denied_without_actions_opt_in() {
        let fixture = isolated_gateway();
        let handlers = verbs(&fixture);
        let upsert = handlers
            .get("stmm.upsert")
            .expect("stmm.upsert must stay registered");
        let err = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [{ "id": "s", "day": "2026-11-10", "content": "x" }]
            }),
        )
        .expect_err("upsert must be denied by default");
        assert!(
            err.starts_with(crate::gateway::ACTIONS_DISABLED_PREFIX),
            "{err}"
        );
    }

    // Contract: re-sending a block with the same id replaces the stored row
    // (idempotent upsert), never a duplicate or a primary-key error.
    #[test]
    fn stmm_upsert_same_id_replaces_row() {
        let fixture = isolated_gateway();
        enable_actions(&fixture);
        let handlers = verbs(&fixture);
        let upsert = handlers.get("stmm.upsert").unwrap();

        let first = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [{
                    "id": "sum-1",
                    "day": "2026-11-10",
                    "content": "first",
                    "sourceSessionIds": ["s1"],
                    "tokenEstimate": 4,
                    "createdAt": 10
                }]
            }),
        )
        .unwrap();
        assert_eq!(first["upserted"], 1);

        // Same id, new body: must succeed and replace, not conflict.
        let second = upsert(
            "stmm.upsert",
            &serde_json::json!({
                "blocks": [{
                    "id": "sum-1",
                    "day": "2026-11-10",
                    "content": "second",
                    "tokenEstimate": 9,
                    "createdAt": 20
                }]
            }),
        )
        .unwrap();
        assert_eq!(second["upserted"], 1);

        let listed =
            handlers.get("stmm.list").unwrap()("stmm.list", &serde_json::json!({ "limit": 10 }))
                .unwrap();
        let summaries = listed["summaries"].as_array().unwrap();
        assert_eq!(summaries.len(), 1, "same id must not duplicate");
        assert_eq!(summaries[0]["content"], "second");
        assert_eq!(summaries[0]["token_estimate"], 9);
        assert_eq!(summaries[0]["created_at"], 20);
    }
}
