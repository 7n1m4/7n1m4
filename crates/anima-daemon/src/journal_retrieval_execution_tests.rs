// SPDX-License-Identifier: GPL-3.0-or-later
//! Round v31 real-execution proof of `retrieval.status`, `journal.append` and
//! `journal.search` against the additive channel golden
//! `trace.journal.retrieval.json`.
//!
//! Declared only by `main.rs` (bin test target), so `crate::gateway` and
//! `crate::events` resolve here. The v27/v29/v30 DIRECT pattern is used: an
//! explicit tempdir `ChannelConfig` with `allowActions: true` feeds
//! `Gateway::renderer_handlers` with a real `CoreService` + `EventPublisher`.
//! No process-global `AIRI_SERVER_CHANNEL_CONFIG` is read.
//!
//! Two cores are required. The healthy core seeds via the real gated
//! `journal.append` and reads back through the real `journal.search`; the
//! unavailable core (a directory at `airi.sqlite`) proves `retrieval.status`
//! can answer `{"available": false}` without fabricating journal rows.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::core::CoreService;
use crate::events::EventPublisher;
use crate::gateway::Gateway;
use crate::gateway::ACTIONS_DISABLED_PREFIX;

fn keys(value: &Value) -> BTreeSet<&str> {
    value
        .as_object()
        .expect("JSON object")
        .keys()
        .map(String::as_str)
        .collect()
}

fn collect_keys(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                out.insert(key.clone());
                collect_keys(child, out);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect_keys(child, out);
            }
        }
        _ => {}
    }
}

