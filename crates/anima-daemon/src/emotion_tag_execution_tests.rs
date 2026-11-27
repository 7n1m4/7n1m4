// SPDX-License-Identifier: GPL-3.0-or-later
//! Round v27 real-execution proof of the ACT-marker → `emotion.tag` path.
//!
//! The unchanged channel golden fixture
//! `crates/anima-channel/fixtures/golden/event.emotion_tag.emotion.json`
//! is the oracle. An ACT marker is streamed by a recording provider through
//! the REAL `chat.send` renderer handler; the REAL `EventPublisher` /
//! `CueParser` pair derives a cue and the REAL event bus delivers it to a
//! subscribed lane. Only process-minted fields (bus seq, wall clock ts,
//! session id) are projected onto fixture sentinels — and their own
//! invariants are asserted before that projection.

use std::fs;
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use anima_channel::wire::{ChatSendReply, EventPayload, EventTopic, GatewayEvent};
use serde_json::json;

use crate::core::CoreService;
use crate::events::EventPublisher;
use crate::gateway::Gateway;

/// Official short ACT form parsed by `events.rs::parse_act_body`. Field names
/// are the accepted ones: `emotion`, `intensity`, `duration_ms`, `actor`.
const ACT_MARKER: &str =
    r#"<|ACT:emotion="happy",intensity="0.8",duration_ms="3000",actor="character-7"|>"#;

