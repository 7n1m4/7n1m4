// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust leg of the shared chat streaming trace fixture.
//!
//! ```sh
//! cargo test -p anima-channel interaction_chat_trace
//! ```
//!
//! The same JSON envelope is replayed by
//! `apps/flutter/test/chat_golden_trace_test.dart`, so both codecs must derive
//! identical values from the same bytes: request -> ack -> two text token
//! deltas followed by a distinct empty-delta terminal frame.

use anima_channel::wire::{
    ChatSendReply, ChatSendRequest, EventPayload, EventTopic, GatewayClientFrame,
    GatewayServerFrame,
};
use serde_json::Value;
use std::path::{Path, PathBuf};

fn fixture_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden/trace.chat.send.token_delta.json")
}

fn load_fixture() -> Value {
    let path = fixture_path();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
}

#[test]
fn interaction_chat_trace_matches_shared_fixture() {
    let fixture = load_fixture();
    assert_eq!(fixture["schema"], "airi-channel-trace-v1");
    assert_eq!(fixture["path"], "chat.send");

    let frames = fixture["frames"]
        .as_array()
        .expect("trace fixture: `frames` must be an array");
    assert_eq!(frames.len(), 5, "trace fixture must hold exactly 5 frames");

    // Frame 0: client -> server `chat.send` request, echo id `t1`.
    let request_frame: GatewayClientFrame =
        serde_json::from_value(frames[0].clone()).expect("frame 0 is not a client frame");
    let GatewayClientFrame::Rpc {
        action,
        payload,
        id,
    } = request_frame
    else {
        panic!("frame 0 must be a client rpc request");
    };
    assert_eq!(action, "chat.send");
    assert_eq!(id, Some(Value::String("t1".to_string())));
    let request: ChatSendRequest =
        serde_json::from_value(payload.expect("frame 0 has no payload")).unwrap();
    assert_eq!(request.session_id, "sess-abc");
    assert_eq!(request.content, "Hello, Anima!");

    // Frame 1: server -> client ack, echoing the same id and declaring msg-1.
    let reply_frame: GatewayServerFrame =
        serde_json::from_value(frames[1].clone()).expect("frame 1 is not a server frame");
    let GatewayServerFrame::Rpc {
        action,
        ok,
        data,
        id,
        ..
    } = reply_frame
    else {
        panic!("frame 1 must be a server rpc reply");
    };
    assert_eq!(action, "chat.send");
    assert!(ok, "frame 1 must be a successful reply");
    assert_eq!(
        id,
        Some(Value::String("t1".to_string())),
        "rpc id must pass through verbatim"
    );
    let reply: ChatSendReply = serde_json::from_value(data.expect("frame 1 has no data")).unwrap();
    assert_eq!(reply.session_id, request.session_id);
    assert_eq!(reply.message_id, "msg-1");
    assert!(reply.accepted);

    // Frames 2/3/4: token.delta events on the message declared by the ack.
    // The real daemon emits a distinct EMPTY-delta terminal frame, so the
    // terminal is frame 4 — not the last text delta at frame 3.
    let mut deltas = Vec::new();
    for (i, frame) in frames.iter().enumerate().skip(2) {
        let event_frame: GatewayServerFrame =
            serde_json::from_value(frame.clone()).unwrap_or_else(|e| panic!("frame {i}: {e}"));
        let GatewayServerFrame::Event { topic, data, .. } = event_frame else {
            panic!("frame {i} must be a server event frame");
        };
        assert_eq!(topic, EventTopic::TokenDelta, "frame {i}");
        assert_eq!(data.topic(), EventTopic::TokenDelta, "frame {i}");
        let EventPayload::TokenDelta(delta) = data else {
            panic!("frame {i} must carry a TokenDelta payload");
        };
        deltas.push(delta);
    }
    assert_eq!(deltas.len(), 3);

    let (partial, middle, terminal) = (&deltas[0], &deltas[1], &deltas[2]);
    for (i, delta) in deltas.iter().enumerate() {
        assert_eq!(delta.session_id, request.session_id, "delta {i}");
        assert_eq!(delta.message_id, reply.message_id, "delta {i}");
    }
    assert_eq!(
        deltas.iter().filter(|d| d.final_).count(),
        1,
        "exactly one terminal token.delta frame"
    );
    for delta in &deltas[..2] {
        assert!(!delta.delta.is_empty(), "text deltas must carry text");
    }
    assert!(terminal.delta.is_empty(), "terminal delta must be empty");

    assert_eq!(partial.delta, "Hello");
    assert_eq!(partial.index, 0);
    assert_eq!(partial.seq, 5);
    assert_eq!(partial.ts_ms, 1700000000900);
    assert!(!partial.final_);
    assert_eq!(partial.reason, None);

    assert_eq!(middle.delta, " world");
    assert_eq!(middle.index, 1);
    assert_eq!(middle.seq, 6);
    assert_eq!(middle.ts_ms, 1700000000950);
    assert!(!middle.final_, "the middle frame must not be final");
    assert_eq!(middle.reason, None);

    assert_eq!(terminal.delta, "");
    assert_eq!(terminal.index, 2);
    assert_eq!(terminal.seq, 7);
    assert_eq!(terminal.ts_ms, 1700000001000);
    assert!(terminal.final_, "the terminal frame must be last");
    assert_eq!(terminal.reason.as_deref(), Some("complete"));

    // Re-serialize through the real wire type: the terminal payload keeps
    // byte-identical field names (including `final` and `reason`).
    assert_eq!(
        serde_json::to_value(terminal).unwrap(),
        frames[4]["data"],
        "terminal token.delta must round-trip unchanged"
    );
}
