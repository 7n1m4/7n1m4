// SPDX-License-Identifier: GPL-3.0-or-later
//! Round v32 real-execution proof of `display-model.resolve` against the new
//! additive trace golden `trace.display.model.resolve.json`.
//!
//! Declared only from `main.rs` (bin test target), so `crate::events` and
//! `crate::gateway` resolve here. The v27-v31 DIRECT pattern is used: an
//! explicit tempdir `ChannelConfig` with `allowActions: true` feeds
//! `Gateway::renderer_handlers` with a real `CoreService` + `EventPublisher`.
//! No process-global `AIRI_SERVER_CHANNEL_CONFIG` is read.
//!
//! The catalog is seeded through the REAL gated `settings.set` handler. The
//! descriptor carries a host-derived `file` path and a non-sentinel `url`; the
//! raw wire reply is checked for exact keys and for secret/timestamp/path-key
//! leakage BEFORE those two path-bearing values are projected onto the golden
//! sentinels. The unknown-id branch is exercised through the same real handler.

use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use serde_json::{json, Value};

use crate::core::CoreService;
use crate::events::EventPublisher;
use crate::gateway::Gateway;

fn keys(value: &Value) -> BTreeSet<&str> {
    value
        .as_object()
        .expect("JSON object")
        .keys()
        .map(String::as_str)
        .collect()
}

fn collect_keys(value: &Value, out: &mut BTreeSet<String>) {
    match value {
        Value::Object(map) => {
            for (key, child) in map {
                out.insert(key.clone());
                collect_keys(child, out);
            }
        }
        Value::Array(items) => {
            for child in items {
                collect_keys(child, out);
            }
        }
        _ => {}
    }
}

/// Read the additive golden verbatim; never restate it in this test.
fn load_golden(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/golden")
        .join(name);
    let text = fs::read_to_string(&path).unwrap_or_else(|e| panic!("read {}: {e}", path.display()));
    serde_json::from_str(&text).unwrap_or_else(|e| panic!("parse {}: {e}", path.display()))
}

fn body(fixture: &Value, index: usize, key: &str) -> Value {
    let object = fixture["frames"][index][key]
        .as_object()
        .unwrap_or_else(|| panic!("frame {index} has no object `{key}`"));
    Value::Object(object.clone())
}

#[test]
fn display_model_resolve_golden_execution_replays_through_real_handler() {
    let golden = load_golden("trace.display.model.resolve.json");
    assert_eq!(golden["schema"], "airi-channel-trace-v1");
    let frames = golden["frames"].as_array().expect("frames array");
    assert!(frames.len() >= 10, "trace must carry all ten frames");

    let settings_payload = body(&golden, 2, "payload");
    let resolve_payload = body(&golden, 4, "payload");
    let golden_descriptor = body(&golden, 5, "data");
    let unknown_payload = body(&golden, 6, "payload");
    let golden_error = body(&golden, 7, "error");

    // Exact camelCase key-set oracle on the golden descriptor; drift in the
    // additive fixture fails here instead of silently ratcheting.
    let descriptor_keys = ["file", "format", "id", "name", "source", "url"]
        .into_iter()
        .collect::<BTreeSet<_>>();
    assert_eq!(keys(&golden_descriptor), descriptor_keys);

    let mut golden_keys = BTreeSet::new();
    collect_keys(&golden_descriptor, &mut golden_keys);
    for forbidden in [
        "apiKey",
        "api_key",
        "secret",
        "token",
        "authToken",
        "password",
        "credential",
        "authorization",
        "ciphertext",
        "createdAt",
        "updatedAt",
        "timestamp",
    ] {
        assert!(
            !golden_keys
                .iter()
                .any(|key| key.eq_ignore_ascii_case(forbidden)),
            "golden descriptor must not carry `{forbidden}`"
        );
    }

    // Explicit tempdir config with allowActions: true and a real core; no
    // process-global config path is read on this path.
    let tmp = tempfile::tempdir().expect("display model tempdir");
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

    // Seed the catalog through the real gated handler. Host-derived file/url
    // values make the later projection non-tautological.
    let real_file = tmp
        .path()
        .join("models/v32-live2d.zip")
        .to_string_lossy()
        .into_owned();
    let real_url = "https://models.v32.invalid/live2d.zip".to_string();
    let mut seed = settings_payload.clone();
    seed["settings"]["catalog"][0]["file"] = json!(real_file);
    seed["settings"]["catalog"][0]["url"] = json!(real_url);
    let set_reply = handlers
        .get("settings.set")
        .expect("settings.set registered")("settings.set", &seed)
    .expect("real gated settings.set must ack");
    assert!(
        set_reply.is_object(),
        "settings.set must return a JSON object"
    );

    // `display-model.resolve` is UNGATED; it reads the real persisted section.
    let reply: Value = handlers
        .get("display-model.resolve")
        .expect("display-model.resolve registered")(
        "display-model.resolve", &resolve_payload
    )
    .expect("real display-model.resolve must ack");

    // Pre-projection invariants on the RAW wire reply.
    assert_eq!(keys(&reply), descriptor_keys);
    let mut reply_keys = BTreeSet::new();
    collect_keys(&reply, &mut reply_keys);
    for forbidden in [
        "apiKey",
        "api_key",
        "secret",
        "token",
        "authToken",
        "password",
        "credential",
        "authorization",
        "ciphertext",
        "createdAt",
        "updatedAt",
        "timestamp",
        "tsMs",
        "path",
        "directory",
        "homeDir",
    ] {
        assert!(
            !reply_keys
                .iter()
                .any(|key| key.eq_ignore_ascii_case(forbidden)),
            "display-model.resolve must never carry `{forbidden}`"
        );
    }
    assert_eq!(reply["id"], golden_descriptor["id"]);
    assert_eq!(reply["name"], golden_descriptor["name"]);
    assert_eq!(reply["format"], golden_descriptor["format"]);
    assert_eq!(reply["source"], golden_descriptor["source"]);
    assert!(
        !reply["id"].as_str().unwrap_or("").is_empty(),
        "id must be non-empty"
    );
    assert!(
        !reply["name"].as_str().unwrap_or("").is_empty(),
        "name must be non-empty"
    );
    assert_eq!(reply["file"].as_str(), Some(real_file.as_str()));
    assert_eq!(reply["url"].as_str(), Some(real_url.as_str()));
    assert_ne!(
        reply["file"], golden_descriptor["file"],
        "projection must be meaningful: real file differs from sentinel"
    );
    assert_ne!(
        reply["url"], golden_descriptor["url"],
        "projection must be meaningful: real url differs from sentinel"
    );

    // Only the two path-bearing leaves are normalized onto golden sentinels.
    let mut projected = reply.clone();
    projected["file"] = golden_descriptor["file"].clone();
    projected["url"] = golden_descriptor["url"].clone();
    assert_eq!(
        projected, golden_descriptor,
        "real reply equals the unchanged golden after path projection"
    );

    // Unknown id: a typed error, never a fabricated descriptor.
    let err = handlers
        .get("display-model.resolve")
        .expect("display-model.resolve registered")(
        "display-model.resolve", &unknown_payload
    )
    .expect_err("unknown id must fail");
    assert!(err.contains("unknown display model id"));
    assert!(
        err.contains(
            golden_error["message"]
                .as_str()
                .expect("golden error message")
        ),
        "real error must match the golden message"
    );
    assert!(!err.contains(&real_file), "error must not leak a path");
}