/// Read a golden fixture verbatim. No fixture field is restated in this test.
fn load_golden(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden")
        .join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

#[tokio::test]
async fn journal_retrieval_golden_replays_through_real_handlers() {
    let golden = load_golden("trace.journal.retrieval.json");
    assert_eq!(golden["schema"], "airi-channel-trace-v1");
    let frames = golden["frames"].as_array().expect("frames array");
    assert_eq!(frames.len(), 8, "trace frame count drift");

    // Fixture casing oracles: request payloads are camelCase, stored reply
    // timestamps are snake_case. Lock both so a Flutter/Dart DTO cannot quietly
    // drop a field to null.
    let append_payload = &frames[2]["payload"];
    assert_eq!(
        keys(append_payload),
        ["content", "kind"].into_iter().collect::<BTreeSet<_>>()
    );
    let search_payload = &frames[4]["payload"];
    assert_eq!(
        keys(search_payload),
        ["query", "limit"].into_iter().collect::<BTreeSet<_>>()
    );
    let golden_search = &frames[5]["data"];
    assert_eq!(
        keys(golden_search),
        ["entries", "truncated"]
            .into_iter()
            .collect::<BTreeSet<_>>()
    );
    let golden_entry = &golden_search["entries"][0];
    assert_eq!(
        keys(golden_entry),
        ["content", "created_at", "id", "kind", "updated_at"]
            .into_iter()
            .collect::<BTreeSet<_>>()
    );
    assert!(golden_entry.get("embedding").is_none());
    assert_eq!(golden_search["truncated"], false);
    assert_eq!(frames[1]["data"], json!({ "available": true }));
    assert_eq!(frames[7]["data"], json!({ "available": false }));

    // --- subcase (a): healthy core, real gated append + real search ---
    let tmp = tempfile::tempdir().expect("journal tempdir");
    let config_dir = tmp.path().join("server-channel");
    fs::create_dir_all(&config_dir).expect("config dir");
    let config_path = config_dir.join("config.json");
    let mut config = anima_channel::ChannelConfig::healed();
    config.allow_actions = Some(true);
    fs::write(&config_path, serde_json::to_string_pretty(&config).unwrap()).expect("config.json");

    let core = CoreService::open(Some(tmp.path().to_path_buf()));
    assert!(core.available(), "isolated core must be available");
    let publisher = EventPublisher::new(anima_channel::EventBus::with_defaults());
    let handlers = Gateway::renderer_handlers(&core, &publisher, &config_path, "127.0.0.1");

    let status_true = handlers
        .get("retrieval.status")
        .expect("retrieval.status registered")("retrieval.status", &json!({}))
    .expect("retrieval.status must ack");
    assert_eq!(&status_true, &frames[1]["data"]);

    // Gate denial first, with the same live core but a config that lacks the
    // opt-in: a mutating verb must be refused before any row is seeded.
    let denied_dir = tmp.path().join("no-actions");
    fs::create_dir_all(&denied_dir).expect("denied config dir");
    let denied_path = denied_dir.join("config.json");
    fs::write(&denied_path, json!({ "allowActions": false }).to_string()).expect("denied config");
    let denied_handlers = Gateway::renderer_handlers(&core, &publisher, &denied_path, "127.0.0.1");
    let denied = denied_handlers
        .get("journal.append")
        .expect("journal.append registered")("journal.append", append_payload)
    .expect_err("mutating verb must be denied without allowActions");
    assert!(
        denied.starts_with(ACTIONS_DISABLED_PREFIX),
        "gate denial: {denied}"
    );

    // The allowed handler rejects empty content before touching the store.
    let empty = handlers
        .get("journal.append")
        .expect("journal.append registered")(
        "journal.append",
        &json!({ "content": "   ", "kind": "note" }),
    )
    .expect_err("whitespace-only content must be rejected");
    assert!(empty.contains("empty content"), "empty rejection: {empty}");

    // Seed through the real gated handler using the golden request payload
    // verbatim: no client-side normalization of content or kind.
    let appended = handlers
        .get("journal.append")
        .expect("journal.append registered")("journal.append", append_payload)
    .expect("real journal.append must ack");
    let minted_id = appended["id"]
        .as_str()
        .expect("append reply carries a string id");
    assert!(!minted_id.is_empty());

    // Sacred Journal Rule: verify the real SQLite row before projecting the
    // reply onto any fixture sentinel. Append-only: the daemon-minted id is
    // not overwritten and the content/kind are stored verbatim.
    let repo = anima_store::JournalRepo::new(core.db().expect("core db"));
    let rows = repo.list_recent(10).expect("real journal query");
    assert_eq!(rows.len(), 1, "exactly one seeded row");
    let row = &rows[0];
    assert_eq!(row.id, minted_id, "append must not overwrite the id");
    assert_eq!(row.kind, append_payload["kind"].as_str().expect("kind"));
    assert_eq!(
        row.content,
        append_payload["content"].as_str().expect("content"),
        "content stored verbatim, no client normalization"
    );
    assert_eq!(row.created_at, row.updated_at);
    assert!(row.created_at > 0);
    assert!(row.embedding.is_none(), "append path stores no embedding");

    let reply: Value =
        handlers
            .get("journal.search")
            .expect("journal.search registered")("journal.search", search_payload)
        .expect("real journal.search must ack");

    // Pre-projection invariants on the RAW reply.
    assert_eq!(keys(&reply), keys(golden_search));
    assert_eq!(reply["truncated"], golden_search["truncated"]);
    let entries = reply["entries"].as_array().expect("entries array");
    let golden_entries = golden_search["entries"].as_array().expect("golden entries");
    assert_eq!(entries.len(), golden_entries.len());
    assert_eq!(entries[0]["content"], golden_entries[0]["content"]);
    assert_eq!(entries[0]["kind"], golden_entries[0]["kind"]);
    assert_eq!(keys(&entries[0]), keys(&golden_entries[0]));
    assert!(
        entries[0].get("embedding").is_none(),
        "no embedding on wire"
    );
    assert!(!entries[0]["id"].as_str().unwrap_or("").is_empty());
    assert!(entries[0]["created_at"].as_i64().unwrap_or(0) > 0);
    assert!(entries[0]["updated_at"].as_i64().unwrap_or(0) > 0);
    // Deterministic ordering: the same query returns the same ordered page.
    let again: Value =
        handlers
            .get("journal.search")
            .expect("journal.search registered")("journal.search", search_payload)
        .expect("real journal.search must ack");
    assert_eq!(again, reply, "search ordering must be deterministic");
    // No secret-bearing or path-bearing key/value anywhere in the reply.
    let mut reply_keys = BTreeSet::new();
    collect_keys(&reply, &mut reply_keys);
    for forbidden in [
        "embedding",
        "apiKey",
        "api_key",
        "secret",
        "token",
        "authToken",
        "config",
        "password",
        "credential",
        "authorization",
        "keys",
        "ciphertext",
        "path",
        "file",
        "dir",
        "vector",
    ] {
        assert!(
            !reply_keys
                .iter()
                .any(|key| key.eq_ignore_ascii_case(forbidden)),
            "journal.search must never carry `{forbidden}`"
        );
    }
    let rendered = reply.to_string();
    let tmp_display = tmp.path().to_string_lossy();
    assert!(
        !rendered.contains(tmp_display.as_ref()),
        "journal.search leaked a host path"
    );

    // GREEN: only the three daemon-minted leaves (id + both timestamps) are
    // projected onto the fixture sentinels. The availability flag, exact
    // camelCase/snake_case key sets, verbatim content/kind, truncation flag,
    // ordering and secret-free shape were all asserted on the RAW reply above
    // and are never normalized. Cross-universe seeding is not exposed by any
    // verb here, so it stays out of scope instead of being fabricated.
    let mut projected = reply.clone();
    for field in ["id", "created_at", "updated_at"] {
        let minted = entries[0][field].clone();
        let sentinel = golden_entry[field].clone();
        assert_ne!(
            minted, sentinel,
            "{field} must be process-minted, never copied from the fixture"
        );
        projected["entries"][0][field] = sentinel;
    }
    assert_eq!(
        &projected, golden_search,
        "real reply equals the unchanged golden after projecting process-minted leaves"
    );

    // --- subcase (b): unavailable core, honest status:false ---
    let tmp_unavailable = tempfile::tempdir().expect("unavailable tempdir");
    fs::create_dir_all(tmp_unavailable.path().join("airi.sqlite"))
        .expect("directory at db path forces open failure");
    let unavailable_core = CoreService::open(Some(tmp_unavailable.path().to_path_buf()));
    assert!(
        !unavailable_core.available(),
        "a directory at airi.sqlite must make the core unavailable"
    );
    let unavailable_handlers =
        Gateway::renderer_handlers(&unavailable_core, &publisher, &config_path, "127.0.0.1");
    let status_false =
        unavailable_handlers
            .get("retrieval.status")
            .expect("retrieval.status registered")("retrieval.status", &json!({}))
        .expect("retrieval.status must ack even when unavailable");
    assert_eq!(&status_false, &frames[7]["data"]);
    assert_ne!(&status_false, &status_true, "status must be non-vacuous");
    // No fabricated empty journal from a dead core.
    let search_err = unavailable_handlers
        .get("journal.search")
        .expect("journal.search registered")("journal.search", search_payload)
    .expect_err("search must fail when the store is unavailable");
    assert!(
        search_err.contains("core unavailable"),
        "search error: {search_err}"
    );
}
