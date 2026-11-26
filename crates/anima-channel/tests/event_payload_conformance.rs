// SPDX-License-Identifier: GPL-3.0-or-later

//! Wire conformance for the typed event payloads consumed by non-Rust clients.
//! Every Rust-canonical event fixture must decode to the variant selected by its
//! topic and retain all payload fields. Unknown and non-object data are rejected
//! without a panic; absent optional values retain their defaults.

use anima_channel::wire::{CueKind, EventPayload, GatewayServerFrame};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn fixtures_dir() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden")
}

fn load_frame(name: &str) -> Value {
    let path = fixtures_dir().join(format!("{name}.json"));
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
}

fn event_data(name: &str) -> Value {
    let frame = load_frame(name);
    assert_eq!(frame["type"], "event");
    frame.get("data").cloned().unwrap_or_else(|| {
        panic!("{name}: missing data property");
    })
}

fn decode_fixture(name: &str, topic: &str) -> EventPayload {
    let frame = load_frame(name);
    assert_eq!(frame["type"], "event");
    assert_eq!(frame["topic"], topic);
    let decoded: GatewayServerFrame = serde_json::from_value(frame).unwrap_or_else(|e| {
        panic!("{name}: typed event decode failed: {e}");
    });
    match decoded {
        GatewayServerFrame::Event {
            topic: actual,
            data,
            ..
        } => {
            assert_eq!(actual.as_str(), topic);
            data
        }
        other => panic!("{name}: expected event frame, got {other:?}"),
    }
}

#[test]
fn lip_sync_rms_fixtures_round_trip() {
    for name in [
        "event.lip_sync_rms.silence",
        "event.lip_sync_rms.basic",
        "event.lip_sync_rms.peak",
    ] {
        let source = event_data(name);
        let decoded = decode_fixture(name, "lip_sync.rms");
        let EventPayload::LipSyncRms(data) = decoded else {
            panic!("{name}: wrong payload variant");
        };
        assert_eq!(data.actor_id, source["actor_id"].as_str().unwrap());
        assert_eq!(data.level, source["level"].as_f64().unwrap() as f32);
        assert_eq!(data.seq, source["seq"].as_u64().unwrap());
        assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
    }
}

#[test]
fn emotion_tag_fixtures_round_trip() {
    for (name, tag, kind) in [
        ("event.emotion_tag.emotion", "happy", CueKind::Emotion),
        (
            "event.emotion_tag.motion_no_duration",
            "wave",
            CueKind::Motion,
        ),
        ("event.emotion_tag.vfx", "sparkle", CueKind::Vfx),
    ] {
        let source = event_data(name);
        let decoded = decode_fixture(name, "emotion.tag");
        let EventPayload::EmotionTag(data) = decoded else {
            panic!("{name}: wrong payload variant");
        };
        assert_eq!(data.actor_id, source["actor_id"].as_str().unwrap());
        assert_eq!(data.tag, tag);
        assert_eq!(data.kind, kind);
        assert_eq!(data.intensity, source["intensity"].as_f64().unwrap() as f32);
        assert_eq!(
            data.duration_ms,
            source.get("duration_ms").and_then(Value::as_u64)
        );
        assert_eq!(data.seq, source["seq"].as_u64().unwrap());
        assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
    }
}

#[test]
fn token_delta_fixtures_round_trip() {
    for name in ["event.token_delta.partial", "event.token_delta.final"] {
        let source = event_data(name);
        let decoded = decode_fixture(name, "token.delta");
        let EventPayload::TokenDelta(data) = decoded else {
            panic!("{name}: wrong payload variant");
        };
        assert_eq!(data.session_id, source["session_id"].as_str().unwrap());
        assert_eq!(data.message_id, source["message_id"].as_str().unwrap());
        assert_eq!(data.delta, source["delta"].as_str().unwrap());
        assert_eq!(data.index, source["index"].as_u64().unwrap());
        assert_eq!(data.final_, source["final"].as_bool().unwrap());
        assert_eq!(data.seq, source["seq"].as_u64().unwrap());
        assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
        assert_eq!(
            data.reason.as_deref(),
            source["reason"].as_str(),
            "{name}: reason must survive the round trip"
        );
        if name.ends_with(".final") {
            assert_eq!(data.reason.as_deref(), Some("complete"));
            assert_eq!(source["reason"].as_str(), Some("complete"));
        } else {
            assert_eq!(data.reason, None);
            assert!(source.get("reason").is_none());
        }
    }
    // A final frame from an older daemon has no reason field: it must decode
    // as complete rather than fail, so legacy clients keep working.
    let mut legacy = event_data("event.token_delta.final");
    legacy.as_object_mut().unwrap().remove("reason");
    let payload = serde_json::from_value::<EventPayload>(legacy).unwrap();
    let EventPayload::TokenDelta(data) = payload else {
        panic!("legacy final frame decoded to wrong variant");
    };
    assert_eq!(data.reason, None);
    assert!(data.final_);
}

