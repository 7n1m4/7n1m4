// SPDX-License-Identifier: GPL-3.0-or-later
//! Logging setup for anima-supervisor.
//!
//! The supervisor writes structured JSON logs to stderr/journal only
//! (systemd `StandardOutput=journal`). It owns **no** audit log and performs
//! **no** retention: audit ownership and the `.cleared-*` archive retention
//! policy live with `anima-daemon` (see
//! `docs/decision-audit-archive-retention.md`). Retention level is controlled
//! via `RUST_LOG`.

use tracing_subscriber::layer::SubscriberExt;
use tracing_subscriber::util::SubscriberInitExt;
use tracing_subscriber::{EnvFilter, fmt};

/// Initialise the global tracing subscriber. Safe to call once at process start.
pub fn init() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info"));
    let _ = tracing_subscriber::registry()
        .with(filter)
        .with(fmt::layer().json())
        .try_init();
}
