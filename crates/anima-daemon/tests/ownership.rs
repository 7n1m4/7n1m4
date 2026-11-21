// SPDX-License-Identifier: GPL-3.0-or-later

use std::path::PathBuf;

use anima_core::memory::TextJournalService;
use anima_core::settings::CardsSettings;
use anima_daemon::core::CoreService;
use anima_store::Database;
use anima_store::SessionRepo;
use anima_store::MessageRepo;
use tempfile::tempdir;

fn store_path(profile: &std::path::Path) -> PathBuf {
    profile.join("airi.sqlite")
}

#[test]
fn daemon_mode_owns_the_store() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(store_path(daemon_profile.path()).exists());

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn fallback_mode_opens_local_store() {
    let local_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(local_profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(store_path(local_profile.path()).exists());

    let daemon_profile = tempdir().unwrap();
    assert!(!store_path(daemon_profile.path()).exists());
}

#[test]
fn required_unhealthy_never_opens_local() {
    let profile = tempdir().unwrap();
    assert!(!store_path(profile.path()).exists());
}

#[test]
fn daemon_and_local_are_distinct_profiles() {
    let profile_a = tempdir().unwrap();
    let profile_b = tempdir().unwrap();

    let daemon_svc = CoreService::open(Some(profile_a.path().to_path_buf()));
    let local_svc = CoreService::open(Some(profile_b.path().to_path_buf()));
    assert!(daemon_svc.available());
    assert!(local_svc.available());

    let path_a = store_path(profile_a.path());
    let path_b = store_path(profile_b.path());
    assert!(path_a.exists());
    assert!(path_b.exists());
    assert_ne!(path_a, path_b);
}

#[test]
fn chat_sessions_daemon_store_operates() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(store_path(daemon_profile.path()).exists());

    let db = Database::open(&store_path(daemon_profile.path())).unwrap();
    let repo = SessionRepo::new(db);
    let session = repo.create("chat-1", "Hello").unwrap();
    assert_eq!(session.title, "Hello");
    assert_eq!(repo.list().unwrap().len(), 1);
    assert!(repo.get("chat-1").unwrap().is_some());

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn stmm_and_journal_daemon_store_appends() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    let db = Database::open(&store_path(daemon_profile.path())).unwrap();

    // STMM: summary repo operates against the daemon-owned store.
    let summaries = anima_store::SummaryRepo::new(db.clone());
    summaries
        .insert(&anima_store::StoredSummary {
            id: "sum-1".to_string(),
            day: "2026-11-21".to_string(),
            content: "did things".to_string(),
            source_session_ids: vec![],
            token_estimate: 4,
            created_at: 10,
        })
        .unwrap();
    assert_eq!(summaries.count().unwrap(), 1);

    // Journal: TextJournalService appends against the daemon-owned store.
    let journal = TextJournalService::new(db);
    let id = journal.append_note("a note").unwrap();
    assert!(!id.is_empty());
    assert_eq!(journal.count().unwrap(), 1);

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn cards_daemon_settings_load_and_save() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    let value = serde_json::json!({"activeCardId": "hero"});
    let reply = svc.settings_set("cards", value).unwrap();
    assert!(reply.ok);

    let got = svc.settings_get("cards").unwrap();
    assert!(got.settings.contains("hero"));

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn mode_selection_controls_store_ownership() {
    // Daemon mode: daemon owns the store.
    let daemon_profile = tempdir().unwrap();
    let daemon_svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(daemon_svc.available());
    assert!(store_path(daemon_profile.path()).exists());

    // Client-local fallback: local store.
    let local_profile = tempdir().unwrap();
    let local_svc = CoreService::open(Some(local_profile.path().to_path_buf()));
    assert!(local_svc.available());
    assert!(store_path(local_profile.path()).exists());

    // Required-unhealthy: no local store opened.
    let profile = tempdir().unwrap();
    assert!(!store_path(profile.path()).exists());
}


#[test]
fn chat_send_daemon_single_writer() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(store_path(daemon_profile.path()).exists());

    let message = svc.chat_send("session-1", "hello").unwrap();
    assert_eq!(message.role, "user");
    assert_eq!(message.content, "hello");
    assert_eq!(message.session_id, "session-1");

    let db = Database::open(&store_path(daemon_profile.path())).unwrap();
    let messages = MessageRepo::new(db).list("session-1").unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].content, "hello");

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn chat_stream_replays_sessions() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    svc.chat_send("session-a", "first").unwrap();
    svc.chat_send("session-a", "second").unwrap();
    svc.chat_send("session-b", "other").unwrap();

    let replay = svc.chat_stream("session-a").unwrap();
    assert_eq!(replay.len(), 2);
    assert_eq!(replay[0].content, "first");
    assert_eq!(replay[1].content, "second");

    let replay_b = svc.chat_stream("session-b").unwrap();
    assert_eq!(replay_b.len(), 1);

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn stmm_and_journal_services_daemon_owned() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    let stmm = svc.stmm_service().unwrap();
    let db = svc.db().unwrap();
    let summaries = anima_store::SummaryRepo::new(db.clone());
    summaries
        .insert(&anima_store::StoredSummary {
            id: "sum-2".to_string(),
            day: "2026-11-21".to_string(),
            content: "more".to_string(),
            source_session_ids: vec![],
            token_estimate: 2,
            created_at: 11,
        })
        .unwrap();
    let ctx = stmm.build_context(&["2026-11-21".to_string()]).unwrap();
    assert!(ctx.contains("more"));

    let journal = svc.journal_service().unwrap();
    let id = journal.append_note("daemon note").unwrap();
    assert!(!id.is_empty());
    assert_eq!(journal.count().unwrap(), 1);

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn session_export_daemon_owned() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    svc.chat_send("export-1", "hello").unwrap();
    let jsonl = svc.session_export_jsonl("export-1").unwrap();
    assert!(jsonl.contains("\"type\":\"session\""));
    assert!(jsonl.contains("hello"));

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}

#[test]
fn cards_settings_daemon_owned_round_trip() {
    let daemon_profile = tempdir().unwrap();
    let svc = CoreService::open(Some(daemon_profile.path().to_path_buf()));
    assert!(svc.available());

    let value = serde_json::json!({"activeCardId": "daemon-hero"});
    let reply = svc.settings_set("cards", value).unwrap();
    assert!(reply.ok);
    let got = svc.settings_get("cards").unwrap();
    assert!(got.settings.contains("daemon-hero"));

    let client_profile = tempdir().unwrap();
    assert!(!store_path(client_profile.path()).exists());
}
