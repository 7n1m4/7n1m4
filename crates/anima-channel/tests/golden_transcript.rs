// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust conformance test: replay a deterministic golden chat transcript
//! (prompt -> ack -> streamed deltas -> terminal marker) and the
//! cancellation branch through the channel wire types.

#[cfg(test)]
mod golden_transcript {
    use anima_channel::wire::{
        ChatCancelReply, ChatCancelRequest, ChatDelta, ChatSendReply, ChatSendRequest,
        GatewayServerFrame,
    };
    use serde::de::DeserializeOwned;
    use serde::Serialize;
    use std::path::{Path, PathBuf};

    fn fixtures_dir() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden")
    }

    fn load_json(name: &str) -> serde_json::Value {
        let path = fixtures_dir().join(format!("{name}.json"));
        let text = std::fs::read_to_string(&path).unwrap();
        serde_json::from_str(&text).unwrap()
    }

    fn round_trip<T>(value: &serde_json::Value)
    where
        T: Serialize + DeserializeOwned + PartialEq + std::fmt::Debug,
    {
        let decoded: T = serde_json::from_value(value.clone()).unwrap();
        let re = serde_json::to_value(&decoded).unwrap();
        assert_eq!(value, &re);
    }

    #[test]
    fn chat_send_request_round_trips() {
        let v = serde_json::json!({"sessionId":"sess-abc","content":"hi"});
        round_trip::<ChatSendRequest>(&v);
    }

    #[test]
    fn chat_send_reply_round_trips() {
        let v = serde_json::json!({"sessionId":"sess-abc","messageId":"msg-1","accepted":true});
        round_trip::<ChatSendReply>(&v);
    }

    #[test]
    fn chat_delta_partial_and_final_round_trip() {
        for (delta, final_) in [("Hello", false), (" world", true)] {
            let v = serde_json::json!({
                "sessionId":"sess-abc","messageId":"msg-1","delta":delta,
                "index": if final_ {1} else {0}, "final":final_
            });
            round_trip::<ChatDelta>(&v);
        }
    }

    #[test]
    fn chat_cancel_round_trips() {
        let req = serde_json::json!({"sessionId":"sess-abc","requestId":"r1"});
        round_trip::<ChatCancelRequest>(&req);
        let rep = serde_json::json!({"cancelled":true});
        round_trip::<ChatCancelReply>(&rep);
    }

    #[test]
    fn golden_token_delta_fixtures_round_trip() {
        for name in &["event.token_delta.partial", "event.token_delta.final"] {
            let value = load_json(name);
            round_trip::<GatewayServerFrame>(&value);
        }
    }
}
