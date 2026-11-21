// SPDX-License-Identifier: GPL-3.0-or-later

//! Golden chat conformance at daemon level: persisted user turn and
//! cancellation honesty.

use anima_daemon::core::CoreService;
use anima_store::MessageRepo;
use tempfile::tempdir;

#[test]
fn golden_chat_send_persists_user_turn() {
    let profile = tempdir().unwrap();
    let svc = CoreService::open(Some(profile.path().to_path_buf()));
    assert!(svc.available());
    let msg = svc.chat_send("golden-sess", "hello").unwrap();
    assert_eq!(msg.role, "user");
    assert_eq!(msg.content, "hello");
    let db = svc.db().unwrap();
    let messages = MessageRepo::new(db).list("golden-sess").unwrap();
    assert_eq!(messages.len(), 1);
    assert_eq!(messages[0].content, "hello");
}

#[test]
fn golden_chat_cancel_unknown_session_is_honest() {
    let profile = tempdir().unwrap();
    let svc = CoreService::open(Some(profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(!svc.chat_cancel("no-such-session"));
}