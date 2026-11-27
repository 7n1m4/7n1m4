// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust leg of the shared settings bridge trace (v24b).
//!
//! Both engines replay the same seven frames from
//! `fixtures/golden/trace.settings.captions.json`:
//!
//!   settings.get -> settings.set partial PATCH -> settings.changed ->
//!   settings.get again, showing the merged field with siblings preserved.
//!
//! Every reply/event frame is decoded straight from the fixture JSON with the
//! production `GatewayServerFrame` codec. No action is injected and no
//! envelope is rebuilt: a frame missing its wire `action` must fail here.
//!
//! ```sh
//! cargo test -p anima-channel interaction_settings_trace
//! ```

use anima_channel::wire::{
    EventPayload, EventTopic, GatewayServerFrame, SettingsChangedData, SettingsGetReply,
    SettingsSetReply,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::path::Path;

#[derive(Debug, Deserialize)]
struct Fixture {
    schema: String,
    path: String,
    frames: Vec<Value>,
}

fn load_fixture() -> Fixture {
    let path =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden/trace.settings.captions.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
}

fn settings_map(reply: &SettingsGetReply) -> BTreeMap<String, Value> {
    serde_json::from_str(&reply.settings)
        .unwrap_or_else(|e| panic!("settings blob is not a JSON object: {e}"))
}

#[test]
fn interaction_settings_trace_matches_shared_fixture() {
    let fixture = load_fixture();
    assert_eq!(fixture.schema, "airi-channel-trace-v1");
    assert_eq!(fixture.path, "settings.get/set");
    assert_eq!(
        fixture.frames.len(),
        7,
        "the trace must keep all seven frames"
    );

    // 0: settings.get request (s1).
    let get1 = &fixture.frames[0];
    assert_eq!(get1["type"], "rpc");
    assert_eq!(get1["action"], "settings.get");
    assert_eq!(get1["id"], "s1");
    assert_eq!(get1["payload"]["section"], "captions");

    // 1: settings.get reply (s1), raw frame through the real reply DTO.
    let reply1 = &fixture.frames[1];
    let decoded1: GatewayServerFrame = serde_json::from_value(reply1.clone())
        .unwrap_or_else(|e| panic!("frame 1 is not a valid server frame: {e}"));
    let GatewayServerFrame::Rpc {
        action,
        ok,
        id,
        data,
        ..
    } = &decoded1
    else {
        panic!("frame 1 is not an rpc reply: {decoded1:?}");
    };
    assert_eq!(action, "settings.get");
    assert!(*ok, "frame 1 reply must be successful");
    assert_eq!(id.as_ref().and_then(Value::as_str), Some("s1"));
    let get_reply: SettingsGetReply = serde_json::from_value(data.clone().expect("reply data"))
        .expect("settings.get reply decodes into SettingsGetReply");
    assert_eq!(get_reply.section, "captions");
    let initial = settings_map(&get_reply);
    assert_eq!(initial.get("enabled"), Some(&json!(false)));
    assert_eq!(initial.get("fontSize"), Some(&json!(150)));
    assert_eq!(initial.get("opacity"), Some(&json!(70)));
    assert_eq!(initial.get("docking"), Some(&json!("head")));

    // 2: settings.set request (s2) carries a PATCH, not the full blob.
    let set1 = &fixture.frames[2];
    assert_eq!(set1["type"], "rpc");
    assert_eq!(set1["action"], "settings.set");
    assert_eq!(set1["id"], "s2");
    assert_eq!(set1["payload"]["section"], "captions");
    let patch: BTreeMap<String, Value> = serde_json::from_str(
        set1["payload"]["settings"]
            .as_str()
            .expect("settings string"),
    )
    .expect("PATCH is a JSON object");
    assert_eq!(patch.len(), 1, "PATCH must carry only the changed field");
    assert_eq!(
        patch.get("opacity"),
        Some(&json!(55)),
        "PATCH sets opacity 55"
    );
    assert!(!patch.contains_key("enabled"), "no sibling in PATCH");
    assert!(!patch.contains_key("fontSize"), "no sibling in PATCH");
    assert!(!patch.contains_key("docking"), "no sibling in PATCH");

    // 3: settings.set reply (s2), raw frame through the real reply DTO.
    let reply2 = &fixture.frames[3];
    let decoded2: GatewayServerFrame = serde_json::from_value(reply2.clone())
        .unwrap_or_else(|e| panic!("frame 3 is not a valid server frame: {e}"));
    let GatewayServerFrame::Rpc {
        action,
        ok,
        id,
        data,
        ..
    } = &decoded2
    else {
        panic!("frame 3 is not an rpc reply: {decoded2:?}");
    };
    assert_eq!(action, "settings.set");
    assert!(*ok, "frame 3 reply must be successful");
    assert_eq!(id.as_ref().and_then(Value::as_str), Some("s2"));
    let set_reply: SettingsSetReply = serde_json::from_value(data.clone().expect("reply data"))
        .expect("settings.set reply decodes into SettingsSetReply");
    assert!(set_reply.ok);

    // 4: settings.changed event carries section/seq/ts_ms, no values.
    let event = &fixture.frames[4];
    assert_eq!(event["topic"], "settings.changed");
    let decoded_event: GatewayServerFrame = serde_json::from_value(event.clone())
        .unwrap_or_else(|e| panic!("frame 4 is not a valid server frame: {e}"));
    let GatewayServerFrame::Event { topic, data, .. } = &decoded_event else {
        panic!("frame 4 is not an event: {decoded_event:?}");
    };
    assert_eq!(*topic, EventTopic::SettingsChanged);
    assert_eq!(topic.as_str(), "settings.changed");
    let EventPayload::SettingsChanged(changed) = data else {
        panic!("frame 4 payload is not settings.changed: {data:?}");
    };
    assert_eq!(changed.section, "captions");
    assert_eq!(changed.seq, 102);
    assert_eq!(changed.ts_ms, 1_700_000_000_900);
    let direct: SettingsChangedData = serde_json::from_value(event["data"].clone())
        .expect("event data decodes into SettingsChangedData");
    assert_eq!(direct, *changed);

    // 5: the event is a read hint, not a value carrier: re-read with a new id.
    let get2 = &fixture.frames[5];
    assert_eq!(get2["type"], "rpc");
    assert_eq!(get2["action"], "settings.get");
    assert_eq!(get2["id"], "s3");
    assert_eq!(get2["payload"]["section"], "captions");

    // 6: re-read shows the patched opacity with every sibling intact.
    let reply3 = &fixture.frames[6];
    let decoded3: GatewayServerFrame = serde_json::from_value(reply3.clone())
        .unwrap_or_else(|e| panic!("frame 6 is not a valid server frame: {e}"));
    let GatewayServerFrame::Rpc {
        action,
        ok,
        id,
        data,
        ..
    } = &decoded3
    else {
        panic!("frame 6 is not an rpc reply: {decoded3:?}");
    };
    assert_eq!(action, "settings.get");
    assert!(*ok, "frame 6 reply must be successful");
    assert_eq!(id.as_ref().and_then(Value::as_str), Some("s3"));
    let get_reply3: SettingsGetReply = serde_json::from_value(data.clone().expect("reply data"))
        .expect("final settings.get reply decodes into SettingsGetReply");
    assert_eq!(get_reply3.section, "captions");
    let merged = settings_map(&get_reply3);
    assert_eq!(
        merged.get("opacity"),
        Some(&json!(55)),
        "opacity merged to 55"
    );
    assert_eq!(merged.get("enabled"), initial.get("enabled"));
    assert_eq!(merged.get("fontSize"), initial.get("fontSize"));
    assert_eq!(merged.get("docking"), initial.get("docking"));
    let mut expected = initial.clone();
    expected.insert("opacity".to_owned(), json!(55));
    assert_eq!(merged, expected, "only opacity changed across the trace");
}
