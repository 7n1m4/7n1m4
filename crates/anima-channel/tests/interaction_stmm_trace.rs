// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust leg of the shared STMM authority trace (v24b).
//!
//! Replays the eight-frame `stmm.list -> stmm.upsert -> stmm.delete ->
//! stmm.list` trace through the real channel wire DTOs. This is a wire-trace
//! conformance test, not a daemon handler test: no gateway socket is bound and
//! no store is opened.
//!
//! ```sh
//! cargo test -p anima-channel interaction_stmm_trace
//! ```

use anima_channel::wire::{GatewayClientFrame, GatewayServerFrame, StmmSummary};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

fn fixture_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("fixtures/golden/trace.stmm.authority.json")
}

fn load_fixture() -> Value {
    let path = fixture_path();
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()))
}

/// Decode a request frame through the real client wire enum.
fn request(frame: &Value) -> (String, Option<Value>, Option<Value>) {
    let decoded: GatewayClientFrame = serde_json::from_value(frame.clone())
        .unwrap_or_else(|e| panic!("not a client wire frame: {e}: {frame}"));
    match decoded {
        GatewayClientFrame::Rpc {
            action,
            payload,
            id,
        } => (action, payload, id),
        other => panic!("expected an rpc request, got {other:?}"),
    }
}

/// Decode a reply frame through the real server wire enum.
fn reply(frame: &Value) -> (String, bool, Option<Value>, Option<Value>) {
    let decoded: GatewayServerFrame = serde_json::from_value(frame.clone())
        .unwrap_or_else(|e| panic!("not a server wire frame: {e}: {frame}"));
    match decoded {
        GatewayServerFrame::Rpc {
            action,
            ok,
            data,
            error,
            id,
        } => {
            assert!(error.is_none(), "trace replies must be successful: {frame}");
            (action, ok, data, id)
        }
        other => panic!("expected an rpc reply, got {other:?}"),
    }
}

fn data_field<'a>(reply_data: &'a Option<Value>, key: &str) -> &'a Value {
    reply_data
        .as_ref()
        .and_then(|v| v.get(key))
        .unwrap_or_else(|| panic!("reply data has no `{key}`"))
}

#[test]
fn interaction_stmm_trace_matches_shared_fixture() {
    let fixture = load_fixture();
    assert_eq!(fixture["schema"], "airi-channel-trace-v1");
    assert_eq!(fixture["path"], "stmm.list/upsert/delete");

    let frames = fixture["frames"]
        .as_array()
        .expect("trace fixture: `frames` must be an array");
    assert_eq!(frames.len(), 8, "trace must hold exactly 8 frames");

    let ids = ["m1", "m1", "m2", "m2", "m3", "m3", "m4", "m4"];
    for (i, frame) in frames.iter().enumerate() {
        assert_eq!(frame["id"], ids[i], "frame {i} id passthrough");
    }

    // Frames 0/1: list request m1 -> the daemon-authoritative row.
    let (action, payload, id) = request(&frames[0]);
    assert_eq!(action, "stmm.list");
    assert_eq!(payload, Some(json!({ "limit": 50 })));
    assert_eq!(id, Some(json!("m1")));

    let (action, ok, reply_data, reply_id) = reply(&frames[1]);
    assert_eq!(action, "stmm.list");
    assert!(ok, "frame 1 must be a successful reply");
    assert_eq!(reply_id, id, "rpc id must pass through verbatim");
    let summaries = data_field(&reply_data, "summaries")
        .as_array()
        .expect("summaries must be an array");
    assert_eq!(summaries.len(), 1, "the daemon row is authoritative");
    let summary: StmmSummary = serde_json::from_value(summaries[0].clone())
        .expect("listed row must deserialize into the real StmmSummary DTO");
    assert_eq!(summary.id, "summary-1");
    assert_eq!(summary.day, "2026-11-25");
    assert_eq!(summary.content, "A summary");
    assert_eq!(summary.token_estimate, 3);
    assert_eq!(summary.source_session_ids, vec!["s1".to_string()]);
    assert_eq!(summary.created_at, 1_764_000_000_000_000);
    // The daemon row is snake_case (StoredSummary serde); the upsert input
    // below is camelCase. Both shapes are locked so the seam cannot drift.
    assert_eq!(serde_json::to_value(&summary).unwrap(), summaries[0]);

    // Frames 2/3: upsert request m2 -> the daemon's written count.
    let (action, payload, id) = request(&frames[2]);
    assert_eq!(action, "stmm.upsert");
    assert_eq!(id, Some(json!("m2")));
    let blocks = payload
        .as_ref()
        .and_then(|p| p.get("blocks"))
        .and_then(Value::as_array)
        .expect("blocks must be an array");
    assert_eq!(blocks.len(), 1);
    assert_eq!(
        blocks[0],
        json!({
            "id": "summary-1",
            "day": "2026-11-25",
            "content": "A summary",
            "tokenEstimate": 3,
            "sourceSessionIds": ["s1"],
            "createdAt": 1_764_000_000_000_000i64,
        })
    );

    let (action, ok, reply_data, reply_id) = reply(&frames[3]);
    assert_eq!(action, "stmm.upsert");
    assert!(ok);
    assert_eq!(reply_id, Some(json!("m2")));
    assert_eq!(data_field(&reply_data, "upserted"), &json!(1));

    // Frames 4/5: delete request m3 -> `deleted: true`.
    let (action, payload, id) = request(&frames[4]);
    assert_eq!(action, "stmm.delete");
    assert_eq!(payload, Some(json!({ "id": "summary-1" })));
    assert_eq!(id, Some(json!("m3")));

    let (action, ok, reply_data, reply_id) = reply(&frames[5]);
    assert_eq!(action, "stmm.delete");
    assert!(ok);
    assert_eq!(reply_id, Some(json!("m3")));
    assert_eq!(data_field(&reply_data, "deleted"), &json!(true));

    // Frames 6/7: re-list m4 -> empty, so the deleted row cannot resurrect.
    let (action, payload, id) = request(&frames[6]);
    assert_eq!(action, "stmm.list");
    assert_eq!(payload, Some(json!({ "limit": 50 })));
    assert_eq!(id, Some(json!("m4")));

    let (action, ok, reply_data, reply_id) = reply(&frames[7]);
    assert_eq!(action, "stmm.list");
    assert!(ok);
    assert_eq!(reply_id, Some(json!("m4")));
    let final_summaries = data_field(&reply_data, "summaries")
        .as_array()
        .expect("summaries must be an array");
    assert!(final_summaries.is_empty(), "no resurrect after delete");
}
