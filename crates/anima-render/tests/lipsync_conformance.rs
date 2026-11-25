// SPDX-License-Identifier: GPL-3.0-or-later

//! Rust leg of the lip-sync smoothing conformance fixture. The same JSON
//! drives the Godot `LipSyncSmoother`, so both renderers must produce the
//! exact f32 weights recorded here.
//!
//! ```sh
//! cargo test -p anima-render --locked --test lipsync_conformance
//! ```

use anima_render::vrm::lipsync::LipSync;
use serde::Deserialize;
use std::path::Path;

#[derive(Debug, Deserialize)]
struct Fixture {
    schema: String,
    decay_seconds: f32,
    steps: Vec<Step>,
}

#[derive(Debug, Deserialize)]
struct Step {
    rms: f32,
    dt: f32,
    expected_weight: f32,
}

#[test]
fn rust_smoothing_matches_shared_fixture() {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../anima-channel/fixtures/lipsync/smoothing.basic.json");
    let text = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("cannot read {}: {e}", path.display()));
    let fixture: Fixture = serde_json::from_str(&text)
        .unwrap_or_else(|e| panic!("invalid JSON in {}: {e}", path.display()));
    assert_eq!(fixture.schema, "lipsync-smoothing-v1");
    assert_eq!(fixture.decay_seconds, 0.120);

    let mut smoother = LipSync::new();
    for (i, step) in fixture.steps.iter().enumerate() {
        smoother.set_rms(step.rms);
        let weight = smoother.tick(step.dt);
        assert_eq!(
            weight.to_bits(),
            step.expected_weight.to_bits(),
            "step {i} ({:?}) weight mismatch",
            step
        );
        assert_eq!(smoother.weight().to_bits(), weight.to_bits(), "step {i}");
    }
}
