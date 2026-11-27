// SPDX-License-Identifier: GPL-3.0-or-later
//! Round v30 real-execution proof of `vault.status` against the unchanged
//! channel golden `vault_status.reply.json`.
//!
//! This module is declared only by `main.rs` (bin test target), so `crate::events`
//! and `crate::gateway` resolve here; the same imports fail in the `anima_daemon`
//! lib test target, which compiles `provider_validation.rs` as well.
//!
//! The v27/v29 DIRECT pattern is used: an explicit tempdir `ChannelConfig` with
//! `allowActions: true` feeds `Gateway::renderer_handlers` with a real
//! `CoreService` + `EventPublisher`. No process-global
//! `AIRI_SERVER_CHANNEL_CONFIG` is involved, so this module cannot steal
//! another module's config path under parallel execution.
//!
//! Every write is seeded through the real gated handlers and checked against
//! the real SQLite store BEFORE the reply is projected onto fixture sentinels.
//! All vault counters/byte sizes are process-minted u32 metrics: they vary with
//! the seeded state and the host, so only those numeric leaves are projected;
//! the availability flag, camelCase key-set and secret-free shape are asserted
//! on the raw reply and never normalized.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;
use std::time::Duration;

use serde_json::{json, Value};

use crate::core::CoreService;
use crate::events::EventPublisher;
use crate::gateway::Gateway;

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

/// Read a golden fixture verbatim. Never edit or restate it in this test.
fn load_golden(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden")
        .join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

#[tokio::test]
async fn vault_status_golden_execution_replays_through_real_handler() {
    // The golden is read verbatim; no fixture field is restated here.
    let golden = load_golden("vault_status.reply.json");

    // Exact camelCase key-set oracle: availability plus four archive domains
    // and their nested count/bytes/sessions/messages/summaries/journalEntries
    // fields only. This guards against a fixture silently gaining a key.
    assert_eq!(
        keys(&golden),
        ["available", "stats"].into_iter().collect::<BTreeSet<_>>()
    );
    let golden_stats = &golden["stats"];
    assert_eq!(
        keys(golden_stats),
        ["characters", "chats", "memory", "providers"]
            .into_iter()
            .collect::<BTreeSet<_>>()
    );
    for (domain, expected) in [
        ("characters", vec!["bytes", "count"]),
        ("chats", vec!["bytes", "messages", "sessions"]),
        ("memory", vec!["bytes", "journalEntries", "summaries"]),
        ("providers", vec!["bytes", "count"]),
    ] {
        assert_eq!(
            keys(&golden_stats[domain]),
            expected.into_iter().collect::<BTreeSet<_>>(),
            "fixture key drift in {domain}"
        );
    }

    // Explicit tempdir config with allowActions: true and a real core; no
    // process-global AIRI_SERVER_CHANNEL_CONFIG is read anywhere on this path.
    let tmp = tempfile::tempdir().expect("vault tempdir");
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

    // Seed real state through the gated handlers: characters -> chats ->
    // memory in the same vault the status handler will project.
    let card = handlers
        .get("cards.create")
        .expect("cards.create registered")(
        "cards.create",
        &json!({
            "name": "Vault Golden Card",
            "document": {
                "spec": "chara_card_v2",
                "data": { "name": "Vault Golden Card" }
            }
        }),
    )
    .expect("real cards.create must ack");
    assert!(!card["id"].as_str().unwrap_or("").is_empty());

    let journal = handlers
        .get("journal.append")
        .expect("journal.append registered")(
        "journal.append",
        &json!({ "content": "round v30 vault golden seed", "kind": "note" }),
    )
    .expect("real journal.append must ack");
    assert!(!journal["id"].as_str().unwrap_or("").is_empty());

    let session_id = "sess-v30-vault-golden";
    let sent = handlers.get("chat.send").expect("chat.send registered")(
        "chat.send",
        &json!({ "sessionId": session_id, "content": "round v30 vault golden seed" }),
    )
    .expect("real chat.send must ack");
    assert_eq!(sent["accepted"], true);

    // chat.send persists the user turn on its background task. Poll the real
    // store rather than guessing a fixed sleep.
    let db = core.db().expect("core db");
    let messages = anima_store::MessageRepo::new(db.clone());
    let sessions = anima_store::SessionRepo::new(db.clone());
    let mut stored_messages = 0usize;
    for _ in 0..200 {
        stored_messages = messages.list(session_id).expect("message query").len();
        if stored_messages > 0 {
            break;
        }
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert!(
        stored_messages > 0,
        "chat.send must persist a real user turn"
    );
    assert!(sessions.get(session_id).expect("session query").is_some());

    let listed =
        handlers.get("cards.list").expect("cards.list registered")("cards.list", &json!({}))
            .expect("real cards.list must ack");
    assert_eq!(listed["cards"].as_array().expect("cards array").len(), 1);

    let reply: Value = handlers
        .get("vault.status")
        .expect("vault.status registered")("vault.status", &json!({}))
    .expect("real vault.status must ack");

    assert_eq!(reply["available"], true);
    assert_eq!(keys(&reply), keys(&golden));
    let stats = &reply["stats"];
    assert_eq!(keys(stats), keys(golden_stats));
    for domain in ["characters", "chats", "memory", "providers"] {
        assert_eq!(keys(&stats[domain]), keys(&golden_stats[domain]));
    }

    // No secret-bearing key anywhere in the recursively flattened reply.
    let mut reply_keys = BTreeSet::new();
    collect_keys(&reply, &mut reply_keys);
    for forbidden in [
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
    ] {
        assert!(
            !reply_keys
                .iter()
                .any(|key| key.eq_ignore_ascii_case(forbidden)),
            "vault.status must never carry `{forbidden}`"
        );
    }

    // Real seeded counters are strictly positive before any projection.
    assert!(
        stats["chats"]["sessions"].as_u64().unwrap_or(0) > 0,
        "chat.send must mint a real session count"
    );
    assert!(
        stats["memory"]["summaries"].as_u64().unwrap_or(0) > 0,
        "journal.append must mint a real memory count"
    );
    assert!(stored_messages > 0);

    // Invariant: every leaf under `stats` is a process-minted u32 metric from
    // `anima_core::vault::stats` (counts/byte sizes derived from the live SQLite
    // store and the caller's card dirs — empty here). They are the ONLY values
    // that vary with seeded state and host; availability, the exact camelCase
    // key-set and the secret-free shape were asserted on the RAW reply above
    // and are never normalized. Project only those numeric leaves onto the
    // golden sentinels, then require full equality.
    let mut projected = reply.clone();
    for (domain, fields) in [
        ("characters", vec!["bytes", "count"]),
        ("chats", vec!["bytes", "messages", "sessions"]),
        ("memory", vec!["bytes", "journalEntries", "summaries"]),
        ("providers", vec!["bytes", "count"]),
    ] {
        for field in fields {
            let sentinel = golden_stats[domain][field]
                .as_u64()
                .unwrap_or_else(|| panic!("{domain}.{field} golden sentinel is not a number"));
            let minted = reply["stats"][domain][field]
                .as_u64()
                .unwrap_or_else(|| panic!("{domain}.{field} real reply is not a number"));
            assert!(
                sentinel > 0,
                "{domain}.{field} golden sentinel must be positive"
            );
            assert!(minted <= u32::MAX as u64, "wire type is u32");
            projected["stats"][domain][field] = json!(sentinel);
        }
    }
    assert_eq!(
        projected, golden,
        "real reply equals the unchanged golden after projecting process-minted metrics"
    );
}
