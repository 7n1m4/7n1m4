// SPDX-License-Identifier: GPL-3.0-or-later
//! Logging setup for anima-daemon.
//!
//! Mirrors `anima-supervisor`'s pattern: structured JSON logs to
//! stderr/journal only (systemd `StandardOutput=journal`), level controlled
//! via `RUST_LOG` (default `info`). The daemon owns the redacted audit JSONL
//! and its retention; this subscriber is only for operational `tracing`
//! events (gateway lifecycle, warnings) so they are visible in the journal.

use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{fmt, EnvFilter};

/// Initialise the global tracing subscriber. Safe to call once at process start.
pub fn init() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().json())
        .try_init();
}