#[tokio::test]
async fn act_marker_stream_drives_real_chat_send_to_golden_emotion_tag() {
    // Turns take a permit from the process-global CHAT_TURNS semaphore.
    static TURN_GUARD: std::sync::LazyLock<tokio::sync::Mutex<()>> =
        std::sync::LazyLock::new(|| tokio::sync::Mutex::new(()));
    let _guard = TURN_GUARD.lock().await;

    // The fixture is read verbatim; never edit or restate it in this test.
    let fixture_path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden/event.emotion_tag.emotion.json");
    let golden: serde_json::Value = serde_json::from_str(
        &fs::read_to_string(&fixture_path).expect("read golden emotion tag fixture"),
    )
    .expect("golden emotion tag is JSON");
    assert_eq!(golden["type"], "event");
    assert_eq!(golden["topic"], "emotion.tag");
    let golden_data = golden["data"].clone();
    let golden_seq = golden_data["seq"].as_u64().expect("fixture seq");
    let golden_ts = golden_data["ts_ms"].as_u64().expect("fixture ts_ms");
    let golden_tag = golden_data["tag"].as_str().expect("fixture tag");
    let golden_kind = golden_data["kind"].as_str().expect("fixture kind");
    let golden_actor = golden_data["actor_id"].as_str().expect("fixture actor_id");
    let golden_intensity = golden_data["intensity"]
        .as_f64()
        .expect("fixture intensity");
    let golden_duration = golden_data["duration_ms"]
        .as_u64()
        .expect("fixture duration_ms");

    // Explicit tempdir config with allowActions: true. This avoids the
    // process-global AIRI_SERVER_CHANNEL_CONFIG env var entirely: the handler
    // is built directly from CoreService + EventPublisher + this config path
    // (the v25 golden trace at gateway.rs:4292 uses the same gate pattern).
    let tmp = tempfile::tempdir().expect("tempdir");
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

    struct ActMarkerProvider {
        marker: String,
    }
    #[async_trait::async_trait]
    impl anima_llm::ChatProvider for ActMarkerProvider {
        fn id(&self) -> &str {
            "act-marker-v27"
        }
        async fn models(&self) -> Result<Vec<anima_llm::ModelInfo>, anima_llm::LlmError> {
            Ok(vec![])
        }
        async fn stream(
            &self,
            _req: anima_llm::ChatRequest,
        ) -> Result<anima_llm::ChatStream, anima_llm::LlmError> {
            let chunks = vec![
                Ok(anima_llm::ChatChunk::text(self.marker.clone())),
                Ok(anima_llm::ChatChunk::finish("stop")),
            ];
            Ok(Box::pin(futures_util::stream::iter(chunks)))
        }
    }

    let session_id = "sess-emotion-v27";
    core.ensure_chat_session(session_id).expect("seed session");
    let svc = core.chat_service().expect("chat service");
    svc.providers.lock().unwrap().insert(
        "act-marker-v27".to_string(),
        Arc::new(ActMarkerProvider {
            marker: ACT_MARKER.to_string(),
        }),
    );
    anima_store::ProviderRepo::new(core.db().expect("db"))
        .upsert(&anima_store::StoredProvider {
            id: "act-marker-v27".to_string(),
            kind: anima_store::ProviderKind::OpenAiCompatible,
            config: json!({ "model": "act-model" }),
            enabled: true,
            updated_at: 0,
        })
        .expect("provider row");

    // Subscribe BEFORE sending: no real event may race past the lane.
    let lane = publisher.bus().new_lane();
    lane.subscribe(EventTopic::ALL);
    publisher.bus().register_lane(&lane);

    let payload = json!({ "sessionId": session_id, "content": "emit the cue" });
    let reply = handlers.get("chat.send").expect("chat.send registered")("chat.send", &payload)
        .expect("real chat.send must ack");

    // Bounded barrier: wait for the REAL published cue, not a sleep.
    let mut events: Vec<GatewayEvent> = Vec::new();
    tokio::time::timeout(Duration::from_secs(5), async {
        loop {
            events.extend(lane.drain());
            let has_cue = events.iter().any(|e| e.topic == EventTopic::EmotionTag);
            let has_terminal = events.iter().any(|e| match &e.data {
                EventPayload::TokenDelta(d) => d.final_,
                _ => false,
            });
            if has_cue && has_terminal {
                break;
            }
            tokio::task::yield_now().await;
        }
    })
    .await
    .expect("real handler must publish emotion.tag and its terminal delta within 5s");

    let ack: ChatSendReply = serde_json::from_value(reply.clone()).expect("typed ack");
    assert!(ack.accepted, "real handler must accept the turn");
    assert_eq!(ack.session_id, session_id);
    assert!(!ack.message_id.is_empty(), "handler must mint a message id");

    // Assert real invariants before projecting anything onto fixture sentinels.
    let mut seqs = Vec::new();
    for event in &events {
        let (seq, ts_ms) = match &event.data {
            EventPayload::TokenDelta(d) => (d.seq, d.ts_ms),
            EventPayload::EmotionTag(d) => (d.seq, d.ts_ms),
            other => panic!("unexpected event on the lane: {other:?}"),
        };
        assert!(ts_ms > 0, "bus must stamp a real ts: {event:?}");
        seqs.push(seq);
    }
    assert!(
        seqs.windows(2).all(|pair| pair[0] < pair[1]),
        "bus seq must be strictly monotonic in publication order: {seqs:?}"
    );

    let cues: Vec<&anima_channel::EmotionTagData> = events
        .iter()
        .filter_map(|event| match (&event.topic, &event.data) {
            (EventTopic::EmotionTag, EventPayload::EmotionTag(data)) => Some(data),
            _ => None,
        })
        .collect();
    assert_eq!(cues.len(), 1, "one ACT marker must produce exactly one cue");
    let cue: &anima_channel::EmotionTagData = cues[0];

    // These four plus kind are the CueParser-derived semantics the fixture
    // pins. They are asserted on the LIVE event, never hand-built.
    assert_eq!(
        cue.tag, golden_tag,
        "ACT emotion normalizes to the golden tag"
    );
    assert_eq!(cue.actor_id, golden_actor, "ACT actor reaches the wire");
    assert_eq!(
        serde_json::to_value(cue.kind).expect("kind serializes"),
        json!(golden_kind),
        "emotion field maps to the emotion cue class"
    );
    assert_eq!(
        cue.intensity as f64, golden_intensity,
        "ACT intensity is the fixture intensity"
    );
    assert_eq!(
        cue.duration_ms,
        Some(golden_duration),
        "duration_ms override reaches the wire"
    );
    assert!(cue.ts_ms > 0, "bus must stamp a real wall clock");
    let cue_session = cue
        .session_id
        .as_deref()
        .expect("chat-derived cue carries a session id");
    assert!(!cue_session.is_empty());
    assert_eq!(cue_session, session_id, "cue belongs to the chat turn");

    // The normal token stream must still complete: the cue is additive.
    let terminal = events
        .iter()
        .filter_map(|event| match &event.data {
            EventPayload::TokenDelta(d) if d.final_ => Some(d),
            _ => None,
        })
        .next()
        .expect("handler must publish a terminal token.delta");
    assert_eq!(terminal.message_id, ack.message_id);

    // Project ONLY process-minted fields (bus seq, wall clock, session id —
    // the fixture omits it because it was published outside a chat turn).
    let mut projected = serde_json::to_value(cue).expect("cue serializes");
    let data = projected.as_object_mut().expect("cue object");
    data["seq"] = json!(golden_seq);
    data["ts_ms"] = json!(golden_ts);
    data.remove("session_id");
    let frame = json!({ "type": "event", "topic": "emotion.tag", "data": projected });
    assert_eq!(
        frame, golden,
        "the real handler's cue equals the unchanged golden event after projecting process-minted fields"
    );
}

