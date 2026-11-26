// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! `airi-channel` — the AIRI gateway channel server for the desktop app.
//!
//! A local WebSocket server on port **6121** (override with
//! `SERVER_CHANNEL_PORT` via the daemon) implementing the
//! auth-token handshake from the `airi-gateway-websocket-protocol` skill:
//!
//! 1. Waits for an HTTP `Upgrade: websocket` on a raw TCP socket.
//! 2. Speaks just enough WebSocket (text frames, close, ping/pong) for a
//!    gateway — optional `wss://` via a local CA (see [`certs`]), no extensions or subprotocols.
//! 3. Requires the client's **first message to authenticate** with the
//!    `authToken` from `<data>/airi-slint/server-channel/config.json`.
//!    Unauthenticated peers receive nothing else and are closed with 1008.
//! 4. After auth: `ping` → `pong` (plus the server-runtime
//!    `transport:connection:heartbeat` mirror), and a typed `rpc` dispatch
//!    registry (`runtime.ping`, `runtime.status`, `gateway.config`,
//!    `gateway.auth`, plus `event.subscribe` / `event.unsubscribe`) with stable
//!    `rpc_*` error codes. See [`dispatch`]. Unknown types get a typed `error`
//!    frame.
//! 5. After auth, the gateway can also **push** server-initiated `event` frames
//!    (`lip_sync.rms`, `emotion.tag`, `token.delta`, `presence.changed`,
//!    `status.changed`) to clients that opted in. See the ADR in [`wire`] and
//!    the bounded fan-out in [`event_bus`]. Events are one-way: producers
//!    publish through [`EventBus`], never by writing to a client socket.
//!
//! ## Client connection contract
//!
//! Endpoint `ws://127.0.0.1:6121` (loopback default), path `/ws`; protocol
//! literal `airi-channel/1`.
//! - First frame must be JSON auth: `{"type":"auth","authToken":"<uuid-v4>"}`.
//! - Success replies `{"type":"auth","ok":true}`; failure is a typed error
//!   frame followed by close 1008.
//! - Config path (auto-healed, mode 0600): XDG `$XDG_DATA_HOME/airi-slint/server-channel/config.json`
//!   (Linux), `~/Library/Application Support/airi-slint/server-channel/config.json`
//!   (macOS), `%APPDATA%\airi-slint\server-channel\config.json` (Windows);
//!   override via `AIRI_SERVER_CHANNEL_CONFIG`. Exposed over D-Bus as
//!   `GetGatewayConfig`.
//! - Wire names are camelCase with named fields `authToken`, `uptimeSeconds`,
//!   `sessionStartedMs`.
//! - Beyond loopback: `wss://` with the locally minted CA; never disable
//!   verification.
//! - Reconnect is owned by clients; auth failures are terminal; token rotation
//!   does not force-close existing sessions.
//! - Helpers `daemon_connect` / `daemon_connect_with_ca`; `fromUri` (Dart)
//!   exist so each client constructs its own transport.
//! - Client conformance: Rust drift check and Flutter `dart test`.
//!
//! ## Security posture (read before enabling on a network)
//!
//! - **TLS is supported, not automatic.** With a `tlsConfig` flag in the
//!   loaded config the daemon mints (or loads) a local CA + SAN-covered
//!   server cert via [`certs`] and serves `wss://`; clients must trust the
//!   CA (`websocket-ca-cert.pem`). Without the flag the listener speaks
//!   plaintext — acceptable only on loopback. Remote (LAN/VPN/tailnet)
//!   exposure should enable TLS, and public-internet exposure needs
//!   per-client tokens, which do not exist yet.
//! - **Loopback-only by default.** The healed config binds `127.0.0.1`.
//!   Binding `0.0.0.0` for LAN clients is possible but is plaintext over the
//!   LAN and MUST be weighed against the mkcert-less posture — do not do it
//!   casually.
//! - **Token in plaintext config.** `server-channel/config.json` holds the
//!   `authToken` in clear text, exactly like the Electron build's
//!   `createConfig('server-channel', 'config.json', …)`. File permissions on
//!   the data dir are the only protection; protect them.
//! - **Auto-heal.** Missing/invalid config → a fresh UUIDv4 token is
//!   generated and the file is rewritten (same contract as `autoHeal: true`
//!   upstream). Clients must re-read or re-pair after a regeneration.
//! - **No origin validation.** Any local process (or, if bound to LAN, any
//!   host) can attempt the handshake; possession of the token is the only
//!   gate. Origin checking is deferred — see the phase note.
//! - **No rate limiting / brute-force protection** on the token. Loopback
//!   exposure makes online guessing impractical only for high-entropy
//!   tokens; tokens are UUIDv4 (122 bits), which is the mitigation.
//! - Token comparison avoids early-exit timing leaks on content (length is
//!   compared first, which is acceptable for fixed-shape UUIDs).
//!
//! ## What this is not (yet)
//!
//! Not a general-purpose RPC bridge, not a module registry, not audio
//! streaming, not LAN discovery. The `rpc` registry is a small, fully local
//! slice of the gateway protocol. `renderer.*` methods dispatch to
//! embedder-registered [`RendererHandlers`] (read-only, plain-JSON handlers
//! registered via [`ChannelServer::bind_with_renderer`]); unregistered
//! methods reply `rpc_not_implemented`. Wiring it into GUI-thread targets into
//! that registry is a separate decision — handlers here must never touch
//! `QObject`s directly; they get plain JSON and return plain JSON.

