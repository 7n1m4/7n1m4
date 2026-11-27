// SPDX-License-Identifier: GPL-3.0-or-later
//! Round v29 real-execution proof of the sessions verbs against the unchanged
//! channel golden fixtures `sessions.import.reply.json` and
//! `sessions.delete.reply.json`.
//!
//! The v27 DIRECT pattern is used throughout: an explicit tempdir
//! `ChannelConfig` with `allowActions: true` feeds `Gateway::renderer_handlers`
//! with a real `CoreService` + `EventPublisher`. No process-global
//! `AIRI_SERVER_CHANNEL_CONFIG` and no `ENV_LOCK` static are involved, so this
//! module cannot steal another module's config path under parallel execution.
//!
//! Every write is checked against the real SQLite store BEFORE any reply is
//! projected onto a fixture sentinel. The golden revision
//! `1700000000123` is a process-minted ms timestamp; only that one field is
//! projected (after its own `> 0` invariant is asserted). No other fixture
//! field is normalized or synthesized.

use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::core::CoreService;
use crate::events::EventPublisher;
use crate::gateway::Gateway;

/// Read a golden fixture verbatim. Never edit or restate it in this test.
fn load_golden(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden")
        .join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

/// A fresh daemon with writes explicitly opted in, built from a caller-owned
/// tempdir. Returns the live core (for store assertions) and the real renderer
/// handler map (for wire-level execution).
fn isolated_daemon(tmp: &tempfile::TempDir) -> (CoreService, anima_channel::RendererHandlers) {
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
    (core, handlers)
}

#[test]
fn sessions_golden_execution_drives_real_handlers_and_store() {
    let golden_import = load_golden("sessions.import.reply.json");
    let golden_delete = load_golden("sessions.delete.reply.json");
    let golden_delete_request = load_golden("sessions.delete.request.json");
    assert_eq!(golden_import["status"], "applied", "fixture status oracle");
    assert_eq!(
        golden_delete,
        json!({ "deleted": true }),
        "fixture delete oracle"
    );
    let golden_revision = golden_import["revision"]
        .as_i64()
        .expect("fixture revision is an i64 sentinel");
    assert!(golden_revision > 0);

    // --- Phase 1: source daemon, seeded through the real store ---------------
    let source_tmp = tempfile::tempdir().expect("source tempdir");
    let (source_core, source_handlers) = isolated_daemon(&source_tmp);
    let session_id = "sess-v29-real";
    source_core
        .ensure_chat_session(session_id)
        .expect("seed source session");
    let source_db = source_core.db().expect("source db");
    let source_messages = anima_store::MessageRepo::new(source_db.clone());
    for (id, role, content) in [
        ("sess-v29-m1", "user", "round v29"),
        ("sess-v29-m2", "assistant", "real reply"),
    ] {
        source_messages
            .insert(&anima_store::StoredMessage {
                id: id.to_string(),
                session_id: session_id.to_string(),
                role: role.to_string(),
                content: content.to_string(),
                created_at: 1,
                metadata: json!({}),
            })
            .expect("seed source message");
    }

    let export = source_handlers
        .get("sessions.export")
        .expect("sessions.export registered")(
        "sessions.export",
        &json!({ "session_id": session_id }),
    )
    .expect("real sessions.export must ack");
    let jsonl = export["jsonl"]
        .as_str()
        .expect("export carries a JSONL string");
    assert_eq!(export.as_object().expect("export object").len(), 1);

    // The export handler reads snake_case `session_id` only; camelCase is not
    // a silent fallback (unlike fork/activate/delete).
    assert!(
        source_handlers.get("sessions.export").unwrap()(
            "sessions.export",
            &json!({ "sessionId": session_id })
        )
        .is_err(),
        "sessions.export must read session_id (snake) only"
    );

    let header: Value = serde_json::from_str(jsonl.lines().next().expect("session header"))
        .expect("session header is JSON");
    assert_eq!(header["type"], "session");
    assert_eq!(header["session"]["id"], session_id);
    let real_revision = header["session"]["updated_at"]
        .as_i64()
        .expect("real updated_at");
    assert!(real_revision > 0, "store must mint a real ms revision");
    assert_eq!(
        jsonl.lines().filter(|line| !line.trim().is_empty()).count(),
        3,
        "one session header plus two message lines"
    );

    // --- Phase 2: import into a FRESH daemon --------------------------------
    let fresh_tmp = tempfile::tempdir().expect("fresh tempdir");
    let (fresh_core, fresh_handlers) = isolated_daemon(&fresh_tmp);
    let fresh_db = fresh_core.db().expect("fresh db");
    let fresh_sessions = anima_store::SessionRepo::new(fresh_db.clone());
    let fresh_messages = anima_store::MessageRepo::new(fresh_db.clone());
    assert!(
        fresh_sessions
            .get(session_id)
            .expect("fresh session query")
            .is_none(),
        "the import target must start empty"
    );

    let imported = fresh_handlers
        .get("sessions.import")
        .expect("sessions.import registered")(
        "sessions.import", &json!({ "jsonl": jsonl })
    )
    .expect("real sessions.import must ack");

    // REAL store state, asserted BEFORE projecting the reply onto the fixture.
    let stored = fresh_sessions
        .get(session_id)
        .expect("post-import session query")
        .expect("import must persist the session");
    assert_eq!(stored.title, session_id);
    assert_eq!(stored.updated_at, real_revision);
    assert_eq!(
        fresh_messages
            .list(session_id)
            .expect("post-import messages")
            .len(),
        2
    );

    let reply_revision = imported["revision"].as_i64().expect("real reply revision");
    assert!(
        reply_revision > 0,
        "import must report a process-minted revision"
    );
    assert_eq!(
        reply_revision, stored.updated_at,
        "reply revision is the stored row"
    );
    assert_eq!(
        imported["status"], golden_import["status"],
        "real status must be applied before projection"
    );
    assert_eq!(
        imported.as_object().expect("import reply object").len(),
        golden_import
            .as_object()
            .expect("golden import object")
            .len(),
        "no extra or missing fields may be normalized away"
    );
    // Project ONLY the process-minted revision onto the golden sentinel.
    let mut projected_import = imported.clone();
    projected_import["revision"] = json!(golden_revision);
    assert_eq!(
        projected_import, golden_import,
        "the real import reply equals the unchanged golden after projecting revision"
    );

    // --- Phase 3: fork -> activate -> list through the REAL handlers --------
    let forked = fresh_handlers
        .get("sessions.fork")
        .expect("sessions.fork registered")(
        "sessions.fork",
        &json!({ "session_id": session_id, "at_index": 1 }),
    )
    .expect("real sessions.fork must ack");
    let fork_id = forked["session_id"]
        .as_str()
        .expect("fork must mint a session id")
        .to_string();
    assert!(!fork_id.is_empty());
    assert_ne!(fork_id, session_id);
    assert_eq!(
        forked.as_object().unwrap().len(),
        1,
        "fork reply is id-only"
    );
    let fork_row = fresh_sessions
        .get(&fork_id)
        .expect("fork row query")
        .expect("fork stored");
    assert_eq!(
        fork_row.title, stored.title,
        "fork inherits the source title"
    );
    assert_eq!(fork_row.metadata, stored.metadata);
    let fork_messages = fresh_messages.list(&fork_id).expect("fork messages");
    assert_eq!(
        fork_messages.len(),
        1,
        "only the requested prefix is copied"
    );
    assert_eq!(fork_messages[0].content, "round v29");

    let activated = fresh_handlers
        .get("sessions.activate")
        .expect("sessions.activate registered")(
        "sessions.activate",
        &json!({ "session_id": &fork_id }),
    )
    .expect("real sessions.activate must ack");
    assert_eq!(activated, json!({ "ok": true, "session_id": &fork_id }));
    let chat_settings: Value = anima_store::SettingsRepo::new(fresh_db.clone())
        .get("settings/chat")
        .expect("settings query")
        .expect("activate persists a settings blob");
    assert_eq!(
        chat_settings["activeSessionId"],
        json!(&fork_id),
        "activate must persist the choice in the real store"
    );

    let listed =
        fresh_handlers
            .get("sessions.list")
            .expect("sessions.list registered")("sessions.list", &json!({ "limit": 50 }))
        .expect("real sessions.list must ack");
    let listed_ids: Vec<&str> = listed["sessions"]
        .as_array()
        .expect("sessions array")
        .iter()
        .map(|row| row["id"].as_str().expect("session id"))
        .collect();
    assert!(
        listed_ids.contains(&session_id),
        "imported session is listed"
    );
    assert!(
        listed_ids.contains(&fork_id.as_str()),
        "forked session is listed"
    );
    if let Some(cursor) = listed.get("cursor") {
        assert!(
            cursor["updatedAt"].is_i64() && cursor["rowId"].is_i64(),
            "keyset cursor shape drifted: {cursor}"
        );
    }

    // --- Phase 4: delete equals the golden reply exactly --------------------
    let mut delete_request = golden_delete_request.clone();
    delete_request["sessionId"] = json!(&fork_id);
    let deleted = fresh_handlers
        .get("sessions.delete")
        .expect("sessions.delete registered")("sessions.delete", &delete_request)
    .expect("real sessions.delete must ack");
    assert_eq!(
        deleted, golden_delete,
        "delete reply must equal the unchanged golden with zero projection"
    );
    assert!(fresh_sessions
        .get(&fork_id)
        .expect("post-delete query")
        .is_none());
    assert!(fresh_messages
        .list(&fork_id)
        .expect("post-delete messages")
        .is_empty());
    assert!(
        fresh_sessions
            .get(session_id)
            .expect("source query")
            .is_some(),
        "deleting the fork must not touch the imported source"
    );

    // Idempotent repeat: a missing session is `false`, never an error. The
    // golden sentinel is intentionally NOT reused here (it says `true`).
    let again = fresh_handlers.get("sessions.delete").unwrap()("sessions.delete", &delete_request)
        .expect("repeat delete must still ack");
    assert_eq!(
        again,
        json!({ "deleted": false }),
        "delete must be idempotent"
    );
    assert!(fresh_sessions.get(&fork_id).expect("still gone").is_none());
}