/// Presence/status reuse the same untagged `event` frame schema as the ACT cue
/// above (topic + flat data + bus-minted seq/ts_ms), so the identical
/// real-handler → real-bus → golden-frame proof applies to them unchanged.
#[test]
fn presence_status_golden_events_replay_through_real_publisher() {
    let dir = Path::new(env!("CARGO_MANIFEST_DIR")).join("../anima-channel/fixtures/golden");
    let load = |name: &str| -> serde_json::Value {
        serde_json::from_str(
            &fs::read_to_string(dir.join(name)).unwrap_or_else(|e| panic!("read {name}: {e}")),
        )
        .unwrap_or_else(|e| panic!("parse {name}: {e}"))
    };
    let healthy = load("event.status_changed.healthy.json");
    let unhealthy = load("event.status_changed.unhealthy.json");
    let online = load("event.presence_changed.online.json");
    let offline = load("event.presence_changed.offline.json");
    let core_reply = load("core_status.reply.json");

    for (golden, topic) in [
        (&healthy, "status.changed"),
        (&unhealthy, "status.changed"),
        (&online, "presence.changed"),
        (&offline, "presence.changed"),
    ] {
        assert_eq!(golden["type"], "event");
        assert_eq!(golden["topic"], topic);
    }

    // Same explicit tempdir config + renderer_handlers gate as the ACT proof:
    // no process-global AIRI_SERVER_CHANNEL_CONFIG env var is touched.
    let tmp = tempfile::tempdir().expect("tempdir");
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

    // Subscribe BEFORE publishing so no real event races past the lane.
    let lane = publisher.bus().new_lane();
    lane.subscribe(EventTopic::ALL);
    publisher.bus().register_lane(&lane);

    // (a) Healthy health comes from the REAL `core.status` handler, which
    // drives the real publisher.status_changed on this bus.
    let reply = handlers
        .get("core.status")
        .expect("core.status handler registered")("core.status", &json!({}))
    .expect("real core.status must ack");
    // core.rs:538 mints CARGO_PKG_NAME ('anima-daemon') while
    // core_status.reply.json and runtime_status.reply.json say 'airi-daemon'.
    // This test compares only the health fields that feed status.changed; the
    // identity drift is unowned and tracked by follow-up bead airi-ib4p.
    assert_eq!(reply["coreAvailable"], core_reply["coreAvailable"]);
    assert_eq!(reply["storeAvailable"], core_reply["storeAvailable"]);
    assert_eq!(reply["storeHealth"], core_reply["storeHealth"]);

    let mut events = lane.drain();
    assert_eq!(events.len(), 1, "one status.changed per health change");
    assert_eq!(events[0].topic, EventTopic::StatusChanged);

    // (b) An identical repeat returns false and emits NOTHING at all.
    assert!(
        !publisher.status_changed(true, true, "ok", None),
        "an unchanged health snapshot must be deduped"
    );
    assert_eq!(lane.len(), 0, "a deduped snapshot publishes no frame");

    // (c) Distinct health + two real presence transitions on the same bus.
    assert!(publisher.status_changed(false, false, "unavailable", None));
    publisher.presence_changed("user-42", "online", None);
    publisher.presence_changed("user-42", "offline", None);
    events.extend(lane.drain());
    assert_eq!(
        events.len(),
        4,
        "unhealthy status + online + offline presence"
    );

    // Assert LIVE invariants before projecting anything onto fixture sentinels.
    let mut seqs = Vec::new();
    for event in &events {
        let (seq, ts_ms) = match &event.data {
            EventPayload::StatusChanged(d) => (d.seq, d.ts_ms),
            EventPayload::PresenceChanged(d) => (d.seq, d.ts_ms),
            other => panic!("unexpected event on lane: {other:?}"),
        };
        assert!(ts_ms > 0, "bus must stamp a real wall clock: {event:?}");
        seqs.push(seq);
        let obj = serde_json::to_value(&event.data).expect("data serializes");
        let obj = obj.as_object().expect("data object");
        for forbidden in [
            "authToken",
            "auth_token",
            "dbusToken",
            "apiKey",
            "api_key",
            "secret",
            "prompt",
            "config",
            "token",
            "path",
            "password",
        ] {
            assert!(
                !obj.contains_key(forbidden),
                "forbidden field {forbidden} on {event:?}"
            );
        }
    }
    assert!(
        seqs.windows(2).all(|pair| pair[0] < pair[1]),
        "bus seq must be strictly monotonic in publication order: {seqs:?}"
    );

    // Each live frame, after projecting ONLY the process-minted seq/ts_ms, is
    // byte-for-byte the unchanged golden event frame.
    for (event, golden) in events.iter().zip([&healthy, &unhealthy, &online, &offline]) {
        let golden_seq = golden["data"]["seq"].as_u64().expect("golden seq");
        let golden_ts = golden["data"]["ts_ms"].as_u64().expect("golden ts");
        let mut projected = serde_json::to_value(&event.data).expect("data serializes");
        let data = projected.as_object_mut().expect("data object");
        for (key, value) in golden["data"].as_object().expect("golden data") {
            if key == "seq" || key == "ts_ms" {
                continue;
            }
            assert_eq!(
                &data[key], value,
                "live {key} must match the golden before projection"
            );
        }
        data["seq"] = json!(golden_seq);
        data["ts_ms"] = json!(golden_ts);
        let topic = serde_json::to_value(event.topic).expect("topic serializes");
        let frame = json!({ "type": "event", "topic": topic, "data": projected });
        assert_eq!(
            frame, *golden,
            "real published frame equals the unchanged golden after projecting seq/ts_ms"
        );
    }
}