#[test]
fn presence_changed_fixtures_round_trip() {
    for (name, state) in [
        ("event.presence_changed.online", "online"),
        ("event.presence_changed.offline", "offline"),
    ] {
        let source = event_data(name);
        let decoded = decode_fixture(name, "presence.changed");
        let EventPayload::PresenceChanged(data) = decoded else {
            panic!("{name}: wrong payload variant");
        };
        assert_eq!(data.subject, source["subject"].as_str().unwrap());
        assert_eq!(data.state, state);
        assert_eq!(data.seq, source["seq"].as_u64().unwrap());
        assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
    }
}

#[test]
fn status_changed_fixtures_round_trip() {
    for (name, core, store, health) in [
        ("event.status_changed.healthy", true, true, "ok"),
        (
            "event.status_changed.unhealthy",
            false,
            false,
            "unavailable",
        ),
    ] {
        let source = event_data(name);
        let decoded = decode_fixture(name, "status.changed");
        let EventPayload::StatusChanged(data) = decoded else {
            panic!("{name}: wrong payload variant");
        };
        assert_eq!(data.core_available, core);
        assert_eq!(data.store_available, store);
        assert_eq!(data.store_health, health);
        assert_eq!(data.seq, source["seq"].as_u64().unwrap());
        assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
    }
}

#[test]
fn settings_changed_fixture_round_trip() {
    let name = "event.settings_changed.captions";
    let source = event_data(name);
    let decoded = decode_fixture(name, "settings.changed");
    let EventPayload::SettingsChanged(data) = decoded else {
        panic!("{name}: wrong payload variant");
    };
    assert_eq!(data.section, source["section"].as_str().unwrap());
    assert_eq!(data.seq, source["seq"].as_u64().unwrap());
    assert_eq!(data.ts_ms, source["ts_ms"].as_u64().unwrap());
    assert!(source.get("settings").is_none(), "no values on the wire");
}

#[test]
fn invalid_data_does_not_panic() {
    for (topic, data) in [
        ("does.not.exist", serde_json::json!({})),
        ("lip_sync.rms", serde_json::json!([1, 2, 3])),
        (
            "emotion.tag",
            serde_json::json!({ "actor_id": "a", "tag": "t", "kind": "future-kind", "intensity": 0.5 }),
        ),
        (
            "lip_sync.rms",
            serde_json::json!({ "actor_id": "a", "seq": 1, "ts_ms": 2 }),
        ),
        (
            "lip_sync.rms",
            serde_json::json!({ "actor_id": "a", "level": "0.5", "seq": 1, "ts_ms": 2 }),
        ),
        (
            "emotion.tag",
            serde_json::json!({ "actor_id": "a", "tag": "t", "kind": "emotion", "seq": 1, "ts_ms": 2 }),
        ),
        (
            "emotion.tag",
            serde_json::json!({ "actor_id": "a", "tag": "t", "kind": "emotion", "intensity": "0.5", "seq": 1, "ts_ms": 2 }),
        ),
    ] {
        let frame = serde_json::json!({ "type": "event", "topic": topic, "data": data });
        let decoded: Result<GatewayServerFrame, _> = serde_json::from_value(frame);
        assert!(
            decoded.is_err(),
            "invalid event unexpectedly decoded: {decoded:?}"
        );
    }
}

#[test]
fn every_event_fixture_is_a_valid_object_envelope() {
    let dir = fixtures_dir();
    let mut count = 0;
    for entry in std::fs::read_dir(&dir).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|s| s.to_str()) != Some("json")
            || !path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("event.")
        {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let value: Value = serde_json::from_str(&text).unwrap();
        assert!(value.is_object());
        assert_eq!(value["type"], "event");
        assert!(!value["topic"].as_str().unwrap().is_empty());
        assert!(value["data"].is_object());
        count += 1;
    }
    assert!(count > 0, "no event fixtures found");
}
