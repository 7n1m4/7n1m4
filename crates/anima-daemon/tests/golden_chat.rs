// SPDX-License-Identifier: GPL-3.0-or-later

//! Golden chat conformance at daemon level: persisted user turn and
//! cancellation honesty.

use anima_daemon::core::CoreService;
use anima_store::MessageRepo;
use std::path::Path;
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

/// The daemon joins the golden persona fixture into the exact system prefix
/// the provider receives: fixed section order, nickname prefix, greeting
/// bullets, and no daemon-owned keys crossing the wire.
#[test]
fn golden_chat_persona_fixture_joins_in_fixed_order() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden/chat.send.persona.request.json");
    let text = std::fs::read_to_string(&path).expect("read persona golden fixture");
    let value: serde_json::Value = serde_json::from_str(&text).expect("persona fixture is JSON");
    let request: anima_channel::wire::ChatSendRequest =
        serde_json::from_value(value).expect("persona fixture decodes as chat.send request");

    assert!(
        request.persona.is_some(),
        "persona golden carries a persona"
    );
    for forbidden in ["system", "a2ui", "genUi"] {
        let mut payload = serde_json::Map::new();
        payload.insert("systemPrompt".into(), serde_json::json!("SYS"));
        payload.insert(forbidden.into(), serde_json::json!("daemon-owned"));
        assert!(
            serde_json::from_value::<anima_channel::wire::PersonaPrompt>(
                serde_json::Value::Object(payload)
            )
            .is_err(),
            "persona must reject `{forbidden}` at the wire boundary"
        );
    }

    let joined = request.persona.unwrap().join();
    let expected = [
        "SYS",
        "Nickname: Ari",
        "A curious companion",
        "Playful",
        "A sunny balcony",
        "Greetings / Dialog Starters:\n- Hi!\n- Hello!",
        "ACT1",
        "ACT2",
        "ART",
        "JOURNAL",
        "SANDBOX",
        "The user wants to customize or tweak the premise of this encounter, please adjust to the text below: PREMISE",
        "This is what your appearance is for this story. Try to make it work with your known appearance; you're free to modify or adjust as needed: LOOKS",
        "The setting and location for this encounter is: PLACE",
    ]
    .join("\n");
    assert_eq!(joined, expected);
    assert!(
        joined.contains("The setting and location for this encounter is: PLACE"),
        "scene must carry the TS buildSystemPrompt prefix"
    );
}

#[test]
fn golden_chat_cancel_unknown_session_is_honest() {
    let profile = tempdir().unwrap();
    let svc = CoreService::open(Some(profile.path().to_path_buf()));
    assert!(svc.available());
    assert!(!svc.chat_cancel("no-such-session"));
}