pub mod asset;
pub mod audit;
pub mod base64;
pub mod certs;
pub mod client;
pub mod config;
pub mod control;
pub mod dispatch;
pub mod event_bus;
pub mod provider;
pub mod server;
pub mod session;
pub mod sha1;
pub mod uuid;
pub mod wire;
pub mod ws;

pub use certs::{
    ca_cert_pem, certs_exist, get_or_create_certs, san_domains, server_config as tls_server_config,
    CertBundle, CertsError,
};
pub use client::{daemon_connect, daemon_connect_with_ca};
pub use client::{GatewayClient, GatewayClientError};
pub use config::{default_config_path, load_or_heal, ChannelConfig, ConfigError, DEFAULT_HOSTNAME};
pub use control::{GatewayControlApply, GatewayControlStatus};
pub use dispatch::{
    RendererHandler, RendererHandlers, RpcContext, RpcError, RpcRegistry, APP_NAME, PROTOCOL,
};
pub use event_bus::{EventBus, EventLane, DEFAULT_EVENT_POLL_INTERVAL, DEFAULT_LANE_CAPACITY};
pub use server::{ChannelServer, ServerHandle, HANDLER_DEADLINE};
pub use session::{CloseInfo, Session, SessionOutcome, SessionState, CLOSE_POLICY_VIOLATION};
pub use wire::{
    AuthenticatedData, CapabilitiesReply, CardInfo, CardMetadataReply, CardMetadataSetRequest,
    ChatMessage, CoreStatusReply, CueKind, EmotionTagData, EventPayload, EventSubscriptionReply,
    EventTopic, GatewayAuthReply, GatewayClientFrame, GatewayConfigReply, GatewayEvent,
    GatewayServerFrame, HeartbeatData, HeartbeatKind, JournalEntry, LipSyncRmsData, ModuleAuthData,
    PresenceChangedData, RpcErrorObject, RuntimePingReply, RuntimeStatusReply, SessionExportReply,
    SessionImportReply, SessionInfo, SettingsChangedData, StatusChangedData, StmmSummary,
    TokenDeltaData, CANONICAL_EMOTION_KEYS,
};
pub use ws::{accept_key, encode_frame, Frame, FrameDecoder, OP_CLOSE, OP_PING, OP_PONG, OP_TEXT};

/// Default channel-server port (`SERVER_CHANNEL_PORT` overrides).
pub const DEFAULT_PORT: u16 = 6121;

/// Install the rustls `aws-lc-rs` CryptoProvider as the process-wide default.
///
/// The unified workspace build enables both `ring` (via `quinn-proto`) and
/// `aws-lc-rs` (rustls' default) providers, and rustls panics on every TLS-building
/// call until one is chosen. Binaries and TLS-touching tests call
/// this once at startup.
pub fn install_default_crypto_provider() {
    let _ = rustls::crypto::aws_lc_rs::default_provider().install_default();
}
