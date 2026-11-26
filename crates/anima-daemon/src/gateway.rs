// SPDX-License-Identifier: GPL-3.0-or-later

//! Gateway hosting: the `airi-channel` WebSocket gateway, served from the
//! always-on daemon instead of the desktop app.
//!
//! ## Topology (see `docs/design-daemon-gateway.md`)
//!
//! ```text
//!   external clients ─── ws(s)://[hostname]:6121 ───▶ airi-daemon
//!                                                       │  org.moeru.airi.Daemon1 (control)
//!                                                       ▼
//!                                               D-Bus methods GetGatewayConfig /
//!                                               ApplyGatewayConfig / RegenerateGatewayToken
//! ```
//!
//! The gateway binds `<hostname>:<port>` (default loopback, port from
//! `SERVER_CHANNEL_PORT`, falling back to 6121). With a `tlsConfig` flag in
//! the config it serves `wss://` using a locally minted CA + SAN-covered
//! certificate (see [`anima_channel::certs`]) — required for anything beyond
//! loopback (LAN/VPN/tailnet). A public-internet relay with per-client
//! tokens does not exist yet; do not expose this to the open internet.
//!
//! ## Config adoption (upgrading from the in-app server)
//!
//! The Electrobun/Electron desktop app kept its gateway config at
//! `<userData>/server-channel-config.json`. On first start the daemon adopts
//! the newest matching file into its own daemon-owned path
//! (`<data>/airi-slint/server-channel/config.json`), preserving the
//! `authToken` so previously paired devices keep working. The daemon-owned
//! copy is authoritative from then on; the app's settings UI is expected to
//! talk to the daemon via D-Bus (`ApplyGatewayConfig`) instead of editing
//! files directly.
//!
//! `AIRI_SERVER_CHANNEL_CONFIG=<path>` overrides everything and is used
//! write-through (the daemon edits the file in place), so app and daemon
//! never diverge when both are pointed at it.
//!
//! ## Port contention during transition
//!
//! Until the desktop app stops hosting its own in-app server (it will once
//! the renderer is re-backed to D-Bus), exactly one of them can bind 6121.
//! The daemon retries every 15 s and reports `bound: false` + `lastError`
//! through `GetGatewayConfig` in the meantime; awareness functions are
//! unaffected either way.

use crate::core::CoreService;
use crate::events::EventPublisher;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use anima_channel::{
    get_or_create_certs, load_or_heal, san_domains, uuid::uuid_v4, ChannelConfig, ChannelServer,
    GatewayControlApply, GatewayControlStatus, ServerHandle,
};

/// How often the daemon re-tries a failed bind (e.g. while the desktop app
/// still holds the port).
const RETRY_INTERVAL: Duration = Duration::from_secs(15);

/// Hard ceiling for client-supplied `limit` in list/search RPCs. Without it a
/// single RPC can ask the store for `usize::MAX` rows (the store converts with
/// `i64::try_from(limit).unwrap_or(i64::MAX)`), i.e. an unbounded table scan.
const RPC_MAX_LIMIT: usize = 500;
/// Hard ceiling on rows the in-daemon journal search is willing to scan.
/// `JournalRepo` has no query pushdown yet; see the store-side follow-up.
const JOURNAL_SEARCH_SCAN_CAP: usize = 100_000;
/// Hard ceiling on the total `content` bytes one in-daemon journal search
/// pulls into memory. The scan is row-bounded by
/// [`JOURNAL_SEARCH_SCAN_CAP`] and byte-bounded here, so a handful of huge
/// entries cannot turn the search into an unbounded allocation.
const JOURNAL_SEARCH_MAX_SCAN_BYTES: u64 = 8 * 1024 * 1024;
/// Default page size for list RPCs that take a client `limit`
/// (`sessions.list` today), clamped by [`RPC_MAX_LIMIT`].
const DEFAULT_LIST_LIMIT: usize = 50;
/// Hard cap on the number of blocks a single `stmm.upsert` RPC may carry.
const STMM_UPSERT_MAX_BLOCKS: usize = 100;
/// Hard cap on the byte size of a single block's `content` field.
const STMM_UPSERT_MAX_CONTENT_BYTES: usize = 64 * 1024;
/// Hard cap on the byte size of a block's `id` field.
const STMM_UPSERT_MAX_ID_BYTES: usize = 256;
/// Hard cap on the number of source session ids a single block may carry.
const STMM_UPSERT_MAX_SOURCE_SESSION_IDS: usize = 32;

/// Prefix recognized by `anima-channel`'s RPC dispatch as `rpc_actions_disabled`.
pub(crate) const ACTIONS_DISABLED_PREFIX: &str = "actions-disabled";

/// Hard cap on a single MCP tool call or short ACP RPC, independent of any
/// client-supplied `timeout`. Keeps a hung tool server from holding an RPC
/// handler thread. ACP prompts use `ACP_PROMPT_DEADLINE` instead: a real LLM
/// turn can take minutes (client default 300 s).
const MCP_ACP_DEADLINE: Duration = Duration::from_secs(30);
const ACP_PROMPT_DEADLINE: Duration = Duration::from_secs(320);

/// Run an MCP/ACP handler under a mandatory server-side deadline.
/// `anima-channel` already runs every registered handler off the connection
/// reader; this second bound ensures direct callers cannot wait forever.
fn with_mcp_acp_deadline<F>(deadline: Duration, f: F) -> Result<serde_json::Value, String>
where
    F: FnOnce() -> Result<serde_json::Value, String> + Send + 'static,
{
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("airi-daemon-mcp-acp".to_string())
        .spawn(move || {
            let _ = tx.send(f());
        })
        .map_err(|e| format!("failed to start MCP/ACP handler: {e}"))?;
    match rx.recv_timeout(deadline) {
        Ok(result) => result,
        Err(std::sync::mpsc::RecvTimeoutError::Timeout) => Err(format!(
            "MCP/ACP handler exceeded {deadline:?} server deadline"
        )),
        Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => {
            Err("MCP/ACP handler worker died".to_string())
        }
    }
}

/// Clamp a client-supplied timeout to the server deadline.
fn rpc_deadline(value: &serde_json::Value) -> Duration {
    value
        .get("timeout")
        .and_then(|v| v.as_u64())
        .map(Duration::from_secs)
        .unwrap_or(Duration::from_secs(5))
        .min(MCP_ACP_DEADLINE)
}

/// Client-supplied ACP prompt timeout, bounded by the server deadline.
fn acp_prompt_deadline(value: &serde_json::Value) -> Duration {
    value
        .get("prompt_timeout")
        .and_then(|v| v.as_u64())
        .map(Duration::from_secs)
        .unwrap_or(anima_acp::DEFAULT_PROMPT_TIMEOUT)
        .min(ACP_PROMPT_DEADLINE)
}

/// Per-call check for mutating-verb opt-ins in `config.json`.
///
/// Reads the file on every call so a live disable takes effect immediately.
/// Requires literal JSON `true` for `allowActions`; missing file/key, wrong
/// type, and invalid JSON all fail closed. Loopback binds need no second
/// flag. Non-loopback binds (LAN/VPN/tailnet) additionally require literal
/// JSON `true` for `allowRemoteActions`: a remote client is trusted for
/// mutating verbs only when a local operator has explicitly opted in on that
/// bind. Authentication is separate — the shared `authToken` still gates the
/// connection — and this flag alone does not authorize internet exposure
/// (see `docs/decision-remote-client-trust.md`). Error text names flags and
/// the config path, never credentials.
fn require_actions(config_path: &Path, hostname: &str) -> Result<(), String> {
    let value = fs::read_to_string(config_path)
        .ok()
        .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok());
    let enabled = value
        .as_ref()
        .and_then(|v| v.get("allowActions"))
        .and_then(serde_json::Value::as_bool)
        .unwrap_or(false);
    if !enabled {
        return Err(format!(
            "{ACTIONS_DISABLED_PREFIX}: gateway actions are off; set \"allowActions\": true in {}",
            config_path.display()
        ));
    }
    if !is_loopback_hostname(hostname) {
        let remote_enabled = value
            .as_ref()
            .and_then(|v| v.get("allowRemoteActions"))
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false);
        if !remote_enabled {
            return Err(format!(
                "{ACTIONS_DISABLED_PREFIX}: gateway actions require \"allowRemoteActions\": true for a non-loopback hostname in {}",
                config_path.display()
            ));
        }
    }
    Ok(())
}

/// Receive the next chat event, transparently recovering from a lagged
/// broadcast receiver. `Lagged` means the bounded bus dropped events while we
/// were behind — not that the stream ended. Only `Closed` terminates it.
async fn recv_chat_event(
    rx: &mut tokio::sync::broadcast::Receiver<anima_core::chat::ChatEvent>,
) -> Option<anima_core::chat::ChatEvent> {
    loop {
        match rx.recv().await {
            Ok(ev) => return Some(ev),
            Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
            Err(tokio::sync::broadcast::error::RecvError::Closed) => return None,
        }
    }
}

/// Session id carried by a chat event. The `ChatService` bus is shared by
/// every turn, so each pump must drop events that belong to another session.
fn chat_event_session(ev: &anima_core::chat::ChatEvent) -> &str {
    use anima_core::chat::ChatEvent;
    match ev {
        ChatEvent::Delta { session, .. }
        | ChatEvent::MessageDone { session, .. }
        | ChatEvent::StatusChanged { session, .. }
        | ChatEvent::Error { session, .. } => session,
    }
}

const SERVER_CHANNEL_DIR: &str = "server-channel";
const CERTS_DIR: &str = "certs";
const CONFIG_FILE: &str = "config.json";

/// A D-Bus caller's request (kept pure so tests can drive it without a bus).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum GatewayRequest {
    /// Read the effective config + listener state. Never logs credentials.
    Get,
    /// Apply a config patch (raw JSON object string, Electron handler shape:
    /// `{ websocketTlsConfig?: {} | null, authToken?, hostname? }`; the legacy
    /// `tlsConfig` spelling for the TLS flag is also accepted).
    Apply(String),
    /// Rotate the shared auth token; affects new connections (existing
    /// sessions are not force-closed, matching the in-app server).
    RegenerateToken,
}

struct Inner {
    hostname: String,
    auth_token: String,
    /// The persisted/user-configured TLS flag (`tlsConfig` in the file).
    tls_flag: bool,
    /// The transport actually bound: `tls_flag || !loopback(hostname)`.
    bound_tls: bool,
    bound: bool,
    last_error: Option<String>,
    adopted_from: Option<PathBuf>,
    server: Option<ServerHandle>,
    last_attempt: Instant,
}

/// The daemon's gateway state. Owns the listener handle (if any) and the
/// effective config; D-Bus handlers read/mutate it under a mutex.
pub struct Gateway {
    config_path: PathBuf,
    cert_dir: PathBuf,
    /// Explicit bind port, or `None` to use `SERVER_CHANNEL_PORT`/6121.
    /// Tests pass `Some(0)` for an ephemeral port.
    port_override: Option<u16>,
    inner: Mutex<Inner>,
    core: CoreService,
    /// The one bus shared by every bind (including retries/rebinds) and every
    /// D-Bus handler. Created once here so captures never go stale on rebind.
    publisher: EventPublisher,
}

impl Gateway {
    /// Start the gateway, adopting/healing config as documented. Never
    /// panics: every failure is captured into `bound: false` + `last_error`
    /// and reported via `GetGatewayConfig`.
    pub fn start() -> Self {
        Self::start_with(port_from_env(), None)
    }

    /// Same as [`Gateway::start`] with an explicit port (tests use `Some(0)`).
    pub fn start_with(port_override: Option<u16>, adopt_from: Option<PathBuf>) -> Self {
        Self::start_with_core(port_override, adopt_from, CoreService::open(None))
    }

    pub fn start_with_core(
        port_override: Option<u16>,
        adopt_from: Option<PathBuf>,
        core: CoreService,
    ) -> Self {
        let Some(data_dir) = dirs::data_dir() else {
            return Self::disabled_with_core(
                port_override,
                "no data dir for this platform; gateway disabled",
                core,
            );
        };
        Self::start_in(
            data_dir.join("airi-slint").join(SERVER_CHANNEL_DIR),
            port_override,
            adopt_from,
            core,
        )
    }

    fn start_in(
        config_dir: PathBuf,
        port_override: Option<u16>,
        adopt_from: Option<PathBuf>,
        core: CoreService,
    ) -> Self {
        let config_path = config_dir.join(CONFIG_FILE);
        let cert_dir = config_dir.join(CERTS_DIR);

        // 1. Explicit override path: write through, never copy.
        let explicit = std::env::var("AIRI_SERVER_CHANNEL_CONFIG")
            .ok()
            .map(PathBuf::from);
        let (config_path, adopted_from) = match explicit {
            Some(path) => (path, None),
            None => match adopt_from {
                Some(source) => adopt(&source, &config_path).map_or_else(
                    |err| {
                        eprintln!("airi-daemon: gateway config adoption from {} failed: {err}; minting fresh", source.display());
                        (config_path.clone(), None)
                    },
                    |source| (config_path.clone(), Some(source)),
                ),
                None => {
                    if config_path.exists() {
                        (config_path.clone(), None)
                    } else {
                        match find_adoptable() {
                            Some(source) => adopt(&source, &config_path).map_or_else(
                                |err| {
                                    eprintln!("airi-daemon: gateway config adoption from {} failed: {err}; minting fresh", source.display());
                                    (config_path.clone(), None)
                                },
                                |source| (config_path.clone(), Some(source)),
                            ),
                            None => (config_path.clone(), None),
                        }
                    }
                }
            },
        };

        let gateway = Self {
            config_path,
            cert_dir,
            port_override,
            core: core.clone(),
            publisher: EventPublisher::new(anima_channel::EventBus::with_defaults()),
            inner: Mutex::new(Inner {
                hostname: DEFAULT_HOSTNAME_PLACEHOLDER.to_string(),
                auth_token: String::new(),
                tls_flag: false,
                bound_tls: false,
                bound: false,
                last_error: None,
                adopted_from,
                server: None,
                last_attempt: Instant::now() - RETRY_INTERVAL,
            }),
        };

        // Publish the initial, secret-free health snapshot once. Nothing
        // mutates core health at runtime today; the publisher dedupes further
        // repeats so `core.status` RPCs never echo an unchanged reading as a
        // fresh event. Publishing before any bind is harmless (no lanes yet).
        let reply = gateway.core.status_reply();
        gateway.publisher().status_changed(
            reply.core_available,
            reply.store_available,
            reply.store_health,
            None,
        );

        // 2. Load/heal the persisted config, then bind.
        match load_or_heal(&gateway.config_path) {
            Ok(config) => {
                if let Err(err) = validate_hostname(&config.hostname) {
                    gateway.set_error(format!("config load/heal failed: {err}"));
                    return gateway;
                }
                gateway.bind_once(&config);
                let inner = gateway.inner.lock().unwrap_or_else(|e| e.into_inner());
                if inner.bound {
                    eprintln!(
                        "airi-daemon: gateway listening on {}:{} (TLS: {})",
                        inner.hostname,
                        gateway.port(),
                        inner.bound_tls
                    );
                } else {
                    eprintln!(
                        "airi-daemon: gateway not bound ({}); will retry",
                        inner.last_error.as_deref().unwrap_or("unknown error")
                    );
                }
            }
            Err(err) => {
                gateway.set_error(format!("config load/heal failed: {err}"));
            }
        }
        gateway
    }

    /// Create a non-binding gateway that reports `bound: false` with `reason`
    /// on every D-Bus query. Used by `--no-gateway`; keeps the control
    /// interface honest while the desktop app (still) hosts the server.
    pub fn start_disabled(reason: &str) -> Self {
        Self::start_disabled_with_core(reason, CoreService::open(None))
    }

    pub fn start_disabled_with_core(reason: &str, core: CoreService) -> Self {
        Self::disabled(port_from_env(), reason, core)
    }

    fn disabled_with_core(port_override: Option<u16>, reason: &str, core: CoreService) -> Self {
        Self::disabled(port_override, reason, core)
    }

    fn disabled(port_override: Option<u16>, reason: &str, core: CoreService) -> Self {
        Self {
            config_path: PathBuf::new(),
            cert_dir: PathBuf::new(),
            port_override,
            core,
            publisher: EventPublisher::new(anima_channel::EventBus::with_defaults()),
            inner: Mutex::new(Inner {
                hostname: String::new(),
                auth_token: String::new(),
                tls_flag: false,
                bound_tls: false,
                bound: false,
                last_error: Some(reason.to_string()),
                adopted_from: None,
                server: None,
                last_attempt: Instant::now() - RETRY_INTERVAL,
            }),
        }
    }

    /// Re-attempt binding if the listener is down and the cooldown elapsed.
    /// Called from the daemon's poll loop; internally rate-limited. No-op
    /// when the gateway was never configured (`--no-gateway`).
    pub fn maybe_retry(&self) {
        if self.config_path.as_os_str().is_empty() {
            return; // disabled via --no-gateway
        }
        let do_retry = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            !inner.bound && inner.last_attempt.elapsed() >= RETRY_INTERVAL
        };
        if do_retry {
            match load_or_heal(&self.config_path) {
                Ok(config) => {
                    if let Err(err) = validate_hostname(&config.hostname) {
                        // Consume the cooldown like any other failed attempt so
                        // the poll loop does not hammer the config file.
                        self.set_error(format!("config load/heal failed: {err}"));
                    } else {
                        self.bind_once(&config);
                    }
                }
                Err(err) => {
                    // Failure must also consume the cooldown, otherwise the
                    // poll loop hammers the config file at ~50 reads/s.
                    self.set_error(format!("config load/heal failed: {err}"));
                }
            }
        }
    }

    /// Handle one D-Bus gateway request. Returns the reply payload string.
    pub fn handle(&self, request: &GatewayRequest) -> String {
        match request {
            GatewayRequest::Get => self.get_json(),
            GatewayRequest::Apply(raw) => self.apply(raw),
            GatewayRequest::RegenerateToken => self.regenerate_token(),
        }
    }

    fn get_json(&self) -> String {
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let ca_cert = self.cert_dir.join(anima_channel::certs::CA_CERT_FILE);
        serde_json::to_string(&GatewayControlStatus {
            hostname: inner.hostname.clone(),
            port: self.port(),
            tls_enabled: inner.bound_tls,
            bound: inner.bound,
            last_error: inner.last_error.clone(),
            adopted_from: inner.adopted_from.as_ref().map(|p| p.display().to_string()),
            ca_cert_path: ca_cert.is_file().then(|| ca_cert.display().to_string()),
            auth_token: inner.auth_token.clone(),
        })
        .expect("GatewayControlStatus serialization cannot fail")
    }

    fn apply(&self, raw: &str) -> String {
        let patch: GatewayControlApply = match serde_json::from_str(raw) {
            Ok(patch) => patch,
            Err(_) => {
                return serde_json::json!({ "ok": false, "error": "expected a JSON object payload" })
                    .to_string();
            }
        };

        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        let mut hostname = inner.hostname.clone();
        if let Some(h) = patch.hostname.as_deref() {
            let h = h.trim();
            if !h.is_empty() {
                hostname = h.to_string();
            }
        }

        // Reject wildcard binds before persisting: a wildcard is not a DNS
        // name and would force TLS with a cert that covers no dialable address.
        if let Err(err) = validate_hostname(&hostname) {
            let message = format!("invalid gateway hostname: {err}");
            inner.last_error = Some(message.clone());
            return serde_json::json!({ "ok": false, "error": message }).to_string();
        }

        let auth_token = match patch.auth_token.as_deref() {
            Some(t) if !t.trim().is_empty() => t.trim().to_string(),
            _ => inner.auth_token.clone(),
        };

        // `tlsConfig`/`websocketTlsConfig` are opaque flags: undefined =
        // keep, null = disable, anything else = enable (always `{}`).
        // The legacy `tlsConfig` spelling wins, as before.
        let tls_flag = patch
            .tls_config
            .as_ref()
            .or(patch.websocket_tls_config.as_ref());
        let mut tls = inner.tls_flag;
        match tls_flag {
            None => {}                                    // key absent: keep the current flag
            Some(serde_json::Value::Null) => tls = false, // explicit `null`: disable
            Some(_) => tls = true,                        // any other value: enable
        }

        // `allow_actions: None` — `persist` re-injects the live `allowActions`
        // value from the existing file, so D-Bus rewrites preserve the opt-in.
        let config = ChannelConfig {
            hostname: hostname.clone(),
            auth_token: auth_token.clone(),
            tls_config: tls.then(|| serde_json::json!({})),
            allow_actions: None,
        };
        if let Err(err) = Self::persist(&self.config_path, &config) {
            let message = format!("failed to persist gateway config: {err}");
            inner.last_error = Some(message.clone());
            return serde_json::json!({ "ok": false, "error": message }).to_string();
        }

        // Rebind with the new effective config (bind_once syncs Inner).
        drop(inner);
        self.bind_once(&config);

        // A persisted-but-unbound apply must not look like a success:
        // report ok:false with the bind error (Get's last_error unchanged).
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if !inner.bound {
            let message = inner
                .last_error
                .clone()
                .unwrap_or_else(|| "gateway did not bind with the new config".to_string());
            return serde_json::json!({ "ok": false, "error": message }).to_string();
        }

        // Reply with the transport actually bound, not the persisted flag: a
        // non-loopback hostname forces TLS on even when `tlsConfig` is unset,
        // and clients must not be pointed at `ws://` in that case.
        let bound_tls = inner.bound_tls;
        serde_json::json!({
            "websocketTlsConfig": if bound_tls { serde_json::json!({}) } else { serde_json::Value::Null },
            "authToken": auth_token,
            "hostname": hostname,
        })
        .to_string()
    }

    fn regenerate_token(&self) -> String {
        let config = {
            let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
            ChannelConfig {
                hostname: inner.hostname.clone(),
                auth_token: uuid_v4(),
                tls_config: inner.tls_flag.then(|| serde_json::json!({})),
                allow_actions: None,
            }
        };
        if let Err(err) = Self::persist(&self.config_path, &config) {
            // Keep listening with the old token on write failure; the
            // rotation did not happen and the caller gets the plain truth.
            let message = format!("failed to persist rotated token: {err}");
            self.set_error(message.clone());
            return serde_json::json!({ "ok": false, "error": message }).to_string();
        }
        // `bind_once` stops the old listener before attempting the new bind.
        // A failed rebind would otherwise leave a valid-looking token with
        // nothing listening on the port — the same trap `apply` already avoids.
        self.bind_once(&config);
        let inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        if !inner.bound {
            let message = inner
                .last_error
                .clone()
                .unwrap_or_else(|| "gateway did not bind with the rotated token".to_string());
            return serde_json::json!({ "ok": false, "error": message }).to_string();
        }
        serde_json::json!({ "authToken": config.auth_token }).to_string()
    }

    /// Clone of the process-wide gateway bus handle. Use
    /// [`Self::publisher`] for publishing; this is for diagnostics and for
    /// injecting the same bus into a bind.
    pub fn event_bus(&self) -> anima_channel::EventBus {
        self.publisher.bus().clone()
    }

    /// Clone of the publisher sharing this gateway's bus and dedupe state.
    pub fn publisher(&self) -> EventPublisher {
        self.publisher.clone()
    }

    fn port(&self) -> u16 {
        self.port_override
            .or_else(|| {
                std::env::var("SERVER_CHANNEL_PORT")
                    .ok()
                    .and_then(|v| v.parse().ok())
            })
            .unwrap_or(anima_channel::DEFAULT_PORT)
    }

    fn set_error(&self, message: String) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        inner.last_error = Some(message);
        inner.bound = false;
        inner.last_attempt = Instant::now();
    }

    /// Persist config atomically (tmp file + rename in the same directory).
    /// Written `0600`: the file carries the auth token.
    fn persist(path: &Path, config: &ChannelConfig) -> io::Result<()> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let tmp = path.with_extension("json.tmp");
        // D-Bus config rewrites must preserve the live action opt-ins:
        // `apply`/`regenerate_token` pass `allow_actions: None`, so carry the
        // current file's values forward (fail-closed if the file is gone).
        // `allowRemoteActions` is outside ChannelConfig (it is a gateway-side
        // trust flag), so it is carried here too; otherwise a token rotation
        // would silently revoke remote actions.
        let mut value = serde_json::to_value(config)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        if config.allow_actions.is_none() {
            let previous = fs::read_to_string(path)
                .ok()
                .and_then(|raw| serde_json::from_str::<serde_json::Value>(&raw).ok());
            if let Some(previous) = previous {
                for key in ["allowActions", "allowRemoteActions"] {
                    if let Some(flag) = previous.get(key).cloned() {
                        value[key] = flag;
                    }
                }
            }
        }
        let json = serde_json::to_string_pretty(&value)
            .map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
        #[cfg(unix)]
        {
            use std::io::Write as _;
            use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
            // mode(0o600) only applies at creation; a pre-existing 0644
            // tmp would survive otherwise, and rename() would then hand
            // the daemon a 0644 config.
            let mut file = fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .mode(0o600)
                .open(&tmp)?;
            file.set_permissions(fs::Permissions::from_mode(0o600))?;
            file.write_all(json.as_bytes())?;
        }
        #[cfg(not(unix))]
        {
            fs::write(&tmp, json)?;
        }
        fs::rename(&tmp, path)
    }

    /// Stop the current listener (if any) and bind a fresh one with `config`.

    pub(crate) fn renderer_handlers(
        core: &CoreService,
        publisher: &EventPublisher,
        config_path: &Path,
        hostname: &str,
    ) -> anima_channel::RendererHandlers {
        // Single coercion point from a concrete `move` closure to the boxed RPC
        // handler type. Captures and handler behavior are defined entirely by
        // the closure; this only removes the repeated `as Box<dyn Fn…>` casts.
        fn handler<F>(
            f: F,
        ) -> Box<dyn Fn(&str, &serde_json::Value) -> Result<serde_json::Value, String> + Send + Sync>
        where
            F: Fn(&str, &serde_json::Value) -> Result<serde_json::Value, String>
                + Send
                + Sync
                + 'static,
        {
            Box::new(f)
        }

        // Wrap a mutating/executing handler in a strict, live `allowActions`
        // check (plus `allowRemoteActions` on a non-loopback bind). The verb
        // stays registered so clients get a typed `rpc_actions_disabled` reply
        // instead of `rpc_unknown_method`. `hostname` is the effective bind
        // hostname captured at bind time.
        fn gated<F>(
            config_path: &Path,
            hostname: &str,
            f: F,
        ) -> Box<dyn Fn(&str, &serde_json::Value) -> Result<serde_json::Value, String> + Send + Sync>
        where
            F: Fn(&str, &serde_json::Value) -> Result<serde_json::Value, String>
                + Send
                + Sync
                + 'static,
        {
            let config_path = config_path.to_path_buf();
            let hostname = hostname.to_string();
            handler(move |method, value| {
                require_actions(&config_path, &hostname)?;
                f(method, value)
            })
        }

        // NOTICE: mutating and process-spawning verbs are gated on the strict
        // `allowActions: true` opt-in in `config.json` (fail-closed per call),
        // plus `allowRemoteActions: true` when bound beyond loopback.
        // This covers thin-client user-data writes and the MCP/ACP execution
        // surfaces. Read-only verbs stay ungated; gateway control verbs stay
        // on D-Bus only.
        let mut m = std::collections::HashMap::new();
        {
            let core = core.clone();
            let publisher = publisher.clone();
            m.insert(
                "core.status".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    if !core.available() {
                        let snap = core.snapshot();
                        let reason = snap.reason.unwrap_or_else(|| "unavailable".to_string());
                        return Err(format!("core unavailable: {reason}"));
                    }
                    let reply = core.status_reply();
                    publisher.status_changed(
                        reply.core_available,
                        reply.store_available,
                        reply.store_health.clone(),
                        None,
                    );
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "providers.list".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    let reply = core.providers_list()?;
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "providers.save".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let id = core.providers_save(value).map_err(|e| e.to_string())?;
                        // Secret-free: the apiKey is written through ProviderRepo
                        // but never echoed back on the wire.
                        Ok(serde_json::json!({ "ok": true, "id": id }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "providers.delete".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let id = value.get("id").and_then(|v| v.as_str()).unwrap_or("");
                        if id.is_empty() {
                            return Err("missing id".to_string());
                        }
                        let deleted = core.providers_delete(id).map_err(|e| e.to_string())?;
                        Ok(serde_json::json!({ "ok": true, "deleted": deleted }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "settings.get".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let section = value
                        .get("section")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| "missing section".to_string())?;
                    let mut reply = core.settings_get(section)?;
                    if let Ok(settings) = serde_json::from_str::<serde_json::Value>(&reply.settings) {
                        let normalized = normalize_settings_shape(section, settings);
                        if let Ok(encoded) = serde_json::to_string(&normalized) {
                            reply.settings = encoded;
                        }
                    }
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "settings.set".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let section = value
                            .get("section")
                            .and_then(|v| v.as_str())
                            .ok_or_else(|| "missing section".to_string())?;
                        let settings = value
                            .get("settings")
                            .cloned()
                            .ok_or_else(|| "missing settings".to_string())?;
                        // Thin clients send partial sections. Opaque object fields
                        // must arrive as `{}` (the Vue default), not as `null`,
                        // which serde would persist for an omitted JSON `Value`.
                        let settings = normalize_settings_shape(section, settings);
                        let reply = core.settings_set(section, settings)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "display-model.resolve".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let id = value
                        .get("id")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| "missing id".to_string())?;
                    let reply = core.resolve_display_model(id)?;
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "vault.status".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    let reply = core.vault_status()?;
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "vault.archive.collect".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::VaultArchiveCollectRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let selection = vault_archive_selection(&req.domains)?;
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        let bytes = anima_core::vault::collect_archive(&db, &[], selection)
                            .map_err(|_| "archive collection failed".to_string())?;
                        let reply = anima_channel::wire::VaultArchiveReply {
                            archive: base64::Engine::encode(
                                &base64::engine::general_purpose::STANDARD,
                                &bytes,
                            ),
                            bytes: bytes.len() as u64,
                            domains: req.domains,
                        };
                        vault_archive_reply(
                            &serde_json::to_value(reply).map_err(|e| e.to_string())?,
                        )
                    },
                ),
            );
        }
        {
            m.insert(
                "vault.archive.inspect".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let req: anima_channel::wire::VaultArchiveRequest =
                        serde_json::from_value(value.clone())
                            .map_err(|_| "invalid request".to_string())?;
                    let bytes = vault_archive_bytes(&req.archive)?;
                    let report = anima_core::vault::inspect_archive(&bytes)
                        .map_err(|_| "invalid vault archive".to_string())?;
                    let reply = anima_channel::wire::VaultArchiveInspectReply {
                        format: report.format,
                        version: report.version,
                        created_at: report.created_at,
                        includes_secrets: report.includes_secrets,
                        domains: report.domains,
                        session_count: report.session_count,
                        message_count: report.message_count,
                        companion_names: report.companion_names,
                    };
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "vault.archive.apply".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::VaultArchiveRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let bytes = vault_archive_bytes(&req.archive)?;
                        let inspection = anima_core::vault::inspect_archive(&bytes)
                            .map_err(|_| "invalid vault archive".to_string())?;
                        if inspection.includes_secrets {
                            return Err("archive contains provider credentials".to_string());
                        }
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        let report = anima_core::vault::commit_archive(&db, &bytes)
                            .map_err(|_| "archive apply failed".to_string())?;
                        let reply = anima_channel::wire::VaultArchiveApplyReply {
                            sessions_inserted: report.sessions_inserted,
                            sessions_skipped: report.sessions_skipped,
                            messages_inserted: report.messages_inserted,
                            messages_skipped: report.messages_skipped,
                            summaries_inserted: report.summaries_inserted,
                            journal_entries_inserted: report.journal_entries_inserted,
                            applied: report.applied,
                            not_applied: report.not_applied,
                        };
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "sessions.media.scrub".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::SessionMediaScrubRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        let Some(media_dir) = profile_media_dir(&db) else {
                            return Err("core unavailable".to_string());
                        };
                        let report = anima_core::vault::scrub_session_media(
                            &db,
                            &media_dir,
                            &[],
                            req.create_backup,
                        )
                        .map_err(|_| "media scrub failed".to_string())?;
                        let reply = anima_channel::wire::SessionMediaScrubReply {
                            images_found: report.images_found,
                            bytes_extracted: report.bytes_extracted,
                            sessions_scanned: report.sessions_scanned,
                            backup_path: report.backup_path,
                        };
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            let publisher = publisher.clone();
            m.insert(
                "chat.send".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::ChatSendRequest =
                            serde_json::from_value(value.clone()).map_err(|e| e.to_string())?;
                        if req.content.trim().is_empty() {
                            return Err("empty content".to_string());
                        }
                        let session_id = if req.session_id.is_empty() {
                            anima_channel::uuid::uuid_v4()
                        } else {
                            req.session_id.clone()
                        };
                        let content = req.content.clone();
                        let gen_ui = req.gen_ui;
                        let svc = core.chat_service();
                        let Some(svc) = svc else {
                            return Err("core unavailable".to_string());
                        };
                        // Create the session row (no user-turn insert) so
                        // `send_message(Some(&sid), …)` honours that exact id.
                        // Previously the user turn was inserted here with a
                        // *different* session id while the generator ran with
                        // `None`, splitting the ack from the stream and making
                        // `chat.cancel` flag a session with no generation.
                        // `send_message` writes the single user turn itself.
                        core.ensure_chat_session(&session_id)?;
                        // One flag per turn, registered before the background
                        // turn starts. A cancel arriving right after the ack
                        // flags the exact Arc the generation will poll.
                        let cancel_flag =
                            std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
                        svc.register_cancel(&session_id, &cancel_flag);
                        let pub_clone = publisher.clone();
                        let err_pub = publisher.clone();
                        let sid = session_id.clone();
                        let content_clone = content.clone();
                        let assistant_message_id = anima_channel::uuid::uuid_v4();
                        let assistant_message_id_for_reply = assistant_message_id.clone();
                        let rows = core.provider_rows().unwrap_or_default();
                        // The daemon owns selection: load the same section the
                        // settings.get/set verbs expose, never trust a client
                        // field on chat.send. An empty selection preserves the
                        // env / first-enabled behavior.
                        let selection = core
                            .settings_get("chat-provider")
                            .ok()
                            .and_then(|reply| {
                                serde_json::from_str::<anima_core::settings::ChatProviderSettings>(
                                    &reply.settings,
                                )
                                .ok()
                            })
                            .unwrap_or_default();
                        let core_for_send = core.clone();
                        std::thread::spawn(move || {
                            // One process-wide Tokio runtime for every chat
                            // turn: `Runtime::new()` per turn built (and tore
                            // down) a whole multi-thread reactor per message.
                            chat_runtime().block_on(async move {
                                let resolution = anima_core::providers::resolve_provider_selection(
                                    |k| std::env::var(k).ok(),
                                    &rows,
                                    &selection.active_provider,
                                    &selection.active_model,
                                );
                                let Some(resolution) = resolution else {
                                    // No provider configured: do not silently drop
                                    // the user's turn. Persist it so a reload can
                                    // show it, then end the stream honestly.
                                    // The terminal marker carries the real
                                    // assistant message id from the ack: an empty
                                    // id makes clients key the bubble on a
                                    // stream-active flag instead of the turn.
                                    let _ = core_for_send.chat_send(&sid, &content_clone);
                                    let _ = pub_clone.token_delta(
                                        sid.clone(),
                                        assistant_message_id.clone(),
                                        String::new(),
                                        0,
                                        true,
                                        None,
                                    );
                                    return;
                                };
                                let mut rx = svc.subscribe();
                                let pump_sid = sid.clone();
                                let pump_cancel = cancel_flag.clone();
                                let pump = tokio::spawn(async move {
                                    // Real zero-based token index per assistant
                                    // message (wire: `token.delta.index`). A `0`
                                    // on every delta makes clients de-duplicate or
                                    // overwrite earlier tokens of the same turn.
                                    let mut indices: std::collections::HashMap<String, u64> =
                                        std::collections::HashMap::new();
                                    while let Some(ev) = recv_chat_event(&mut rx).await {
                                        if pump_cancel.load(std::sync::atomic::Ordering::SeqCst) {
                                            break;
                                        }
                                        // The bus is shared by every in-flight turn;
                                        // never relay another session's tokens.
                                        if chat_event_session(&ev) != pump_sid.as_str() {
                                            continue;
                                        }
                                        match ev {
                                            anima_core::chat::ChatEvent::Delta {
                                                session,
                                                message,
                                                delta,
                                            } => {
                                                let slot =
                                                    indices.entry(message.clone()).or_insert(0);
                                                let index = *slot;
                                                *slot += 1;
                                                pub_clone.token_delta(
                                                    session, message, delta, index, false, None,
                                                );
                                            }
                                            anima_core::chat::ChatEvent::MessageDone {
                                                session,
                                                message,
                                            } => {
                                                // The terminal marker follows the
                                                // last token; carry its next index.
                                                let index = indices.remove(&message).unwrap_or(0);
                                                pub_clone.token_delta(
                                                    session,
                                                    message,
                                                    String::new(),
                                                    index,
                                                    true,
                                                    None,
                                                );
                                            }
                                            _ => {}
                                        }
                                    }
                                });
                                let result = if gen_ui {
                                    svc.send_message_with_a2ui(
                                        Some(&sid),
                                        &resolution.id,
                                        resolution.config,
                                        &resolution.model,
                                        &content_clone,
                                        Some(&assistant_message_id),
                                        cancel_flag,
                                    )
                                    .await
                                } else {
                                    svc.send_message_with_assistant_id(
                                        Some(&sid),
                                        &resolution.id,
                                        resolution.config,
                                        &resolution.model,
                                        &content_clone,
                                        Some(&assistant_message_id),
                                        cancel_flag,
                                    )
                                    .await
                                };
                                pump.abort();
                                match result {
                                    Ok(_) => {}
                                    Err(err) => {
                                        // Same honest terminal marker as the
                                        // no-provider path: real assistant id,
                                        // never an empty message_id.
                                        let _ = err;
                                        let _ = err_pub.token_delta(
                                            sid.clone(),
                                            assistant_message_id.clone(),
                                            String::new(),
                                            0,
                                            true,
                                            None,
                                        );
                                    }
                                }
                                // Disconnect behavior: this handler returns the chat.send ack before the
                                // stream completes, and the pump runs in a background thread that is not
                                // tied to the WebSocket connection lifetime. If a client disconnects
                                // mid-stream, deltas continue to be published on the event bus; with no
                                // subscriber they are dropped by the bus, and the persisted user turn
                                // remains honest. The supported way to stop an in-flight turn is
                                // chat.cancel, which sets cancel_flag so the pump breaks and ChatService
                                // stops the generation; late events do not resurrect a cancelled turn.
                                let _ = sid;
                            });
                        });
                        let reply = anima_channel::wire::ChatSendReply {
                            session_id: session_id.clone(),
                            message_id: assistant_message_id_for_reply,
                            accepted: true,
                        };
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            let publisher = publisher.clone();
            m.insert(
                "chat.cancel".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let session_id = match serde_json::from_value::<
                            anima_channel::wire::ChatCancelRequest,
                        >(value.clone())
                        {
                            Ok(req) => req.session_id,
                            Err(_) => value
                                .get("session_id")
                                .and_then(|v| v.as_str())
                                .unwrap_or("")
                                .to_string(),
                        };
                        let cancelled = core.chat_cancel(&session_id);
                        if cancelled {
                            publisher.token_delta(
                                session_id.clone(),
                                String::new(),
                                String::new(),
                                0,
                                true,
                                None,
                            );
                        }
                        let reply = anima_channel::wire::ChatCancelReply { cancelled };
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "chat.history".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let session_id = value
                        .get("session_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("");
                    if session_id.is_empty() {
                        return Err("missing session_id".to_string());
                    }
                    let limit = rpc_limit(value, DEFAULT_LIST_LIMIT);
                    // The client sends the `createdAt` of the last message it
                    // already holds; `rowid = i64::MAX` includes every row at
                    // that timestamp.
                    let cursor = value
                        .get("cursor")
                        .and_then(|v| v.as_i64())
                        .map(|created_at| (created_at, i64::MAX));
                    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                    let repo = anima_store::MessageRepo::new(db);
                    // `list_page` only walks forward, so the newest page is reached by
                    // paging from the cursor (or the start of the session) and keeping the
                    // tail. The walk stops as soon as `limit + 1` rows are held, so the
                    // read is bounded by the page size rather than by the session length.
                    let mut rows: Vec<(anima_store::StoredMessage, i64)> = Vec::new();
                    let mut page_cursor = cursor;
                    loop {
                        let page = repo
                            .list_page(session_id, limit + 1, page_cursor)
                            .map_err(|e| e.to_string())?;
                        let short = page.len() < limit + 1;
                        page_cursor = page.last().map(|(m, rowid)| (m.created_at, *rowid));
                        rows.extend(page);
                        if short || rows.len() >= limit + 1 {
                            break;
                        }
                    }
                    let truncated = rows.len() > limit;
                    // Keep the newest `limit` rows, then restore the oldest-first order
                    // the reply has always used.
                    let mut rows: Vec<anima_store::StoredMessage> =
                        rows.into_iter().rev().take(limit).map(|(m, _)| m).collect();
                    rows.reverse();
                    let messages: Vec<serde_json::Value> = rows
                        .into_iter()
                        .map(|m| {
                            serde_json::json!({
                                "id": m.id,
                                "sessionId": m.session_id,
                                "role": m.role,
                                "content": m.content,
                                "createdAt": m.created_at,
                                "metadata": m.metadata,
                            })
                        })
                        .collect();
                    Ok(serde_json::json!({
                        "sessionId": session_id,
                        "messages": messages,
                        "limit": limit,
                        "truncated": truncated,
                    }))
                }),
            );
        }
        // --- new handlers ---
        {
            let core = core.clone();
            m.insert(
                "stmm.list".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let limit = rpc_limit(value, 50);
                    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                    let repo = anima_store::SummaryRepo::new(db);
                    let summaries = repo.list_recent(limit).map_err(|e| e.to_string())?;
                    Ok(serde_json::json!({ "summaries": summaries }))
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "stmm.upsert".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let blocks = value
                            .get("blocks")
                            .and_then(|v| v.as_array())
                            .ok_or_else(|| "missing blocks".to_string())?;
                        if blocks.is_empty() {
                            return Err("empty blocks".to_string());
                        }
                        if blocks.len() > STMM_UPSERT_MAX_BLOCKS {
                            return Err(format!(
                                "too many blocks: {} exceeds cap of {}",
                                blocks.len(),
                                STMM_UPSERT_MAX_BLOCKS
                            ));
                        }
                        // Validate every block before opening a write transaction:
                        // a late malformed block must not leave earlier rows committed.
                        let summaries = blocks
                            .iter()
                            .enumerate()
                            .map(|(index, block)| {
                                stmm_upsert_block(block).map_err(|err| {
                                    format!("invalid block {index}: {err}")
                                })
                            })
                            .collect::<Result<Vec<_>, _>>()?;
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        with_summary_transaction(db, &summaries)
                            .map_err(|_| "summary write failed".to_string())?;
                        Ok(serde_json::json!({ "upserted": summaries.len() }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "stmm.rebuild".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, _value: &serde_json::Value| {
                        // `summarize_day` needs a day key, session bucket, and a
                        // provider/model, none of which this verb carries, so
                        // 'rebuild' is scoped to pruning stale blocks here.
                        let pruned = core
                            .stmm_service()
                            .and_then(|svc| svc.prune().ok())
                            .unwrap_or(0);
                        Ok(serde_json::json!({ "ok": true, "pruned": pruned }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "journal.append".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let content = value
                            .get("content")
                            .and_then(|v| v.as_str())
                            .unwrap_or("")
                            .to_string();
                        if content.trim().is_empty() {
                            return Err("empty content".to_string());
                        }
                        let kind = value.get("kind").and_then(|v| v.as_str()).unwrap_or("note");
                        let svc = core
                            .journal_service()
                            .ok_or_else(|| "core unavailable".to_string())?;
                        let id = match kind {
                            "milestone" => svc.append_milestone(&content),
                            "dream" => svc.append_dream_gate_outcome(&content),
                            _ => svc.append_note(&content),
                        }
                        .map_err(|e| e.to_string())?;
                        Ok(serde_json::json!({ "id": id }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "journal.search".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let query = value
                        .get("query")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    let limit = rpc_limit(value, 50);
                    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                    // Scan the whole journal, not just the newest 1000 rows —
                    // otherwise old matches silently disappear. The store has
                    // no query-pushdown method yet, so the scan is bounded
                    // here: by row count and by the total `content` bytes
                    // pulled into memory. `list_recent` would also deserialize
                    // every `embedding` blob (potentially the largest column
                    // by far) just to be dropped, so the content-only columns
                    // are read directly through the same connection.
                    let scan_cap = i64::try_from(JOURNAL_SEARCH_SCAN_CAP).unwrap_or(i64::MAX);
                    // One connection borrow for both statements: the count
                    // and the page must see the same snapshot.
                    let (entries, truncated) = db
                        .with_connection(|conn| {
                            let total: i64 = conn.query_row(
                                "select count(*) from journal_entries",
                                [],
                                |row| row.get(0),
                            )?;
                            let truncated =
                                total > i64::try_from(JOURNAL_SEARCH_SCAN_CAP).unwrap_or(i64::MAX);
                            let mut stmt = conn.prepare(
                                "select id, kind, content, created_at, updated_at \
                                 from journal_entries \
                                 order by created_at desc, rowid desc \
                                 limit ?1",
                            )?;
                            let rows = stmt.query_map([scan_cap], |row| {
                                Ok((
                                    row.get::<_, String>(0)?,
                                    row.get::<_, String>(1)?,
                                    row.get::<_, String>(2)?,
                                    row.get::<_, i64>(3)?,
                                    row.get::<_, i64>(4)?,
                                ))
                            })?;
                            let mut out = Vec::new();
                            let mut scanned_bytes = 0u64;
                            for row in rows {
                                let (id, kind, content, created_at, updated_at) = row?;
                                scanned_bytes = scanned_bytes.saturating_add(
                                    u64::try_from(content.len()).unwrap_or(u64::MAX),
                                );
                                if scanned_bytes > JOURNAL_SEARCH_MAX_SCAN_BYTES {
                                    // Byte cap reached: stop pulling rows and
                                    // report the result as truncated.
                                    return Ok((out, true));
                                }
                                // Field names match the previous
                                // `StoredJournalEntry` serialization so
                                // existing clients keep reading timestamps;
                                // only `embedding` is gone, by design.
                                out.push(serde_json::json!({
                                    "id": id,
                                    "kind": kind,
                                    "content": content,
                                    "created_at": created_at,
                                    "updated_at": updated_at,
                                }));
                            }
                            Ok((out, truncated))
                        })
                        .map_err(|e| e.to_string())?;
                    let q = query.to_lowercase();
                    let filtered: Vec<_> = entries
                        .into_iter()
                        .filter(|e| {
                            q.is_empty()
                                || e.get("content")
                                    .and_then(|v| v.as_str())
                                    .map(|c| c.to_lowercase().contains(&q))
                                    .unwrap_or(false)
                        })
                        .take(limit)
                        .collect();
                    Ok(serde_json::json!({
                        "entries": filtered,
                        "truncated": truncated,
                    }))
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "stmm.delete".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let id = value.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
                        if id.is_empty() {
                            return Err("missing id".to_string());
                        }
                        if id.len() > STMM_UPSERT_MAX_ID_BYTES {
                            return Err(format!(
                                "id exceeds cap of {} bytes",
                                STMM_UPSERT_MAX_ID_BYTES
                            ));
                        }
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        let deleted = anima_store::SummaryRepo::new(db)
                            .delete(id)
                            .map_err(|_| "summary delete failed".to_string())?;
                        Ok(serde_json::json!({ "deleted": deleted }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "journal.delete".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let id = value.get("id").and_then(|v| v.as_str()).unwrap_or("").trim();
                        if id.is_empty() {
                            return Err("missing id".to_string());
                        }
                        if id.len() > 256 {
                            return Err("id exceeds cap of 256 bytes".to_string());
                        }
                        let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                        let deleted = anima_store::JournalRepo::new(db)
                            .delete(id)
                            .map_err(|_| "journal delete failed".to_string())?;
                        Ok(serde_json::json!({ "deleted": deleted }))
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "retrieval.status".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    Ok(serde_json::json!({ "available": core.available() }))
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.list".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let limit = rpc_limit(value, DEFAULT_LIST_LIMIT);
                    let listed = core.card_list(limit + 1)?;
                    let truncated = listed.len() > limit;
                    let cards: Vec<_> = listed.into_iter().take(limit).collect();
                    let reply = anima_channel::wire::CardListReply { cards, truncated };
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.get".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let id = value
                        .get("id")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| "missing id".to_string())?;
                    let card = core.card_get(id)?;
                    let reply = anima_channel::wire::CardGetReply { card };
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.import".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::CardImportRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let reply = core.card_import(&req)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.create".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::CardCreateRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let reply = core.card_create(&req)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.update".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::CardUpdateRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let reply = core.card_update(&req)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.delete".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let req: anima_channel::wire::CardDeleteRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let reply = core.card_delete(&req)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.metadata".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let id = value
                        .get("id")
                        .and_then(|v| v.as_str())
                        .ok_or_else(|| "missing id".to_string())?;
                    let reply = core.card_metadata(id)?;
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "cards.metadata.set".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        // Decode the wire DTO at the RPC boundary. The core setter
                        // consumes the typed DTO, so a flag of the wrong type is a
                        // boundary failure instead of a per-field `as_bool` that
                        // cannot tell a missing key from a misspelled one.
                        let req: anima_channel::wire::CardMetadataSetRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let reply = core.card_metadata_set(&req)?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "providers.models".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let req: anima_channel::wire::ProvidersModelsRequest =
                        serde_json::from_value(value.clone())
                            .map_err(|_| "invalid request".to_string())?;
                    let reply = core.providers_models(&req)?;
                    Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "sessions.list".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let db = core.db().ok_or_else(|| "core unavailable".to_string())?;
                    // `SessionRepo::list()` is unbounded; page it here so one
                    // RPC cannot materialize the whole sessions table.
                    let limit = rpc_limit(value, DEFAULT_LIST_LIMIT);
                    let repo = anima_store::SessionRepo::new(db);
                    // The store applies `limit + 1` in SQL, so the extra row
                    // is the only way to know whether more exist.
                    let listed = repo.list_recent(limit + 1).map_err(|e| e.to_string())?;
                    let truncated = listed.len() > limit;
                    let sessions: Vec<_> = listed.into_iter().take(limit).collect();
                    Ok(serde_json::json!({
                        "sessions": sessions,
                        "truncated": truncated,
                    }))
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "sessions.export".to_string(),
                handler(move |_method: &str, value: &serde_json::Value| {
                    let session_id = value
                        .get("session_id")
                        .and_then(|v| v.as_str())
                        .unwrap_or("")
                        .to_string();
                    // Never report success with a partial snapshot: an oversized
                    // session is an explicit error naming the bound.
                    let jsonl = core
                        .session_export_bounded_jsonl(&session_id)
                        .map_err(|e| e.to_string())?
                        .ok_or_else(|| {
                            format!(
                                "session export exceeds the {} byte limit",
                                anima_core::sessions::EXPORT_MAX_BYTES
                            )
                        })?;
                    Ok(serde_json::json!({ "jsonl": jsonl }))
                }),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "sessions.import".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let jsonl = value
                            .get("jsonl")
                            .and_then(|v| v.as_str())
                            .ok_or_else(|| "missing jsonl".to_string())?;
                        let reply = core
                            .session_import_jsonl(jsonl)
                            .map_err(|e| e.to_string())?;
                        Ok(serde_json::to_value(reply).map_err(|e| e.to_string())?)
                    },
                ),
            );
        }
        {
            let core = core.clone();
            m.insert(
                "sessions.delete".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        // Decode the wire DTO at the RPC boundary so a missing
                        // or misspelled session id is a typed failure instead of
                        // an empty-string delete that always reports `false`.
                        let req: anima_channel::wire::SessionDeleteRequest =
                            serde_json::from_value(value.clone())
                                .map_err(|_| "invalid request".to_string())?;
                        let deleted = core.session_delete(&req.session_id)?;
                        Ok(
                            serde_json::to_value(anima_channel::wire::SessionDeleteReply {
                                deleted,
                            })
                            .map_err(|e| e.to_string())?,
                        )
                    },
                ),
            );
        }
        {
            m.insert(
                "sessions.auto_title".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    Err("sessions.auto_title is not implemented by the daemon: auto-titling runs automatically after the first assistant reply".to_string())
                }),
            );
        }
        // --- MCP bridge (daemon-RPC; see docs/decision-bridge-scope.md) ---
        {
            m.insert(
                "mcp.list_servers".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let base_url = value
                            .get("base_url")
                            .and_then(|v| v.as_str())
                            .unwrap_or(anima_mcp::DEFAULT_REGISTRY_BASE_URL);
                        let query = value.get("query").and_then(|v| v.as_str()).unwrap_or("");
                        let limit = rpc_limit(value, 50);
                        let entries = anima_mcp::list_registry_servers(base_url, query, limit)
                            .map_err(|e| e.to_string())?;
                        let servers: Vec<serde_json::Value> = entries
                            .into_iter()
                            .map(|e| {
                                serde_json::json!({
                                    "name": e.name,
                                    "description": e.description,
                                    "url": e.url,
                                    "version": e.version,
                                })
                            })
                            .collect();
                        Ok(serde_json::json!({ "servers": servers }))
                    },
                ),
            );
        }
        {
            m.insert(
                "mcp.tools_list".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let value = value.clone();
                        with_mcp_acp_deadline(MCP_ACP_DEADLINE, move || {
                            let value = &value;
                            let transport = value
                                .get("transport")
                                .and_then(|v| v.as_str())
                                .unwrap_or("stdio");
                            let mut client = build_mcp_client(value, transport)?;
                            client.set_timeout(rpc_deadline(value));
                            client.initialize()?;
                            let tools = client.tools_list()?;
                            let tools: Vec<serde_json::Value> = tools
                                .into_iter()
                                .map(|t| {
                                    serde_json::json!({
                                        "name": t.name,
                                        "description": t.description,
                                        "inputSchema": t.input_schema,
                                    })
                                })
                                .collect();
                            client.close();
                            Ok(serde_json::json!({ "tools": tools }))
                        })
                    },
                ),
            );
        }
        // `mcp.call_tool` is the historical spelling of the same operation;
        // both names run the one implementation below instead of two copies
        // that can drift apart.
        for method in ["mcp.tools_call", "mcp.call_tool"] {
            m.insert(
                method.to_string(),
                gated(config_path, hostname, move |_method: &str, value: &serde_json::Value| {
                    let value = value.clone();
                    with_mcp_acp_deadline(MCP_ACP_DEADLINE, move || {
                        let value = &value;
                        let transport = value
                            .get("transport")
                            .and_then(|v| v.as_str())
                            .unwrap_or("stdio");
                        let tool_name = value
                            .get("tool")
                            .or_else(|| value.get("name"))
                            .or_else(|| value.get("tool_name"))
                            .and_then(|v| v.as_str())
                            .unwrap_or("");
                        if tool_name.is_empty() {
                            return Err("missing tool name (tool/name/tool_name)".to_string());
                        }
                        let arguments = value
                            .get("arguments")
                            .or_else(|| value.get("args"))
                            .cloned()
                            .unwrap_or_else(|| serde_json::json!({}));
                        let mut client = build_mcp_client(value, transport)?;
                        client.set_timeout(rpc_deadline(value));
                        client.initialize()?;
                        let result = client.tools_call(tool_name, arguments)?;
                        let text = result.text();
                        let content: Vec<serde_json::Value> = result
                            .content
                            .into_iter()
                            .map(|c| match c {
                                anima_mcp::McpToolContent::Text(t) => {
                                    serde_json::json!({ "type": "text", "text": t })
                                }
                                anima_mcp::McpToolContent::Other { content_type, raw } => {
                                    serde_json::json!({ "type": content_type, "raw": raw })
                                }
                            })
                            .collect();
                        client.close();
                        Ok(serde_json::json!({
                            "text": text,
                            "content": content,
                            "structuredContent": result.structured_content.unwrap_or(serde_json::Value::Null),
                            "isError": result.is_error,
                        }))
                    })
                }),
            );
        }
        // --- ACP bridge (daemon-RPC) ---
        {
            m.insert(
                "acp.run".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let value = value.clone();
                        with_mcp_acp_deadline(ACP_PROMPT_DEADLINE, move || {
                            let value = &value;
                            let command =
                                value.get("command").and_then(|v| v.as_str()).unwrap_or("");
                            if command.is_empty() {
                                return Err("missing command".to_string());
                            }
                            let args: Vec<String> = value
                                .get("args")
                                .and_then(|v| v.as_array())
                                .map(|a| {
                                    a.iter()
                                        .filter_map(|v| v.as_str().map(str::to_string))
                                        .collect()
                                })
                                .unwrap_or_default();
                            let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
                            let env = parse_env(value);
                            let policy_str = value
                                .get("permission_policy")
                                .and_then(|v| v.as_str())
                                .unwrap_or("auto-all");
                            let policy = match policy_str {
                                "auto-read" => anima_acp::PermissionPolicy::AutoRead,
                                _ => anima_acp::PermissionPolicy::AutoAll,
                            };
                            let prompt_text = value
                                .get("prompt")
                                .or_else(|| value.get("text"))
                                .or_else(|| value.get("content"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if prompt_text.is_empty() {
                                return Err("missing prompt/text/content".to_string());
                            }
                            let cwd_path = value
                                .get("cwd")
                                .and_then(|v| v.as_str())
                                .map(std::path::PathBuf::from);

                            let client = anima_acp::AcpAgentClient::spawn(
                                command,
                                &args_refs,
                                env.as_deref(),
                            )
                            .map_err(|e| e.to_string())?;
                            let mut client = client;
                            client.set_timeout(rpc_deadline(value));
                            client.set_prompt_timeout(acp_prompt_deadline(value));
                            client.set_permission_policy(policy);
                            let init = client.initialize().map_err(|e| e.to_string())?;
                            let session_id = client
                                .new_session(cwd_path.as_deref())
                                .map_err(|e| e.to_string())?;
                            let result = client
                                .prompt(&session_id, prompt_text)
                                .map_err(|e| e.to_string())?;
                            client.close();
                            let updates: Vec<serde_json::Value> = result
                                .updates
                                .iter()
                                .map(|u| {
                                    serde_json::json!({
                                        "kind": u.update_kind(),
                                        "text": u.agent_text(),
                                    })
                                })
                                .collect();
                            Ok(serde_json::json!({
                                "protocolVersion": init.protocol_version,
                                "agentName": init.agent_info.as_ref().map(|i| i.name.clone()),
                                "sessionId": result.session_id,
                                "stopReason": result.stop_reason.as_str(),
                                "finalText": result.final_text,
                                "updateCount": result.updates.len(),
                                "updates": updates,
                            }))
                        })
                    },
                ),
            );
        }
        {
            m.insert(
                "acp.prompt".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let value = value.clone();
                        with_mcp_acp_deadline(ACP_PROMPT_DEADLINE, move || {
                            let value = &value;
                            let command =
                                value.get("command").and_then(|v| v.as_str()).unwrap_or("");
                            if command.is_empty() {
                                return Err("missing command".to_string());
                            }
                            let args: Vec<String> = value
                                .get("args")
                                .and_then(|v| v.as_array())
                                .map(|a| {
                                    a.iter()
                                        .filter_map(|v| v.as_str().map(str::to_string))
                                        .collect()
                                })
                                .unwrap_or_default();
                            let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
                            let env = parse_env(value);
                            let policy = match value
                                .get("permission_policy")
                                .and_then(|v| v.as_str())
                                .unwrap_or("auto-all")
                            {
                                "auto-read" => anima_acp::PermissionPolicy::AutoRead,
                                _ => anima_acp::PermissionPolicy::AutoAll,
                            };
                            let prompt_text = value
                                .get("prompt")
                                .or_else(|| value.get("text"))
                                .or_else(|| value.get("content"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("");
                            if prompt_text.is_empty() {
                                return Err("missing prompt/text/content".to_string());
                            }
                            let cwd_path = value
                                .get("cwd")
                                .and_then(|v| v.as_str())
                                .map(std::path::PathBuf::from);
                            let client = anima_acp::AcpAgentClient::spawn(
                                command,
                                &args_refs,
                                env.as_deref(),
                            )
                            .map_err(|e| e.to_string())?;
                            let mut client = client;
                            client.set_timeout(rpc_deadline(value));
                            client.set_prompt_timeout(acp_prompt_deadline(value));
                            client.set_permission_policy(policy);
                            let init = client.initialize().map_err(|e| e.to_string())?;
                            let session_id = client
                                .new_session(cwd_path.as_deref())
                                .map_err(|e| e.to_string())?;
                            let result = client
                                .prompt(&session_id, prompt_text)
                                .map_err(|e| e.to_string())?;
                            client.close();
                            Ok(serde_json::json!({
                                "protocolVersion": init.protocol_version,
                                "agentName": init.agent_info.as_ref().map(|i| i.name.clone()),
                                "sessionId": result.session_id,
                                "stopReason": result.stop_reason.as_str(),
                                "finalText": result.final_text,
                                "updateCount": result.updates.len(),
                            }))
                        })
                    },
                ),
            );
        }
        {
            m.insert(
                "acp.list_agents".to_string(),
                handler(move |_method: &str, _value: &serde_json::Value| {
                    Err("acp.list_agents is not implemented by the daemon: there is no persistent agent registry (acp.json) wired yet; use acp.run with an explicit command".to_string())
                }),
            );
        }
        {
            m.insert(
                "acp.list_sessions".to_string(),
                gated(
                    config_path,
                    hostname,
                    move |_method: &str, value: &serde_json::Value| {
                        let value = value.clone();
                        with_mcp_acp_deadline(MCP_ACP_DEADLINE, move || {
                            let value = &value;
                            let command =
                                value.get("command").and_then(|v| v.as_str()).unwrap_or("");
                            if command.is_empty() {
                                return Err("missing command".to_string());
                            }
                            let args: Vec<String> = value
                                .get("args")
                                .and_then(|v| v.as_array())
                                .map(|a| {
                                    a.iter()
                                        .filter_map(|v| v.as_str().map(str::to_string))
                                        .collect()
                                })
                                .unwrap_or_default();
                            let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
                            let env = parse_env(value);
                            let client = anima_acp::AcpAgentClient::spawn(
                                command,
                                &args_refs,
                                env.as_deref(),
                            )
                            .map_err(|e| e.to_string())?;
                            let mut client = client;
                            client.set_timeout(rpc_deadline(value));
                            client.initialize().map_err(|e| e.to_string())?;
                            let sessions = client.list_sessions().map_err(|e| e.to_string())?;
                            client.close();
                            let sessions: Vec<serde_json::Value> = sessions
                                .into_iter()
                                .map(|s| {
                                    serde_json::json!({
                                        "sessionId": s.session_id,
                                        "cwd": s.cwd,
                                        "title": s.title,
                                        "updatedAt": s.updated_at,
                                    })
                                })
                                .collect();
                            Ok(serde_json::json!({ "sessions": sessions }))
                        })
                    },
                ),
            );
        }
        m
    }

    fn bind_once(&self, config: &ChannelConfig) {
        let mut inner = self.inner.lock().unwrap_or_else(|e| e.into_inner());
        // Edge-triggered presence: only emit when the bind state really flips.
        let was_bound = inner.bound;
        let publisher = &self.publisher;
        let emit_presence = |bound: bool| {
            if bound != was_bound {
                publisher.presence_changed(
                    "gateway",
                    if bound { "online" } else { "offline" },
                    None,
                );
            }
        };

        inner.last_attempt = Instant::now();
        // Single sync point: the effective config lives in Inner, kept in
        // lockstep with whatever was persisted/loaded.
        inner.hostname = config.hostname.clone();
        inner.auth_token = config.auth_token.clone();
        // Transport policy: loopback may run plaintext (`ws://`); anything
        // beyond loopback is wss-only, enforced regardless of the flag.
        // The forced value is deliberately NOT written back to the stored
        // flag, so switching back to loopback restores plaintext.
        inner.tls_flag = config.tls_config.is_some();
        let loopback = is_loopback_hostname(&config.hostname);
        let effective_tls = inner.tls_flag || !loopback;
        if !inner.tls_flag && !loopback {
            eprintln!(
                "airi-daemon: gateway hostname '{}' is not loopback; TLS is enforced (wss) even though tlsConfig is unset",
                config.hostname
            );
        }
        inner.bound_tls = effective_tls;
        // Detach first so the old server is told to stop even when the new
        // bind fails; existing sessions are NOT force-closed, matching the
        // in-app server (token rotation affects new connections only).
        let old = inner.server.take();
        if let Some(old) = old {
            old.stop();
        }

        let port = self.port();
        let result = if effective_tls {
            let domains = san_domains(&hostname_sans(&config.hostname));
            match get_or_create_certs(&self.cert_dir, &domains) {
                Ok(bundle) => {
                    let tls_config =
                        match anima_channel::tls_server_config(&bundle.cert_pem, &bundle.key_pem) {
                            Ok(cfg) => std::sync::Arc::new(cfg),
                            Err(err) => {
                                inner.last_error =
                                    Some(format!("TLS configuration unusable: {err}"));
                                inner.bound = false;
                                emit_presence(false);
                                return;
                            }
                        };
                    ChannelServer::bind_with_renderer_tls(
                        &config.hostname,
                        port,
                        config,
                        Self::renderer_handlers(
                            &self.core,
                            &self.publisher,
                            &self.config_path,
                            &config.hostname,
                        ),
                        tls_config,
                    )
                }
                Err(err) => {
                    inner.last_error = Some(format!("certificate management failed: {err}"));
                    inner.bound = false;
                    emit_presence(false);
                    return;
                }
            }
        } else {
            ChannelServer::bind_with_renderer(
                &config.hostname,
                port,
                config,
                Self::renderer_handlers(
                    &self.core,
                    &self.publisher,
                    &self.config_path,
                    &config.hostname,
                ),
            )
        };

        match result {
            Ok(server) => match server.with_event_bus(self.event_bus()).spawn() {
                Ok(handle) => {
                    inner.bound = true;
                    inner.last_error = None;
                    inner.server = Some(handle);
                }
                Err(err) => {
                    inner.last_error = Some(format!("failed to spawn gateway listener: {err}"));
                    inner.bound = false;
                }
            },
            Err(err) => {
                inner.last_error = Some(format!(
                    "failed to bind {}:{} — {err}",
                    config.hostname, port
                ));
                inner.bound = false;
            }
        }
        emit_presence(inner.bound);
    }
}

/// Reject wildcard bind hostnames (`0.0.0.0`, `::`).
///
/// A wildcard is not a DNS name: [`hostname_sans`] deliberately drops it from
/// the certificate SAN list, so a wildcard bind would force TLS (non-loopback)
/// with a certificate that covers none of the addresses a client actually
/// dials. There is no legitimate use — the daemon already forces wss for any
/// non-loopback hostname — so refuse it with a clear error at both config
/// `apply` and config `load` instead of silently minting an unusable cert.
fn validate_hostname(hostname: &str) -> Result<(), String> {
    let trimmed = hostname.trim();
    if trimmed == "0.0.0.0" || trimmed == "::" {
        return Err(format!(
            "hostname '{trimmed}' is a wildcard bind address and is not allowed; \
             use a concrete loopback or LAN/tailnet hostname"
        ));
    }
    Ok(())
}

fn hostname_sans(hostname: &str) -> Vec<String> {
    // Wildcard binds are not DNS names; never put them in a cert.
    if hostname == "0.0.0.0" || hostname == "::" {
        Vec::new()
    } else {
        vec![hostname.to_string()]
    }
}

/// Whether `hostname` resolves to this machine. IPs classify by loopback
/// bit; anything unparseable that is not the literal `localhost` is treated
/// as remote (e.g. mDNS / tailnet DNS names) — i.e. TLS-enforced.
fn is_loopback_hostname(hostname: &str) -> bool {
    let trimmed = hostname.trim().trim_end_matches('.');
    if trimmed.eq_ignore_ascii_case("localhost") {
        return true;
    }
    match trimmed.parse::<std::net::IpAddr>() {
        Ok(ip) => ip.is_loopback(),
        Err(_) => false,
    }
}

fn port_from_env() -> Option<u16> {
    // `0` is accepted (ephemeral, tests); empty/garbage falls back to 6121.
    std::env::var("SERVER_CHANNEL_PORT")
        .ok()
        .and_then(|v| v.trim().parse::<u16>().ok())
}

/// Clamp a client-supplied `limit` so one RPC cannot request an unbounded
/// table scan. Missing/garbage limits fall back to `default`.

/// One-shot MCP client handle used by the daemon RPC handlers. Wraps either
/// transport behind a uniform, string-error surface.
enum McpClient {
    Stdio(anima_mcp::McpStdioClient),
    Http(anima_mcp::McpHttpClient),
}

impl McpClient {
    fn initialize(&mut self) -> Result<(), String> {
        match self {
            McpClient::Stdio(c) => c.initialize().map(|_| ()).map_err(|e| e.to_string()),
            McpClient::Http(c) => c.initialize().map(|_| ()).map_err(|e| e.to_string()),
        }
    }

    fn tools_list(&self) -> Result<Vec<anima_mcp::McpToolDescriptor>, String> {
        match self {
            McpClient::Stdio(c) => c.tools_list().map_err(|e| e.to_string()),
            McpClient::Http(c) => c.tools_list().map_err(|e| e.to_string()),
        }
    }

    fn tools_call(
        &self,
        name: &str,
        arguments: serde_json::Value,
    ) -> Result<anima_mcp::McpToolResult, String> {
        match self {
            McpClient::Stdio(c) => c.tools_call(name, arguments).map_err(|e| e.to_string()),
            McpClient::Http(c) => c.tools_call(name, arguments).map_err(|e| e.to_string()),
        }
    }

    fn set_timeout(&mut self, timeout: std::time::Duration) {
        match self {
            McpClient::Stdio(c) => c.set_timeout(timeout),
            McpClient::Http(c) => c.set_timeout(timeout),
        }
    }

    fn close(self) {
        match self {
            McpClient::Stdio(mut c) => c.close(),
            McpClient::Http(c) => c.close(),
        }
    }
}

fn build_mcp_client(value: &serde_json::Value, transport: &str) -> Result<McpClient, String> {
    match transport {
        "http" | "https" | "streamable-http" | "streamable_http" | "remote" => {
            let url = value
                .get("url")
                .or_else(|| value.get("endpoint"))
                .or_else(|| value.get("server_url"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if url.is_empty() {
                return Err("missing url (url/endpoint/server_url)".to_string());
            }
            let token = value
                .get("bearer_token")
                .or_else(|| value.get("token"))
                .or_else(|| value.get("auth_token"))
                .and_then(|v| v.as_str());
            let client = anima_mcp::McpHttpClient::connect_with_auth(url, token)
                .map_err(|e| e.to_string())?;
            Ok(McpClient::Http(client))
        }
        _ => {
            let command = value
                .get("command")
                .or_else(|| value.get("cmd"))
                .and_then(|v| v.as_str())
                .unwrap_or("");
            if command.is_empty() {
                return Err("missing command (command/cmd)".to_string());
            }
            let args: Vec<String> = value
                .get("args")
                .and_then(|v| v.as_array())
                .map(|a| {
                    a.iter()
                        .filter_map(|x| x.as_str().map(str::to_string))
                        .collect()
                })
                .unwrap_or_default();
            let args_refs: Vec<&str> = args.iter().map(|s| s.as_str()).collect();
            let env = parse_env(value);
            let client = anima_mcp::McpStdioClient::spawn(command, &args_refs, env.as_deref())
                .map_err(|e| e.to_string())?;
            Ok(McpClient::Stdio(client))
        }
    }
}

fn parse_env(value: &serde_json::Value) -> Option<Vec<(String, String)>> {
    if let Some(obj) = value.get("env").and_then(|v| v.as_object()) {
        let mut out = Vec::new();
        for (k, val) in obj {
            if let Some(s) = val.as_str() {
                out.push((k.clone(), s.to_string()));
            }
        }
        if out.is_empty() {
            None
        } else {
            Some(out)
        }
    } else if let Some(arr) = value.get("env").and_then(|v| v.as_array()) {
        let mut out = Vec::new();
        for item in arr {
            if let Some(pair) = item.as_array() {
                if pair.len() == 2 {
                    if let (Some(k), Some(val)) = (pair[0].as_str(), pair[1].as_str()) {
                        out.push((k.to_string(), val.to_string()));
                    }
                }
            } else if let Some(obj) = item.as_object() {
                for (k, val) in obj {
                    if let Some(s) = val.as_str() {
                        out.push((k.clone(), s.to_string()));
                    }
                }
            }
        }
        if out.is_empty() {
            None
        } else {
            Some(out)
        }
    } else {
        None
    }
}

/// The process-wide Tokio runtime every background chat turn runs on.
///
/// A multi-thread runtime is a whole reactor (worker threads, I/O driver,
/// timer wheel); building one per `chat.send` turn made every message pay
/// for it twice (create + tear down). One lazily built runtime is shared by
/// all turns; `block_on` is callable from many threads at once.
fn chat_runtime() -> &'static tokio::runtime::Runtime {
    static RUNTIME: std::sync::OnceLock<tokio::runtime::Runtime> = std::sync::OnceLock::new();
    RUNTIME.get_or_init(|| {
        tokio::runtime::Builder::new_multi_thread()
            .enable_all()
            .build()
            .expect("daemon chat runtime")
    })
}

fn stmm_clamp_i64(value: Option<&serde_json::Value>) -> i64 {
    match value {
        Some(v) => {
            if let Some(n) = v.as_i64() {
                n
            } else if let Some(n) = v.as_u64() {
                n.min(i64::MAX as u64) as i64
            } else {
                0
            }
        }
        None => 0,
    }
}

/// Opaque settings objects that Vue keeps as `{}` rather than `null`.
/// Kept here so `settings.rs` stays owned by the provider-selection lane.
const SETTINGS_OBJECT_FIELDS: &[&str] = &[
    "speechProviderSettings",
    "transcriptionProviderSettings",
    "activeAdvanced",
];

/// Normalize JSON-object settings fields for partial writes and reads.
///
/// `serde_json::Value` deserializes an omitted field as `null`; the Vue stores
/// default those opaque maps to `{}`. Normalizing at the gateway boundary keeps
/// first reads, partial writes and post-write reads consistent without changing
/// the shared core settings type.
fn normalize_settings_shape(section: &str, mut settings: serde_json::Value) -> serde_json::Value {
    if !matches!(section, "hearing" | "vision") {
        return settings;
    }
    let Some(map) = settings.as_object_mut() else {
        return settings;
    };
    for field in SETTINGS_OBJECT_FIELDS {
        if map.get(*field).is_none_or(|v| v.is_null()) {
            map.insert((*field).to_string(), serde_json::Value::Object(serde_json::Map::new()));
        }
    }
    settings
}

/// Commit a validated batch in one SQLite transaction. A failure anywhere in
/// the batch rolls back every row, so retrying a rejected upsert cannot leave
/// a half-written day behind.
fn with_summary_transaction(
    db: anima_store::Database,
    summaries: &[anima_store::StoredSummary],
) -> Result<(), String> {
    db.with_connection(|conn| {
        let tx = conn.unchecked_transaction()?;
        for summary in summaries {
            conn.execute(
                "insert into summaries (id, day, content, source_session_ids, token_estimate, created_at)
                 values (?1, ?2, ?3, ?4, ?5, ?6)
                 on conflict(id) do update set day = excluded.day, content = excluded.content,
                 source_session_ids = excluded.source_session_ids,
                 token_estimate = excluded.token_estimate, created_at = excluded.created_at",
                anima_store::params![
                    summary.id,
                    summary.day,
                    summary.content,
                    serde_json::to_string(&summary.source_session_ids)?,
                    summary.token_estimate,
                    summary.created_at,
                ],
            )?;
        }
        tx.commit()?;
        Ok(())
    })
    .map_err(|e| e.to_string())
}

fn stmm_upsert_block(value: &serde_json::Value) -> Result<anima_store::StoredSummary, String> {
    let id = value
        .get("id")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if id.is_empty() {
        return Err("missing id".to_string());
    }
    if id.len() > STMM_UPSERT_MAX_ID_BYTES {
        return Err(format!(
            "id exceeds cap of {} bytes",
            STMM_UPSERT_MAX_ID_BYTES
        ));
    }

    let day = value
        .get("day")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .trim()
        .to_string();
    if day.len() != 10
        || day.chars().nth(4) != Some('-')
        || day.chars().nth(7) != Some('-')
        || !day
            .chars()
            .enumerate()
            .all(|(i, c)| i == 4 || i == 7 || c.is_ascii_digit())
    {
        return Err("invalid day format, expected YYYY-MM-DD".to_string());
    }

    let content = value
        .get("content")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    if content.trim().is_empty() {
        return Err("missing content".to_string());
    }
    if content.len() > STMM_UPSERT_MAX_CONTENT_BYTES {
        return Err(format!(
            "content exceeds cap of {} bytes",
            STMM_UPSERT_MAX_CONTENT_BYTES
        ));
    }

    let token_estimate = stmm_clamp_i64(value.get("tokenEstimate")).max(0);

    let source_session_ids: Vec<String> = value
        .get("sourceSessionIds")
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(|s| s.to_string()))
                .take(STMM_UPSERT_MAX_SOURCE_SESSION_IDS)
                .collect()
        })
        .unwrap_or_default();

    let created_at = stmm_clamp_i64(value.get("createdAt"));

    Ok(anima_store::StoredSummary {
        id,
        day,
        content,
        token_estimate,
        source_session_ids,
        created_at,
    })
}

fn rpc_limit(value: &serde_json::Value, default: usize) -> usize {
    value
        .get("limit")
        .and_then(|v| v.as_u64())
        .and_then(|n| usize::try_from(n).ok())
        .unwrap_or(default)
        .clamp(1, RPC_MAX_LIMIT)
}

/// Domains accepted from clients for a vault archive. `providers` is
/// deliberately excluded: its rows carry API credentials that must not cross
/// the gateway wire (the read-only `vault.status` only reports byte counts).
const VAULT_ARCHIVE_DOMAINS: [&str; 4] = ["characters", "chats", "memory", "backgrounds"];
/// Upper bound on a vault archive's base64 text, including the RPC envelope.
/// Both directions share the channel's single-frame limit: a larger reply
/// cannot be written to the socket, so the daemon must reject the request
/// instead of building a reply that dies at the transport boundary.
const VAULT_ARCHIVE_FRAME_LIMIT_BYTES: u64 = anima_channel::ws::MAX_WS_PAYLOAD_BYTES;
/// Base64 expands by 4/3; leave room for the JSON envelope so the encoded
/// archive plus its wrapper still fit in one WebSocket frame.
const VAULT_ARCHIVE_ENVELOPE_BYTES: u64 = 8192;
/// Upper bound on the decoded size of a client-supplied vault archive. Bounds
/// both the base64 allocation and ZIP parsing done on the RPC thread, and
/// matches the size of an archive that can be returned on this channel.
const VAULT_ARCHIVE_MAX_BYTES: u64 =
    ((VAULT_ARCHIVE_FRAME_LIMIT_BYTES - VAULT_ARCHIVE_ENVELOPE_BYTES) * 3) / 4;

/// Validate and normalize a client domain list, rejecting unknown and
/// credential-bearing domains rather than silently dropping them.
fn vault_archive_selection(domains: &[String]) -> Result<anima_core::vault::VaultSelection, String> {
    for domain in domains {
        if !VAULT_ARCHIVE_DOMAINS.contains(&domain.as_str()) {
            return Err(format!("unsupported vault archive domain: {domain}"));
        }
    }
    if domains.is_empty() {
        return Err("empty vault archive domains".to_string());
    }
    let refs: Vec<&str> = domains.iter().map(String::as_str).collect();
    Ok(anima_core::vault::VaultSelection::parse(&refs))
}

/// Decode a base64 vault archive with a hard size cap; reject padding tricks
/// and malformed input before handing bytes to ZIP parsing.
fn vault_archive_bytes(archive: &str) -> Result<Vec<u8>, String> {
    use base64::Engine as _;
    let encoded = archive.trim();
    if encoded.is_empty() {
        return Err("missing archive".to_string());
    }
    // base64 expands by 4/3; cap before allocating the decoded buffer.
    let max_encoded = VAULT_ARCHIVE_MAX_BYTES.saturating_mul(4) / 3 + 4;
    if encoded.len() as u64 > max_encoded {
        return Err(format!(
            "archive exceeds the {} byte limit",
            VAULT_ARCHIVE_MAX_BYTES
        ));
    }
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|_| "invalid base64 archive".to_string())?;
    if bytes.len() as u64 > VAULT_ARCHIVE_MAX_BYTES {
        return Err(format!(
            "archive exceeds the {} byte limit",
            VAULT_ARCHIVE_MAX_BYTES
        ));
    }
    Ok(bytes)
}

/// Serialize a vault archive reply only when the whole RPC frame fits the
/// channel limit. Returns a typed, user-safe error otherwise; callers must
/// never hand an over-limit frame to the transport.
fn vault_archive_reply(value: &serde_json::Value) -> Result<serde_json::Value, String> {
    let serialized = serde_json::to_string(value).map_err(|e| e.to_string())?;
    if serialized.len() as u64 > VAULT_ARCHIVE_FRAME_LIMIT_BYTES {
        return Err(format!(
            "vault archive exceeds the {} byte transport limit; narrow the archive domains",
            VAULT_ARCHIVE_FRAME_LIMIT_BYTES
        ));
    }
    Ok(value.clone())
}

/// Per-profile media directory used by `scrub_session_media` for extracted
/// assets and pre-scrub backups (mirrors the SQLite parent directory).
fn profile_media_dir(db: &anima_store::Database) -> Option<PathBuf> {
    db.with_connection(|conn| Ok(conn.path().map(PathBuf::from)))
        .ok()
        .flatten()
        .and_then(|path| path.parent().map(Path::to_path_buf))
}

const DEFAULT_HOSTNAME_PLACEHOLDER: &str = "127.0.0.1";

/// Copy `source` into the daemon-owned config path (atomic), preserving
/// everything including `tlsConfig`. Returns the source path on success.
fn adopt(source: &Path, dest: &Path) -> io::Result<PathBuf> {
    adopt_with(source, dest, |_| {})
}

/// `before_rename` lets tests inspect the temp file while it still holds the
/// token (production passes a no-op).
fn adopt_with(source: &Path, dest: &Path, before_rename: impl FnOnce(&Path)) -> io::Result<PathBuf> {
    let raw = fs::read_to_string(source)?;
    // Basic validity check: it must parse as a JSON object. We deliberately
    // do not require a token here — load_or_heal decides freshness.
    let value: serde_json::Value =
        serde_json::from_str(&raw).map_err(|e| io::Error::new(io::ErrorKind::InvalidData, e))?;
    if !value.is_object() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "adoptable config is not a JSON object",
        ));
    }
    if let Some(parent) = dest.parent() {
        fs::create_dir_all(parent)?;
    }
    let tmp = dest.with_extension("json.tmp");
    #[cfg(unix)]
    {
        use std::io::Write as _;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        // mode(0o600) only applies at creation; a pre-existing 0644 tmp
        // would otherwise be written and renamed with world-readable data.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        file.write_all(raw.as_bytes())?;
    }
    #[cfg(not(unix))]
    {
        fs::write(&tmp, raw)?;
    }
    before_rename(&tmp);
    fs::rename(&tmp, dest)?;
    Ok(source.to_path_buf())
}

/// Scan for the Electrobun/Electron desktop app's gateway config
/// (`<userData>/server-channel-config.json`) and return the newest match by
/// modification time. Best-effort: directories that fail to read are skipped.
fn find_adoptable() -> Option<PathBuf> {
    let config_home = std::env::var("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|_| {
            dirs::home_dir()
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".config")
        });

    let mut best: Option<(PathBuf, std::time::SystemTime)> = None;
    let matches = match fs::read_dir(&config_home) {
        Ok(entries) => entries,
        Err(_) => return None,
    };
    for entry in matches.flatten() {
        let name = entry.file_name();
        let name = name.to_string_lossy();
        if !name.starts_with("ai.moeru.airi") {
            continue;
        }
        let candidate = entry.path().join("server-channel-config.json");
        if let Ok(meta) = fs::metadata(&candidate) {
            let modified = meta.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            match &best {
                Some((_, current)) if *current >= modified => {}
                _ => best = Some((candidate, modified)),
            }
        }
    }
    best.map(|(path, _)| path)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_gateway(dir: PathBuf, cert_dir: PathBuf) -> Gateway {
        Gateway {
            config_path: dir.join(CONFIG_FILE),
            cert_dir,
            port_override: Some(0),
            core: CoreService::open(None),
            publisher: EventPublisher::new(anima_channel::EventBus::with_defaults()),
            inner: Mutex::new(Inner {
                hostname: DEFAULT_HOSTNAME_PLACEHOLDER.to_string(),
                auth_token: String::new(),
                tls_flag: false,
                bound_tls: false,
                bound: false,
                last_error: None,
                adopted_from: None,
                server: None,
                last_attempt: Instant::now() - RETRY_INTERVAL,
            }),
        }
    }

    fn fresh_gateway() -> (Gateway, tempfile::TempDir) {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        // Isolate from the real data dir by overriding paths directly.
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));
        // Heal the log path: write a fresh config and bind. The fixture is
        // fail-closed (`allow_actions: None`) regardless of what
        // `ChannelConfig::healed()` provisions in production.
        let mut config = ChannelConfig::healed();
        config.allow_actions = None;
        fs::create_dir_all(&dir).unwrap();
        let json = serde_json::to_string_pretty(&config).unwrap();
        fs::write(&gateway.config_path, json).unwrap();
        gateway.bind_once(&config);
        (gateway, tmp)
    }

    fn get_json(gateway: &Gateway) -> serde_json::Value {
        serde_json::from_str(&gateway.handle(&GatewayRequest::Get)).unwrap()
    }

    /// Test-only alias that includes the gateway's own config path, which
    /// gates the mutating verbs (see `require_actions`).
    fn handlers(gateway: &Gateway) -> anima_channel::RendererHandlers {
        Gateway::renderer_handlers(
            &gateway.core,
            &gateway.publisher(),
            &gateway.config_path,
            &gateway.inner.lock().unwrap().hostname.clone(),
        )
    }

    /// Like `handlers`, but with an explicit effective hostname (for LAN
    /// gate tests). Does not consult the gateway's bound state.
    fn handlers_with_hostname(
        gateway: &Gateway,
        hostname: &str,
    ) -> anima_channel::RendererHandlers {
        Gateway::renderer_handlers(
            &gateway.core,
            &gateway.publisher(),
            &gateway.config_path,
            hostname,
        )
    }

    /// Write `config.json` so the `allowActions` gate permits mutating verbs.
    fn enable_actions(gateway: &Gateway) {
        enable_actions_with_remote(gateway, None);
    }

    /// Write `config.json` with a chosen `allowRemoteActions` value. `None`
    /// omits the key entirely (the fail-closed default for non-loopback).
    fn enable_actions_with_remote(gateway: &Gateway, remote: Option<serde_json::Value>) {
        let mut value = serde_json::to_value(ChannelConfig::healed()).unwrap();
        value["allowActions"] = serde_json::json!(true);
        match remote {
            Some(remote) => {
                value["allowRemoteActions"] = remote;
            }
            None => {
                value.as_object_mut().unwrap().remove("allowRemoteActions");
            }
        }
        fs::create_dir_all(gateway.config_path.parent().unwrap()).unwrap();
        fs::write(
            &gateway.config_path,
            serde_json::to_string_pretty(&value).unwrap(),
        )
        .unwrap();
    }

    /// Gateway with an isolated on-disk core, for tests that write data.
    fn isolated_gateway() -> (Gateway, tempfile::TempDir) {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        let gateway = Gateway {
            config_path: dir.join(CONFIG_FILE),
            cert_dir: dir.join(CERTS_DIR),
            port_override: Some(0),
            core: CoreService::open(Some(tmp.path().to_path_buf())),
            publisher: EventPublisher::new(anima_channel::EventBus::with_defaults()),
            inner: Mutex::new(Inner {
                hostname: DEFAULT_HOSTNAME_PLACEHOLDER.to_string(),
                auth_token: String::new(),
                tls_flag: false,
                bound_tls: false,
                bound: false,
                last_error: None,
                adopted_from: None,
                server: None,
                last_attempt: Instant::now() - RETRY_INTERVAL,
            }),
        };
        let mut config = ChannelConfig::healed();
        // Fail-closed fixture: mutating verbs stay denied unless a test opts
        // in via `enable_actions` (production healing opts in for loopback).
        config.allow_actions = None;
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            &gateway.config_path,
            serde_json::to_string_pretty(&config).unwrap(),
        )
        .unwrap();
        gateway.bind_once(&config);
        (gateway, tmp)
    }

    #[tokio::test]
    async fn recv_chat_event_recovers_from_lagged_receiver() {
        // Capacity 2, six sends: a plain `recv().await` returns `Err(Lagged)`
        // first. The pump must treat that as "missed events", not end-of-stream.
        let (tx, mut rx) = tokio::sync::broadcast::channel::<anima_core::chat::ChatEvent>(2);
        for i in 0..6 {
            let _ = tx.send(anima_core::chat::ChatEvent::Delta {
                session: "s".into(),
                message: format!("m{i}"),
                delta: "x".into(),
            });
        }
        let first = recv_chat_event(&mut rx)
            .await
            .expect("Lagged must not end the pump");
        assert!(matches!(first, anima_core::chat::ChatEvent::Delta { .. }));
        assert!(
            recv_chat_event(&mut rx).await.is_some(),
            "pump must keep draining after a Lagged error"
        );
    }

    #[test]
    fn chat_send_pumps_only_forward_their_own_session() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        use std::sync::Arc;
        use std::time::Duration;

        struct GatedMock {
            arrived: Arc<AtomicUsize>,
        }
        #[async_trait::async_trait]
        impl anima_llm::ChatProvider for GatedMock {
            fn id(&self) -> &str {
                "pump-session-gate"
            }
            async fn models(&self) -> Result<Vec<anima_llm::ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(
                &self,
                _req: anima_llm::ChatRequest,
            ) -> Result<anima_llm::ChatStream, anima_llm::LlmError> {
                self.arrived.fetch_add(1, Ordering::SeqCst);
                // Hold both streams at the gate until both pumps have
                // subscribed, so a cross-session leak is deterministic.
                while self.arrived.load(Ordering::SeqCst) < 2 {
                    tokio::time::sleep(Duration::from_millis(5)).await;
                }
                Ok(Box::pin(futures_util::stream::iter(vec![
                    Ok(anima_llm::ChatChunk::text("X")),
                    Ok(anima_llm::ChatChunk::finish("stop")),
                ])))
            }
        }

        let (gateway, _tmp) = isolated_gateway();
        let arrived = Arc::new(AtomicUsize::new(0));
        let svc = gateway.core.chat_service().unwrap();
        svc.providers.lock().unwrap().insert(
            "pump-session-gate".to_string(),
            Arc::new(GatedMock {
                arrived: arrived.clone(),
            }),
        );
        let db = gateway.core.db().unwrap();
        anima_store::ProviderRepo::new(db)
            .upsert(&anima_store::StoredProvider {
                id: "pump-session-gate".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();

        let lane = gateway.publisher().bus().new_lane();
        lane.subscribe(anima_channel::EventTopic::ALL);
        gateway.publisher().bus().register_lane(&lane);

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let send = handlers.get("chat.send").unwrap();
        send(
            "chat.send",
            &serde_json::json!({ "sessionId": "A", "content": "a" }),
        )
        .unwrap();
        send(
            "chat.send",
            &serde_json::json!({ "sessionId": "B", "content": "b" }),
        )
        .unwrap();

        for _ in 0..200 {
            if arrived.load(Ordering::SeqCst) >= 2 {
                break;
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        assert_eq!(arrived.load(Ordering::SeqCst), 2, "both streams must start");

        let mut a_deltas = 0usize;
        let mut b_deltas = 0usize;
        for _ in 0..100 {
            for event in lane.drain() {
                if let anima_channel::EventPayload::TokenDelta(d) = event.data {
                    if !d.final_ && d.delta == "X" {
                        if d.session_id == "A" {
                            a_deltas += 1;
                        }
                        if d.session_id == "B" {
                            b_deltas += 1;
                        }
                    }
                }
            }
            if a_deltas == 1 && b_deltas == 1 {
                break;
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        assert_eq!(a_deltas, 1, "A's pump must not relay B's delta");
        assert_eq!(b_deltas, 1, "B's pump must not relay A's delta");
    }

    #[test]
    fn chat_cancel_accepts_camel_case_request_ids() {
        // ROOT CAUSE: the handler reads only `session_id`, while `ChatCancelRequest`
        // serializes `sessionId`/`requestId`, so a valid canonical request cancels
        // an empty session. Here we prove the canonical session id reaches the
        // handler while the legacy snake_case fallback preserves the prior no-turn behavior.
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);

        use anima_llm::{ChatChunk, ChatRequest, ChatStream, ModelInfo};
        use async_trait::async_trait;
        use futures_util::stream;
        use std::sync::Arc;
        struct PendingMock;
        #[async_trait]
        impl anima_llm::ChatProvider for PendingMock {
            fn id(&self) -> &str {
                "cancel-test"
            }
            async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(&self, _req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
                Ok(Box::pin(stream::pending::<
                    Result<ChatChunk, anima_llm::LlmError>,
                >()))
            }
        }
        let svc = gateway.core.chat_service().expect("chat service");
        svc.register_client("cancel-test", Arc::new(PendingMock));
        anima_store::ProviderRepo::new(gateway.core.db().unwrap())
            .upsert(&anima_store::StoredProvider {
                id: "cancel-test".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();
        let send_handlers = handlers(&gateway);
        let send = send_handlers.get("chat.send").unwrap();
        send(
            "chat.send",
            &serde_json::json!({"sessionId":"cancel-session","content":"stop me"}),
        )
        .expect("chat.send Ok");
        std::thread::sleep(std::time::Duration::from_millis(50));

        let handlers = std::sync::Arc::new(handlers(&gateway));
        let reply = anima_channel::dispatch::RpcRegistry::dispatch(
            &anima_channel::RpcContext::new("127.0.0.1", 6121),
            "chat.cancel",
            &serde_json::json!({ "sessionId": "cancel-session", "requestId": "req-1" }),
            &handlers,
        )
        .expect("dispatch must succeed for canonical camelCase payload");
        assert_eq!(
            reply["cancelled"], true,
            "canonical camelCase cancel must reach the in-flight session"
        );
    }

    #[test]
    fn chat_send_gen_ui_capability_routes_to_a2ui_only_when_requested() {
        use std::sync::{mpsc, Arc};

        struct RecordingMock {
            systems: mpsc::Sender<Option<String>>,
        }
        #[async_trait::async_trait]
        impl anima_llm::ChatProvider for RecordingMock {
            fn id(&self) -> &str {
                "gen-ui-capture"
            }
            async fn models(&self) -> Result<Vec<anima_llm::ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(
                &self,
                req: anima_llm::ChatRequest,
            ) -> Result<anima_llm::ChatStream, anima_llm::LlmError> {
                let _ = self.systems.send(req.system.clone());
                Ok(Box::pin(futures_util::stream::iter(vec![Ok(
                    anima_llm::ChatChunk::finish("stop"),
                )])))
            }
        }

        let (gateway, _tmp) = isolated_gateway();
        let (tx, rx) = mpsc::channel();
        let svc = gateway.core.chat_service().unwrap();
        svc.providers.lock().unwrap().insert(
            "gen-ui-capture".to_string(),
            Arc::new(RecordingMock { systems: tx }),
        );
        let db = gateway.core.db().unwrap();
        anima_store::ProviderRepo::new(db)
            .upsert(&anima_store::StoredProvider {
                id: "gen-ui-capture".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let send = handlers.get("chat.send").unwrap();
        send(
            "chat.send",
            &serde_json::json!({ "sessionId": "plain", "content": "plain" }),
        )
        .unwrap();
        let plain_system = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert!(
            plain_system.is_none(),
            "default chat.send must stay ungated"
        );

        // Only start the second generation after the provider has recorded the
        // first; concurrent background turns can otherwise arrive in either
        // order and make a fixed-index assertion flake.
        send(
            "chat.send",
            &serde_json::json!({ "sessionId": "widget", "content": "widget", "genUi": true }),
        )
        .unwrap();
        let a2ui = rx
            .recv_timeout(Duration::from_secs(5))
            .unwrap()
            .expect("genUi: true must opt into the A2UI system prompt");
        assert!(a2ui.contains("v0.9"));
        assert!(a2ui.contains("unique, stable, slug-like surfaceId"));
    }

    #[test]
    fn chat_send_without_provider_persists_user_turn() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let send = handlers.get("chat.send").unwrap();
        let reply = send(
            "chat.send",
            &serde_json::json!({ "sessionId": "no-provider", "content": "remember me" }),
        )
        .unwrap();
        assert_eq!(reply["accepted"], true);

        let mut persisted = false;
        for _ in 0..100 {
            let history = gateway.core.chat_stream("no-provider").unwrap();
            if history
                .iter()
                .any(|m| m.role == "user" && m.content == "remember me")
            {
                persisted = true;
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert!(persisted, "no provider must not discard the user turn");
    }

    #[test]
    fn chat_send_over_ws_returns_deltas() {
        let (gateway, _tmp) = fresh_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let h = handlers.get("chat.send").expect("chat.send registered");
        let reply = h(
            "chat.send",
            &serde_json::json!({"sessionId":"s1","content":"hi"}),
        )
        .expect("ok");
        assert_eq!(reply["accepted"], true);
    }

    #[test]
    fn chat_send_rejects_empty_content() {
        let (gateway, _tmp) = fresh_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let h = handlers.get("chat.send").expect("chat.send registered");
        let err = h(
            "chat.send",
            &serde_json::json!({"sessionId":"s1","content":""}),
        )
        .expect_err("empty content must fail");
        assert!(!err.is_empty());
    }

    #[test]
    fn chat_cancel_stops_stream() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);

        // A cancel is honest only when a generation is actually in flight:
        // register a never-yielding provider and start a turn through the
        // public chat.send handler before cancelling it.
        use anima_llm::{ChatChunk, ChatRequest, ChatStream, ModelInfo};
        use async_trait::async_trait;
        use futures_util::stream;
        use std::sync::Arc;

        struct PendingMock;
        #[async_trait]
        impl anima_llm::ChatProvider for PendingMock {
            fn id(&self) -> &str {
                "cancel-test"
            }
            async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(&self, _req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
                Ok(Box::pin(stream::pending::<
                    Result<ChatChunk, anima_llm::LlmError>,
                >()))
            }
        }
        let svc = gateway.core.chat_service().expect("chat service");
        svc.register_client("cancel-test", Arc::new(PendingMock));
        anima_store::ProviderRepo::new(gateway.core.db().unwrap())
            .upsert(&anima_store::StoredProvider {
                id: "cancel-test".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();
        let send = handlers.get("chat.send").expect("chat.send registered");
        send(
            "chat.send",
            &serde_json::json!({"sessionId":"cancel-session","content":"stop me"}),
        )
        .expect("chat.send Ok");
        // Give the spawned pump time to register the generation's cancel flag.
        std::thread::sleep(std::time::Duration::from_millis(50));

        let h = handlers.get("chat.cancel").expect("chat.cancel registered");
        let reply = h(
            "chat.cancel",
            &serde_json::json!({"session_id":"cancel-session"}),
        )
        .expect("ok");
        assert_eq!(
            reply["cancelled"], true,
            "an accepted cancel must report cancelled=true"
        );
    }

    #[test]
    fn fresh_gateway_binds_and_reports() {
        let (gateway, _tmp) = fresh_gateway();
        let v = get_json(&gateway);
        assert_eq!(v["bound"], true);
        assert_eq!(v["tlsEnabled"], false);
        assert!(v["authToken"].as_str().map(|t| t.len()) == Some(36));
        assert!(v["lastError"].is_null());
    }

    #[test]
    fn apply_changes_hostname_and_keeps_token() {
        anima_channel::install_default_crypto_provider();
        let (gateway, _tmp) = fresh_gateway();
        let before = get_json(&gateway)["authToken"]
            .as_str()
            .unwrap()
            .to_string();
        // Enable TLS explicitly on a loopback host: deterministic across
        // hosts (a concrete non-loopback IP is not always bindable).
        let reply = gateway.handle(&GatewayRequest::Apply(
            r#"{"hostname": "127.0.0.1", "tlsConfig": {}}"#.to_string(),
        ));
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["hostname"], "127.0.0.1");
        assert_eq!(v["authToken"], before);

        let after = get_json(&gateway);
        assert_eq!(after["hostname"], "127.0.0.1");
        assert_eq!(after["tlsEnabled"], true);
        assert_eq!(after["bound"], true, "TLS must bind after minting certs");

        // Disable TLS: plaintext is restored on loopback.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": null}"#.to_string(),
        ));
        let after = get_json(&gateway);
        assert_eq!(after["tlsEnabled"], false);
        assert_eq!(after["bound"], true);
    }

    #[test]
    fn apply_rejects_wildcard_hostname() {
        let (gateway, _tmp) = fresh_gateway();
        let before = get_json(&gateway);
        let before_hostname = before["hostname"].as_str().unwrap().to_string();
        for raw in [
            r#"{"hostname": "0.0.0.0"}"#,
            r#"{"hostname": "::"}"#,
            r#"{"hostname": "  0.0.0.0  "}"#,
        ] {
            let reply = gateway.handle(&GatewayRequest::Apply(raw.to_string()));
            let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
            assert_eq!(v["ok"], false, "wildcard {raw} must be rejected");
            let err = v["error"].as_str().unwrap();
            assert!(err.contains("wildcard"), "clear error expected, got {err}");
        }
        // The live config is unchanged: no wildcard was persisted or bound.
        let after = get_json(&gateway);
        assert_eq!(after["hostname"], before_hostname);
        assert!(!after["lastError"].as_str().unwrap().is_empty());
    }

    #[test]
    fn load_rejects_wildcard_hostname_config() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        fs::create_dir_all(&dir).unwrap();
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));
        // A persisted config with a wildcard hostname must not bind. The
        // gateway starts unbound with a stale last_attempt (see test_gateway),
        // so `maybe_retry` exercises the public load/heal path.
        let mut config = ChannelConfig::healed();
        config.hostname = "0.0.0.0".to_string();
        let json = serde_json::to_string_pretty(&config).unwrap();
        fs::write(&gateway.config_path, json).unwrap();

        gateway.maybe_retry();

        let after = get_json(&gateway);
        assert_eq!(after["bound"], false, "wildcard config must not bind");
        let err = after["lastError"].as_str().unwrap();
        assert!(
            err.contains("wildcard"),
            "clear load error expected, got {err}"
        );
    }

    #[test]
    fn validate_hostname_rejects_only_wildcards() {
        assert!(validate_hostname("0.0.0.0").is_err());
        assert!(validate_hostname("::").is_err());
        assert!(validate_hostname("  0.0.0.0  ").is_err());
        assert!(validate_hostname("127.0.0.1").is_ok());
        assert!(validate_hostname("::1").is_ok());
        assert!(validate_hostname("localhost").is_ok());
        assert!(validate_hostname("host.tailnet.ts.net").is_ok());
        assert!(validate_hostname("192.168.1.10").is_ok());
    }

    #[test]
    fn apply_reports_ok_false_when_rebind_fails() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        // cert_dir is a *file*, so the TLS rebind forced by a non-loopback
        // hostname fails certificate management deterministically.
        let cert_dir = tmp.path().join("certs-blocker");
        fs::write(&cert_dir, "not a dir").unwrap();
        let gateway = test_gateway(dir.clone(), cert_dir);
        let config = ChannelConfig::healed();
        fs::create_dir_all(&dir).unwrap();
        let json = serde_json::to_string_pretty(&config).unwrap();
        fs::write(&gateway.config_path, json).unwrap();
        gateway.bind_once(&config);
        assert_eq!(get_json(&gateway)["bound"], true);

        // Explicit tlsConfig forces a TLS rebind, which hits the cert blocker.
        let reply = gateway.handle(&GatewayRequest::Apply(r#"{"tlsConfig": {}}"#.to_string()));
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["ok"], false, "failed rebind must surface ok:false");
        assert!(v["error"].as_str().is_some_and(|e| !e.is_empty()));
        // The persisted config is honest about the state via Get.
        assert!(!get_json(&gateway)["lastError"].is_null());
        assert_eq!(get_json(&gateway)["bound"], false);
    }

    #[test]
    fn apply_rejects_garbage() {
        let (gateway, _tmp) = fresh_gateway();
        for raw in ["not json", "[1,2]", "5", "\"string\""] {
            let reply = gateway.handle(&GatewayRequest::Apply(raw.to_string()));
            let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
            assert_eq!(v["ok"], false, "input {raw} must be rejected");
        }
    }

    #[test]
    fn regenerate_token_rotates_and_persists() {
        let (gateway, _tmp) = fresh_gateway();
        let before = get_json(&gateway)["authToken"]
            .as_str()
            .unwrap()
            .to_string();
        let reply = gateway.handle(&GatewayRequest::RegenerateToken);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        let after = v["authToken"].as_str().unwrap();
        assert_ne!(after, before);
        assert_eq!(get_json(&gateway)["authToken"], after);
        // Persisted: a fresh load sees the rotated token.
        let reloaded = load_or_heal(&gateway.config_path).unwrap();
        assert_eq!(reloaded.auth_token, after);
    }

    #[test]
    fn loopback_classification() {
        assert!(is_loopback_hostname("127.0.0.1"));
        assert!(is_loopback_hostname("127.0.1.17")); // loopback range
        assert!(is_loopback_hostname("::1"));
        assert!(is_loopback_hostname("localhost"));
        assert!(is_loopback_hostname("LOCALHOST"));
        assert!(!is_loopback_hostname("0.0.0.0"));
        assert!(!is_loopback_hostname("192.168.1.10"));
        assert!(!is_loopback_hostname("my-host.tailnet.ts.net"));
        assert!(!is_loopback_hostname("::"));
    }

    #[test]
    fn tls_config_round_trips_through_apply() {
        let (gateway, _tmp) = fresh_gateway();
        // Enable TLS.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": {}}"#.to_string(),
        ));
        let v = get_json(&gateway);
        assert_eq!(v["tlsEnabled"], true);
        assert_eq!(v["bound"], true, "TLS must bind with freshly minted certs");
        let reloaded = load_or_heal(&gateway.config_path).unwrap();
        assert!(reloaded.tls_config.is_some());
        // Disable TLS.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": null}"#.to_string(),
        ));
        let v = get_json(&gateway);
        assert_eq!(v["tlsEnabled"], false);
        assert_eq!(v["bound"], true);
    }

    #[test]
    fn tls_flag_three_state_and_legacy_alias_precedence() {
        let (gateway, _tmp) = fresh_gateway();
        // Any non-null value (not just objects) enables TLS.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": 0}"#.to_string(),
        ));
        assert_eq!(get_json(&gateway)["tlsEnabled"], true);

        // The legacy `tlsConfig` spelling wins over `websocketTlsConfig`
        // when both are present, including an explicit `null`.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"tlsConfig": null, "websocketTlsConfig": {}}"#.to_string(),
        ));
        assert_eq!(get_json(&gateway)["tlsEnabled"], false);

        // Explicit `null` on the canonical key disables TLS.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": {}}"#.to_string(),
        ));
        assert_eq!(get_json(&gateway)["tlsEnabled"], true);
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": null}"#.to_string(),
        ));
        assert_eq!(get_json(&gateway)["tlsEnabled"], false);

        // Absent key keeps the current flag.
        gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig": {}}"#.to_string(),
        ));
        gateway.handle(&GatewayRequest::Apply(
            r#"{"hostname": "127.0.0.1"}"#.to_string(),
        ));
        assert_eq!(get_json(&gateway)["tlsEnabled"], true);
    }

    #[test]
    fn persist_tightens_preexisting_0644_tmp() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("config.json");
        let tmp_path = path.with_extension("json.tmp");
        fs::write(&tmp_path, "stale").unwrap();
        fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o644)).unwrap();
        fs::write(&path, "old").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        Gateway::persist(&path, &ChannelConfig::healed()).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "persisted config must be owner-only");
    }

    #[test]
    fn adoption_tightens_preexisting_0644_dest() {
        use std::os::unix::fs::PermissionsExt;
        let tmp = tempfile::tempdir().unwrap();
        let source_dir = tmp.path().join("ai.moeru.airi.test");
        fs::create_dir_all(&source_dir).unwrap();
        let source = source_dir.join("server-channel-config.json");
        fs::write(
            &source,
            r#"{ "hostname": "127.0.0.1", "authToken": "keep-me-123" }"#,
        )
        .unwrap();
        let dest = tmp.path().join("daemon").join(CONFIG_FILE);
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        fs::write(&dest, "old").unwrap();
        fs::set_permissions(&dest, fs::Permissions::from_mode(0o644)).unwrap();
        // A stale 0644 tmp must not survive either.
        fs::write(dest.with_extension("json.tmp"), "stale").unwrap();
        fs::set_permissions(
            dest.with_extension("json.tmp"),
            fs::Permissions::from_mode(0o644),
        )
        .unwrap();

        adopt(&source, &dest).expect("adopt");
        let mode = fs::metadata(&dest).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "adopted config must be owner-only");
    }

    #[test]
    #[cfg(unix)]
    fn adoption_temp_is_0600_while_holding_token() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join("source.json");
        let token = "keep-me-123";
        fs::write(&source, format!(r#"{{"authToken":"{token}"}}"#)).unwrap();
        let dest = dir.path().join("daemon").join(CONFIG_FILE);
        fs::create_dir_all(dest.parent().unwrap()).unwrap();
        let tmp_path = dest.with_extension("json.tmp");
        fs::write(&tmp_path, "stale").unwrap();
        fs::set_permissions(&tmp_path, fs::Permissions::from_mode(0o644)).unwrap();

        adopt_with(&source, &dest, |tmp_path| {
            let mode = fs::metadata(tmp_path).unwrap().permissions().mode() & 0o777;
            assert_eq!(mode, 0o600, "adoption tmp must be owner-only before rename");
            let raw = fs::read_to_string(tmp_path).unwrap();
            assert!(
                raw.contains(token),
                "adoption tmp must hold the token before rename"
            );
        })
        .expect("adopt");

        assert!(!tmp_path.exists(), "tmp must be renamed away");
        let mode = fs::metadata(&dest).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "adopted config must be owner-only");
    }

    #[test]
    fn adoption_preserves_token_and_tls() {
        let tmp = tempfile::tempdir().unwrap();
        let source_dir = tmp.path().join("ai.moeru.airi.test");
        fs::create_dir_all(&source_dir).unwrap();
        let source = source_dir.join("server-channel-config.json");
        fs::write(
            &source,
            r#"{ "hostname": "0.0.0.0", "authToken": "keep-me-123", "tlsConfig": {} }"#,
        )
        .unwrap();
        let dest = tmp
            .path()
            .join("daemon")
            .join("server-channel")
            .join(CONFIG_FILE);
        let adopted = adopt(&source, &dest).expect("adopt");
        assert_eq!(adopted, source);
        let raw = fs::read_to_string(&dest).unwrap();
        let v: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(v["authToken"], "keep-me-123");
        assert_eq!(v["tlsConfig"], serde_json::json!({}));
    }

    #[test]
    fn core_status_handler_reports_health_and_no_secrets() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));

        // Observe the same bus the injected publisher writes to.
        let lane = gateway.publisher().bus().new_lane();
        lane.subscribe(anima_channel::EventTopic::ALL);
        gateway.publisher().bus().register_lane(&lane);

        let handlers = handlers(&gateway);
        let h = handlers
            .get("core.status")
            .expect("core.status handler registered");
        let reply =
            h("core.status", &serde_json::json!({})).expect("healthy core.status returns Ok");
        let v: serde_json::Value = reply;
        assert_eq!(v["coreAvailable"], true);
        assert_eq!(v["storeAvailable"], true);
        assert_eq!(v["storeHealth"], "ok");
        assert_eq!(v["protocol"], "airi-channel/1");
        assert!(v.get("authToken").is_none());
        assert!(v.get("token").is_none());
        assert!(v.get("path").is_none());

        // The handler emitted exactly one status.changed event with the same
        // health fields as the reply, and no secret-bearing payload.
        let events = lane.drain();
        assert_eq!(events.len(), 1, "one health snapshot per change");
        let event = &events[0];
        assert_eq!(event.topic, anima_channel::EventTopic::StatusChanged);
        let anima_channel::EventPayload::StatusChanged(data) = &event.data else {
            panic!("expected StatusChanged payload, got {:?}", event.data);
        };
        assert!(data.core_available && data.store_available);
        assert_eq!(data.store_health, "ok");
        assert_eq!(data.seq, 0);
        assert!(data.ts_ms > 0);

        // A second, unchanged RPC must not echo a fresh change event.
        let _ = h("core.status", &serde_json::json!({})).expect("healthy status");
        assert_eq!(lane.len(), 0, "unchanged health must be deduped");

        let dir2 = tempfile::tempdir().unwrap();
        let db = dir2.path().join("airi.sqlite");
        std::fs::create_dir_all(&db).unwrap();
        let core = CoreService::open(Some(dir2.path().to_path_buf()));
        assert!(!core.available());
        let handlers = Gateway::renderer_handlers(
            &core,
            &gateway.publisher,
            &gateway.config_path,
            &gateway.inner.lock().unwrap().hostname.clone(),
        );
        let h = handlers.get("core.status").unwrap();
        let err = h("core.status", &serde_json::json!({})).expect_err("unavailable must Err");
        assert!(err.starts_with("core unavailable:"), "got: {err}");
        assert!(!err.contains('/'));
        assert!(!err.contains("tmp"));
        assert!(!err.contains(".sqlite"));
        assert_eq!(lane.len(), 0, "an unavailable core emits no status.changed");
    }

    #[test]
    fn settings_roundtrip_via_rpc() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));

        let handlers = handlers(&gateway);
        enable_actions(&gateway);

        // Set a setting
        let set_handler = handlers
            .get("settings.set")
            .expect("settings.set registered");
        let set_payload = serde_json::json!({
            "section": "chat",
            "settings": {
                "sendMode": "enter",
                "suggestMode": "ctrl-enter",
                "streamIdleTimeoutMs": 600000,
                "showDirectorNotes": true,
                "combineSystemMessages": true
            }
        });
        let set_reply = set_handler("settings.set", &set_payload).expect("settings.set Ok");
        let set_v: serde_json::Value = set_reply;
        assert_eq!(set_v["ok"], true);

        // Get it back
        let get_handler = handlers
            .get("settings.get")
            .expect("settings.get registered");
        let get_payload = serde_json::json!({ "section": "chat" });
        let get_reply = get_handler("settings.get", &get_payload).expect("settings.get Ok");
        let get_v: serde_json::Value = get_reply;
        assert_eq!(get_v["section"], "chat");
        let settings_str = get_v["settings"].as_str().unwrap();
        let settings: serde_json::Value = serde_json::from_str(settings_str).unwrap();
        assert_eq!(settings.get("sendMode").unwrap(), "enter");
        assert_eq!(settings.get("suggestMode").unwrap(), "ctrl-enter");
    }

    #[test]
    fn chat_send_uses_stored_provider_and_model() {
        use std::sync::{mpsc, Arc};

        struct SelectionCapture {
            seen: mpsc::Sender<(String, String)>,
        }
        #[async_trait::async_trait]
        impl anima_llm::ChatProvider for SelectionCapture {
            fn id(&self) -> &str {
                "chosen"
            }
            async fn models(&self) -> Result<Vec<anima_llm::ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(
                &self,
                req: anima_llm::ChatRequest,
            ) -> Result<anima_llm::ChatStream, anima_llm::LlmError> {
                let _ = self.seen.send((self.id().to_string(), req.model.clone()));
                Ok(Box::pin(futures_util::stream::iter(vec![Ok(
                    anima_llm::ChatChunk::finish("stop"),
                )])))
            }
        }

        let (gateway, _tmp) = isolated_gateway();
        let (tx, rx) = mpsc::channel();
        let svc = gateway.core.chat_service().unwrap();
        svc.providers.lock().unwrap().insert(
            "chosen".to_string(),
            Arc::new(SelectionCapture { seen: tx }),
        );
        let db = gateway.core.db().unwrap();
        anima_store::ProviderRepo::new(db)
            .upsert(&anima_store::StoredProvider {
                id: "chosen".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "stored-model" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        handlers.get("chat.send").unwrap()(
            "chat.send",
            &serde_json::json!({ "sessionId": "selection-session", "content": "hello" }),
        )
        .expect("chat.send Ok");
        let (provider_id, model) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
        assert_eq!(provider_id, "chosen");
        assert_eq!(model, "stored-model");
    }

    #[test]
    fn providers_list_never_contains_secrets() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));

        let handlers = handlers(&gateway);
        let handler = handlers
            .get("providers.list")
            .expect("providers.list registered");
        let reply = handler("providers.list", &serde_json::json!({})).expect("providers.list Ok");
        let v: serde_json::Value = reply;

        // Check the serialized reply has no secret-bearing fields
        let obj = v.as_object().unwrap();
        let providers = obj.get("providers").and_then(|p| p.as_array());
        if let Some(providers) = providers {
            for provider in providers {
                let p = provider.as_object().unwrap();
                assert!(
                    !p.contains_key("apiKey"),
                    "apiKey must not be in provider list"
                );
                assert!(
                    !p.contains_key("api_key"),
                    "api_key must not be in provider list"
                );
                assert!(
                    !p.contains_key("secret"),
                    "secret must not be in provider list"
                );
                assert!(
                    !p.contains_key("token"),
                    "token must not be in provider list"
                );
                assert!(
                    !p.contains_key("config"),
                    "config must not be in provider list"
                );
            }
        }
    }

    #[test]
    fn vault_status_never_contains_secrets() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        let gateway = test_gateway(dir.clone(), dir.join(CERTS_DIR));

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let handler = handlers
            .get("vault.status")
            .expect("vault.status registered");
        let reply = handler("vault.status", &serde_json::json!({})).expect("vault.status Ok");
        let v: serde_json::Value = reply;

        // Check the serialized reply has no secret-bearing fields
        let obj = v.as_object().unwrap();
        assert!(!obj.contains_key("apiKey"));
        assert!(!obj.contains_key("secret"));
        assert!(!obj.contains_key("token"));
        assert!(!obj.contains_key("config"));
        assert!(!obj.contains_key("keys"));
        assert!(!obj.contains_key("ciphertext"));
    }

    #[test]
    fn chat_send_stop_end_to_end() {
        use anima_llm::{ChatChunk, ChatRequest, ChatStream, ModelInfo};
        use async_trait::async_trait;
        use futures_util::stream;
        use std::sync::Arc;

        /// Provider that never yields a delta (pends forever) — exercises
        /// cancellation via the poll ticker rather than stream completion.
        struct PendingMock;
        #[async_trait]
        impl anima_llm::ChatProvider for PendingMock {
            fn id(&self) -> &str {
                "e2e-stop"
            }
            async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(&self, _req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
                Ok(Box::pin(stream::pending::<
                    Result<ChatChunk, anima_llm::LlmError>,
                >()))
            }
        }

        let (gateway, _tmp) = isolated_gateway();

        // Register the never-yielding provider on the daemon-owned ChatService
        // and persist a row so `chat.send` actually starts a generation — a
        // cancel is only honest when something is in flight.
        let svc = gateway.core.chat_service().expect("chat service");
        svc.providers
            .lock()
            .unwrap()
            .insert("e2e-stop".to_string(), Arc::new(PendingMock));
        let db = gateway.core.db().unwrap();
        anima_store::ProviderRepo::new(db)
            .upsert(&anima_store::StoredProvider {
                id: "e2e-stop".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();

        // The gate reads config.json per call, so opt in before invoking
        // chat.cancel in this fixture (isolated_gateway starts fail-closed).
        enable_actions(&gateway);
        let handlers = handlers(&gateway);

        // Start the stream (pends forever).
        let send = handlers.get("chat.send").expect("chat.send registered");
        let reply = send(
            "chat.send",
            &serde_json::json!({"sessionId":"stop-session","content":"stop me"}),
        )
        .expect("chat.send Ok");
        assert_eq!(reply["accepted"], true);

        // Give the pump a moment to register its cancel flag.
        std::thread::sleep(std::time::Duration::from_millis(50));

        // Cancel -> pump breaks on cancel flag, ChatService::stop halts generation.
        let cancel = handlers.get("chat.cancel").expect("chat.cancel registered");
        let creply = cancel(
            "chat.cancel",
            &serde_json::json!({"session_id":"stop-session"}),
        )
        .expect("chat.cancel Ok");
        assert_eq!(creply["cancelled"], true);
    }

    #[test]
    fn mcp_acp_handler_enforces_server_deadline() {
        let start = Instant::now();
        let err = with_mcp_acp_deadline(Duration::from_millis(200), || {
            std::thread::sleep(Duration::from_secs(60));
            Ok(serde_json::json!({}))
        })
        .expect_err("handler must be bounded by the server deadline");
        assert!(err.contains("server deadline"));
        assert!(start.elapsed() < Duration::from_secs(2));
    }

    #[test]
    fn apply_reply_reports_bound_tls_not_persisted_flag() {
        anima_channel::install_default_crypto_provider();
        let (gateway, _tmp) = fresh_gateway();
        // TLS enabled: the reply must say `{}`, not `null`, or clients fall
        // back to ws://. Use an explicit flag on loopback so the test is
        // deterministic across hosts (no reliance on a bindable LAN IP).
        let reply = gateway.handle(&GatewayRequest::Apply(r#"{"tlsConfig":{}}"#.into()));
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(v["websocketTlsConfig"], serde_json::json!({}));
        assert_eq!(get_json(&gateway)["tlsEnabled"], true);
        // Disable TLS: plaintext is restored and reported as null.
        let reply = gateway.handle(&GatewayRequest::Apply(
            r#"{"websocketTlsConfig":null}"#.into(),
        ));
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert!(v["websocketTlsConfig"].is_null());
        assert_eq!(get_json(&gateway)["tlsEnabled"], false);
    }

    #[test]
    fn execution_verbs_are_denied_by_default() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        for method in [
            "chat.cancel",
            "sessions.import",
            "mcp.list_servers",
            "mcp.tools_list",
            "mcp.tools_call",
            "mcp.call_tool",
            "acp.run",
            "acp.prompt",
            "acp.list_sessions",
        ] {
            let h = handlers
                .get(method)
                .unwrap_or_else(|| panic!("{method} must stay registered"));
            let err = h(method, &serde_json::json!({}))
                .expect_err("execution verb must be denied by default");
            assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "{method}: {err}");
        }
    }

    #[test]
    fn read_only_acp_list_agents_bypasses_actions_gate() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        let h = handlers.get("acp.list_agents").expect("registered");
        // Fails for the documented "not implemented" reason, not the gate:
        // read-only verbs must remain callable without opt-in.
        let err = h("acp.list_agents", &serde_json::json!({})).expect_err("not implemented");
        assert!(
            !err.starts_with(ACTIONS_DISABLED_PREFIX),
            "read-only verb must bypass the gate: {err}"
        );
    }

    #[test]
    fn regenerate_token_reports_ok_false_when_rebind_fails() {
        let tmp = tempfile::tempdir().unwrap();
        let dir = tmp.path().join("server-channel");
        // cert_dir is a *file*, so a TLS bind fails deterministically.
        let cert_dir = tmp.path().join("certs-blocker");
        fs::write(&cert_dir, "not a dir").unwrap();
        let gateway = test_gateway(dir.clone(), cert_dir);
        let mut config = ChannelConfig::healed();
        config.tls_config = Some(serde_json::json!({}));
        fs::create_dir_all(&dir).unwrap();
        fs::write(
            &gateway.config_path,
            serde_json::to_string_pretty(&config).unwrap(),
        )
        .unwrap();
        gateway.bind_once(&config);
        assert_eq!(get_json(&gateway)["bound"], false);

        let reply = gateway.handle(&GatewayRequest::RegenerateToken);
        let v: serde_json::Value = serde_json::from_str(&reply).unwrap();
        assert_eq!(
            v["ok"], false,
            "unbound rotation must not look like success"
        );
        assert!(v["error"].as_str().is_some_and(|e| !e.is_empty()));
        assert!(
            v["authToken"].is_null(),
            "never return a token that nothing is listening for"
        );
    }

    #[test]
    fn card_metadata_rpc_persists_explicit_flags() {
        // Isolated store: `fresh_gateway()` intentionally uses the real
        // data dir, which another test run may have already written to.
        let (gateway, _tmp) = isolated_gateway();

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let defaults = handlers
            .get("cards.metadata")
            .expect("cards.metadata registered");
        let reply = defaults("cards.metadata", &serde_json::json!({ "id": "card-1" }))
            .expect("default metadata read");
        assert_eq!(
            reply,
            serde_json::json!({ "id": "card-1", "liked": false, "bookmarked": false })
        );

        let set = handlers
            .get("cards.metadata.set")
            .expect("cards.metadata.set registered");
        let reply = set(
            "cards.metadata.set",
            &serde_json::json!({ "id": "card-1", "liked": true, "bookmarked": true }),
        )
        .expect("metadata write");
        assert_eq!(
            reply,
            serde_json::json!({ "id": "card-1", "liked": true, "bookmarked": true })
        );

        // Explicit booleans, not flips: writing `false` for liked keeps the
        // bookmarked flag intact.
        let reply = set(
            "cards.metadata.set",
            &serde_json::json!({ "id": "card-1", "liked": false, "bookmarked": true }),
        )
        .expect("second metadata write");
        assert_eq!(
            reply,
            serde_json::json!({ "id": "card-1", "liked": false, "bookmarked": true })
        );

        let reply = defaults("cards.metadata", &serde_json::json!({ "id": "card-1" }))
            .expect("metadata read-back");
        assert_eq!(
            reply,
            serde_json::json!({ "id": "card-1", "liked": false, "bookmarked": true })
        );

        assert!(
            set(
                "cards.metadata.set",
                &serde_json::json!({ "id": "card-1", "liked": "yes", "bookmarked": true }),
            )
            .is_err(),
            "non-boolean flags must be rejected"
        );
    }

    #[test]
    fn cards_list_get_roundtrip_full_fidelity() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers(&gateway);
        let create = handlers
            .get("cards.create")
            .expect("cards.create registered");
        let doc = serde_json::json!({
            "spec": "chara_card_v2",
            "data": {
                "name": "Aria",
                "description": "test",
                "extensions": { "airi": { "model": "vrm" } },
                "x_unknown": 42
            }
        });
        let created = create(
            "cards.create",
            &serde_json::json!({ "name": "Aria", "document": doc }),
        )
        .unwrap();
        let id = created["id"].as_str().unwrap();
        let list = handlers.get("cards.list").unwrap();
        let listed = list("cards.list", &serde_json::json!({})).unwrap();
        assert_eq!(listed["cards"][0]["id"], id);
        assert_eq!(listed["cards"][0]["name"], "Aria");
        let get = handlers.get("cards.get").unwrap();
        let got = get("cards.get", &serde_json::json!({ "id": id })).unwrap();
        assert_eq!(got["card"]["data"]["extensions"]["airi"]["model"], "vrm");
        assert_eq!(got["card"]["data"]["x_unknown"], 42);
    }

    #[test]
    fn cards_import_renames_on_collision() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers(&gateway);
        let import = handlers
            .get("cards.import")
            .expect("cards.import registered");
        let doc = serde_json::json!({ "spec": "chara_card_v2", "data": { "name": "Bob" } });
        let first = import("cards.import", &serde_json::json!({ "card": doc })).unwrap();
        assert_eq!(first["renamed"], false);
        let second = import("cards.import", &serde_json::json!({ "card": doc })).unwrap();
        assert_eq!(second["renamed"], true);
        assert_ne!(first["id"], second["id"]);
    }

    #[test]
    fn cards_update_replaces_document() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers(&gateway);
        let create = handlers.get("cards.create").unwrap();
        let created = create("cards.create", &serde_json::json!({ "name": "Old", "document": { "spec": "chara_card_v2", "data": { "name": "Old" } } })).unwrap();
        let id = created["id"].as_str().unwrap();
        let update = handlers.get("cards.update").unwrap();
        let new_doc = serde_json::json!({ "spec": "chara_card_v2", "data": { "name": "New" } });
        let updated = update(
            "cards.update",
            &serde_json::json!({ "id": id, "document": new_doc }),
        )
        .unwrap();
        assert_eq!(updated["updated"], true);
        let get = handlers.get("cards.get").unwrap();
        let got = get("cards.get", &serde_json::json!({ "id": id })).unwrap();
        assert_eq!(got["card"]["data"]["name"], "New");
    }

    #[test]
    fn cards_delete_is_idempotent() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers(&gateway);
        let create = handlers.get("cards.create").unwrap();
        let created = create("cards.create", &serde_json::json!({ "name": "Temp", "document": { "spec": "chara_card_v2", "data": { "name": "Temp" } } })).unwrap();
        let id = created["id"].as_str().unwrap();
        let delete = handlers.get("cards.delete").unwrap();
        let first = delete("cards.delete", &serde_json::json!({ "id": id })).unwrap();
        assert_eq!(first["deleted"], true);
        let second = delete("cards.delete", &serde_json::json!({ "id": id })).unwrap();
        assert_eq!(second["deleted"], false);
    }

    #[test]
    fn card_write_verbs_are_gated() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        for verb in &[
            "cards.create",
            "cards.update",
            "cards.delete",
            "cards.import",
        ] {
            let h = handlers
                .get(*verb)
                .unwrap_or_else(|| panic!("{verb} registered"));
            let err = h(verb, &serde_json::json!({})).expect_err("gated verb must deny");
            assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "{verb}: {err}");
        }
    }

    #[test]
    fn chat_history_replays_persisted_turns() {
        let (gateway, _tmp) = isolated_gateway();
        gateway.core.chat_send("h1", "first").unwrap();
        gateway.core.chat_send("h1", "second").unwrap();
        gateway.core.chat_send("h2", "other").unwrap();
        let handlers = handlers(&gateway);
        let h = handlers
            .get("chat.history")
            .expect("chat.history registered");
        let reply = h("chat.history", &serde_json::json!({ "session_id": "h1" })).unwrap();
        assert_eq!(reply["sessionId"], "h1");
        let messages = reply["messages"].as_array().unwrap();
        assert_eq!(messages.len(), 2);
        assert_eq!(messages[0]["content"], "first");
        assert_eq!(messages[1]["content"], "second");
        assert_eq!(messages[0]["sessionId"], "h1");
        h("chat.history", &serde_json::json!({ "session_id": "" }))
            .expect_err("missing session_id must fail");
    }

    #[test]
    fn providers_save_delete_roundtrip_without_secrets() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let save = handlers.get("providers.save").unwrap();
        let reply = save(
            "providers.save",
            &serde_json::json!({
                "id": "p1",
                "kind": "open-ai-compatible",
                "model": "gpt-x",
                "baseUrl": "https://example.test/v1",
                "apiKey": "TOP-SECRET",
                "enabled": true,
            }),
        )
        .unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["id"], "p1");
        assert!(
            !reply.to_string().contains("TOP-SECRET"),
            "reply must not echo the key"
        );

        let list = handlers.get("providers.list").unwrap();
        let listed = list("providers.list", &serde_json::json!({})).unwrap();
        assert_eq!(listed["providers"][0]["baseUrl"], "https://example.test/v1");
        assert_eq!(listed["providers"][0]["model"], "gpt-x");
        assert!(!listed.to_string().contains("TOP-SECRET"));

        // A partial update must not drop the stored secret.
        save(
            "providers.save",
            &serde_json::json!({ "id": "p1", "kind": "open-ai-compatible", "enabled": false }),
        )
        .unwrap();
        let db = gateway.core.db().unwrap();
        let stored = anima_store::ProviderRepo::new(db)
            .get("p1")
            .unwrap()
            .unwrap();
        assert_eq!(stored.config["api_key"], "TOP-SECRET");
        assert!(!stored.enabled);

        let delete = handlers.get("providers.delete").unwrap();
        let reply = delete("providers.delete", &serde_json::json!({ "id": "p1" })).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["deleted"], true);
        let listed = list("providers.list", &serde_json::json!({})).unwrap();
        assert_eq!(listed["providers"].as_array().unwrap().len(), 0);
    }

    #[test]
    fn providers_save_patch_cannot_rotate_a_nested_secret() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let save = handlers.get("providers.save").unwrap();
        save(
            "providers.save",
            &serde_json::json!({
                "id": "p2",
                "kind": "open-ai-compatible",
                "model": "gpt-x",
                "enabled": true,
            }),
        )
        .unwrap();

        // Seed a nested secret-shaped key via the store, then PATCH only a
        // non-secret field and confirm the stored secret survives.
        let db = gateway.core.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        let mut stored = repo.get("p2").unwrap().unwrap();
        stored.config["access_token"] = serde_json::json!("STORED-TOKEN");
        repo.upsert(&stored).unwrap();

        save(
            "providers.save",
            &serde_json::json!({ "id": "p2", "kind": "open-ai-compatible", "model": "gpt-y" }),
        )
        .unwrap();
        let after = repo.get("p2").unwrap().unwrap();
        assert_eq!(after.config["access_token"], "STORED-TOKEN");
        assert_eq!(after.config["model"], "gpt-y");
    }

    // Contract: a PATCH that names only a non-secret field must leave every
    // unmentioned stored config entry alone, and must not disturb `enabled`
    // when the payload omits it.
    #[test]
    fn providers_save_partial_update_preserves_unrelated_config_and_enabled() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let save = handlers.get("providers.save").unwrap();
        save(
            "providers.save",
            &serde_json::json!({
                "id": "partial",
                "kind": "open-ai-compatible",
                "model": "gpt-initial",
                "baseUrl": "https://initial.test/v1",
                "enabled": false,
            }),
        )
        .unwrap();

        let db = gateway.core.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        let mut seeded = repo.get("partial").unwrap().unwrap();
        seeded.config["account_id"] = serde_json::json!("acct-7");
        repo.upsert(&seeded).unwrap();

        let reply = save(
            "providers.save",
            &serde_json::json!({
                "id": "partial",
                "kind": "open-ai-compatible",
                "model": "gpt-patched",
            }),
        )
        .unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["id"], "partial");

        let stored = repo.get("partial").unwrap().unwrap();
        assert_eq!(stored.config["model"], "gpt-patched");
        assert_eq!(stored.config["base_url"], "https://initial.test/v1");
        assert_eq!(stored.config["account_id"], "acct-7");
        assert!(
            !stored.enabled,
            "an omitted `enabled` must keep the stored flag, not default to true"
        );

        // The projection reports the same state on the wire.
        let list = handlers.get("providers.list").unwrap();
        let listed = list("providers.list", &serde_json::json!({})).unwrap();
        let row = listed["providers"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == "partial")
            .expect("saved provider must be listed");
        assert_eq!(row["model"], "gpt-patched");
        assert_eq!(row["baseUrl"], "https://initial.test/v1");
        assert_eq!(row["enabled"], false);
    }

    // Contract: the same PATCH+rotate sequence over one stored credential —
    // a client-sent apiKey is inert without the opt-in, and replaces the
    // stored secret only with literal `rotateSecrets: true`.
    #[test]
    fn providers_save_secret_rotation_contract() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let save = handlers.get("providers.save").unwrap();
        save(
            "providers.save",
            &serde_json::json!({
                "id": "creds",
                "kind": "open-ai-compatible",
                "model": "gpt-v1",
                "apiKey": "STORED-KEY",
            }),
        )
        .unwrap();

        let db = gateway.core.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);

        // No opt-in: the stored credential wins over the incoming one.
        save(
            "providers.save",
            &serde_json::json!({
                "id": "creds",
                "kind": "open-ai-compatible",
                "apiKey": "CLIENT-KEY",
            }),
        )
        .unwrap();
        assert_eq!(
            repo.get("creds").unwrap().unwrap().config["api_key"],
            "STORED-KEY"
        );

        // Explicit opt-in: the incoming credential replaces it, keeping the
        // stored key spelling so no second secret field appears.
        save(
            "providers.save",
            &serde_json::json!({
                "id": "creds",
                "kind": "open-ai-compatible",
                "model": "gpt-v2",
                "apiKey": "ROTATED-KEY",
                "rotateSecrets": true,
            }),
        )
        .unwrap();
        let stored = repo.get("creds").unwrap().unwrap();
        assert_eq!(stored.config["api_key"], "ROTATED-KEY");
        assert_eq!(stored.config["model"], "gpt-v2");
        assert!(
            stored.config.get("apiKey").is_none(),
            "rotation must not leave a camelCase duplicate"
        );
        assert!(!stored.config.to_string().contains("CLIENT-KEY"));

        // Neither the stored nor the rotated credential reaches the wire.
        let list = handlers.get("providers.list").unwrap();
        let listed = list("providers.list", &serde_json::json!({})).unwrap();
        let text = listed.to_string();
        assert!(!text.contains("ROTATED-KEY"), "{text}");
        assert!(!text.contains("STORED-KEY"), "{text}");
    }

    // Contract: delete reports whether a row was actually removed, and a
    // second delete of the same id reports `false` instead of failing.
    #[test]
    fn providers_delete_reports_whether_a_row_was_removed() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let save = handlers.get("providers.save").unwrap();
        save(
            "providers.save",
            &serde_json::json!({
                "id": "gone",
                "kind": "open-ai-compatible",
                "model": "gpt-x",
            }),
        )
        .unwrap();

        let delete = handlers.get("providers.delete").unwrap();
        let reply = delete("providers.delete", &serde_json::json!({ "id": "gone" })).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(reply["deleted"], true);

        let db = gateway.core.db().unwrap();
        let repo = anima_store::ProviderRepo::new(db);
        assert!(repo.get("gone").unwrap().is_none(), "row must be gone");

        let reply = delete("providers.delete", &serde_json::json!({ "id": "gone" })).unwrap();
        assert_eq!(reply["ok"], true);
        assert_eq!(
            reply["deleted"], false,
            "deleting an unknown id must report false, not fail"
        );

        let list = handlers.get("providers.list").unwrap();
        let listed = list("providers.list", &serde_json::json!({})).unwrap();
        assert_eq!(listed["providers"].as_array().unwrap().len(), 0);
        assert!(
            delete("providers.delete", &serde_json::json!({})).is_err(),
            "a delete without an id must fail"
        );
    }

    #[test]
    fn general_settings_roundtrip_via_rpc() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let set = handlers.get("settings.set").unwrap();
        set(
            "settings.set",
            &serde_json::json!({
                "section": "general",
                "settings": { "language": "de", "disableTransitions": false },
            }),
        )
        .unwrap();
        let get = handlers.get("settings.get").unwrap();
        let reply = get("settings.get", &serde_json::json!({ "section": "general" })).unwrap();
        assert_eq!(reply["section"], "general");
        let settings: serde_json::Value =
            serde_json::from_str(reply["settings"].as_str().unwrap()).unwrap();
        assert_eq!(settings["language"], "de");
        assert_eq!(settings["disableTransitions"], false);
    }

    #[test]
    fn chat_send_uses_requested_session_and_indexes_deltas() {
        use anima_llm::{ChatChunk, ChatRequest, ChatStream, ModelInfo};
        use async_trait::async_trait;
        use futures_util::stream;
        use std::sync::Arc;

        struct MultiDeltaMock;
        #[async_trait]
        impl anima_llm::ChatProvider for MultiDeltaMock {
            fn id(&self) -> &str {
                "e2e-index"
            }
            async fn models(&self) -> Result<Vec<ModelInfo>, anima_llm::LlmError> {
                Ok(vec![])
            }
            async fn stream(&self, _req: ChatRequest) -> Result<ChatStream, anima_llm::LlmError> {
                Ok(Box::pin(stream::iter(vec![
                    Ok(ChatChunk::text("a")),
                    Ok(ChatChunk::text("b")),
                    Ok(ChatChunk::text("c")),
                ])))
            }
        }

        let (gateway, _tmp) = isolated_gateway();
        let lane = gateway.publisher().bus().new_lane();
        lane.subscribe(anima_channel::EventTopic::ALL);
        gateway.publisher().bus().register_lane(&lane);

        let svc = gateway.core.chat_service().unwrap();
        svc.providers
            .lock()
            .unwrap()
            .insert("e2e-index".to_string(), Arc::new(MultiDeltaMock));
        let db = gateway.core.db().unwrap();
        anima_store::ProviderRepo::new(db)
            .upsert(&anima_store::StoredProvider {
                id: "e2e-index".to_string(),
                kind: anima_store::ProviderKind::OpenAiCompatible,
                config: serde_json::json!({ "model": "test-model" }),
                enabled: true,
                updated_at: 0,
            })
            .unwrap();

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let send = handlers.get("chat.send").unwrap();
        let reply = send(
            "chat.send",
            &serde_json::json!({ "sessionId": "idx-session", "content": "hi" }),
        )
        .unwrap();
        assert_eq!(reply["sessionId"], "idx-session");
        assert_eq!(reply["accepted"], true);

        let mut indices = Vec::new();
        let mut final_index = None;
        // The turn runs on a background thread with its own Tokio runtime;
        // under parallel test load its terminal event can exceed 1s.
        for _ in 0..2000 {
            for event in lane.drain() {
                if let anima_channel::EventPayload::TokenDelta(d) = event.data {
                    if d.session_id == "idx-session" {
                        if d.final_ {
                            final_index = Some(d.index);
                        } else {
                            indices.push(d.index);
                        }
                    }
                }
            }
            if final_index.is_some() && indices.len() >= 3 {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        assert_eq!(
            indices,
            vec![0, 1, 2],
            "per-message token indices must advance"
        );
        assert_eq!(
            final_index,
            Some(3),
            "terminal marker follows the last token"
        );

        // F1: exactly one user turn, in the session id returned by the ack.
        let history = gateway.core.chat_stream("idx-session").unwrap();
        let user_turns: Vec<_> = history.iter().filter(|m| m.role == "user").collect();
        assert_eq!(
            user_turns.len(),
            1,
            "send_message persists the user turn once"
        );
        assert_eq!(user_turns[0].content, "hi");
        let sessions = anima_store::SessionRepo::new(gateway.core.db().unwrap())
            .list()
            .unwrap();
        assert_eq!(sessions.len(), 1, "no phantom second session");
    }

    #[test]
    fn rpc_limit_is_clamped() {
        assert_eq!(rpc_limit(&serde_json::json!({}), 50), 50);
        assert_eq!(rpc_limit(&serde_json::json!({ "limit": 3 }), 50), 3);
        assert_eq!(
            rpc_limit(&serde_json::json!({ "limit": u64::MAX }), 50),
            RPC_MAX_LIMIT
        );
        assert_eq!(rpc_limit(&serde_json::json!({ "limit": 0 }), 50), 1);
        assert_eq!(rpc_limit(&serde_json::json!({ "limit": "x" }), 50), 50);
    }

    #[test]
    fn journal_search_finds_matches_beyond_the_oldest_1000_rows() {
        let (gateway, _tmp) = isolated_gateway();
        let repo = anima_store::JournalRepo::new(gateway.core.db().unwrap());
        // Needle is the *oldest* entry, far outside the old 1000-row window.
        repo.append("note", "needle-in-the-oldest-entry", None)
            .unwrap();
        for i in 0..1005 {
            repo.append("note", &format!("filler entry {i}"), None)
                .unwrap();
        }
        let handlers = handlers(&gateway);
        let search = handlers.get("journal.search").unwrap();
        let reply = search(
            "journal.search",
            &serde_json::json!({ "query": "needle-in-the-oldest-entry", "limit": 5 }),
        )
        .unwrap();
        let entries = reply["entries"].as_array().unwrap();
        assert_eq!(
            entries.len(),
            1,
            "matches outside the newest 1000 must be found"
        );
        assert_eq!(entries[0]["content"], "needle-in-the-oldest-entry");
        assert_eq!(reply["truncated"], false);
    }

    // Contract: the no-provider terminal marker carries the assistant message
    // id minted for the turn (the same id the `chat.send` ack returns), so a
    // client keys the error bubble on the turn instead of an anonymous
    // stream-active flag.
    #[test]
    fn chat_send_without_provider_finalizes_with_the_ack_message_id() {
        let (gateway, _tmp) = isolated_gateway();
        let lane = gateway.publisher().bus().new_lane();
        lane.subscribe(anima_channel::EventTopic::ALL);
        gateway.publisher().bus().register_lane(&lane);

        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        let send = handlers.get("chat.send").unwrap();
        let reply = send(
            "chat.send",
            &serde_json::json!({ "sessionId": "no-provider", "content": "hi" }),
        )
        .unwrap();
        let ack_id = reply["messageId"].as_str().unwrap().to_string();
        assert!(!ack_id.is_empty(), "ack must carry an assistant id");

        let mut terminal = None;
        for _ in 0..400 {
            for event in lane.drain() {
                if let anima_channel::EventPayload::TokenDelta(d) = event.data {
                    if d.session_id == "no-provider" && d.final_ {
                        terminal = Some(d);
                    }
                }
            }
            if terminal.is_some() {
                break;
            }
            std::thread::sleep(std::time::Duration::from_millis(5));
        }
        let terminal = terminal.expect("no-provider turn must end with a terminal delta");
        assert_eq!(terminal.message_id, ack_id);
        assert!(terminal.delta.is_empty());
    }

    // Contract: both MCP tool-call spellings run one implementation, so a
    // missing tool name is the same boundary error on either verb.
    #[test]
    fn mcp_tool_call_verbs_share_one_implementation() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        enable_actions(&gateway);
        for method in ["mcp.tools_call", "mcp.call_tool"] {
            let handler = handlers
                .get(method)
                .unwrap_or_else(|| panic!("{method} must stay registered"));
            let err = handler(method, &serde_json::json!({ "transport": "stdio" }))
                .expect_err("a call without a tool name must fail");
            assert_eq!(err, "missing tool name (tool/name/tool_name)");
        }
    }

    // Contract: `sessions.list` pages with a default of 50 and clamps a
    // client-supplied limit to `RPC_MAX_LIMIT`.
    #[test]
    fn sessions_list_is_bounded_by_default_and_clamped_limit() {
        let (gateway, _tmp) = isolated_gateway();
        let repo = anima_store::SessionRepo::new(gateway.core.db().unwrap());
        for i in 0..(DEFAULT_LIST_LIMIT + 5) {
            repo.create(&format!("s{i}"), "title").unwrap();
        }
        let handlers = handlers(&gateway);
        let list = handlers.get("sessions.list").unwrap();

        let default = list("sessions.list", &serde_json::json!({})).unwrap();
        assert_eq!(
            default["sessions"].as_array().unwrap().len(),
            DEFAULT_LIST_LIMIT
        );
        assert_eq!(default["truncated"], true);

        let clamped = list("sessions.list", &serde_json::json!({ "limit": u64::MAX })).unwrap();
        assert_eq!(
            clamped["sessions"].as_array().unwrap().len(),
            DEFAULT_LIST_LIMIT + 5,
            "a huge limit clamps to RPC_MAX_LIMIT, above the row count here"
        );
        assert_eq!(clamped["truncated"], false);
    }

    // Contract: `sessions.delete` removes the session and its messages through
    // the daemon-owned store, and reports `false` (not an error) when the
    // session is already gone.
    #[test]
    fn sessions_delete_removes_session_and_messages_and_reports_missing() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let db = gateway.core.db().unwrap();
        let sessions = anima_store::SessionRepo::new(db.clone());
        let messages = anima_store::MessageRepo::new(db);
        sessions.create("del-1", "delete me").unwrap();
        messages
            .insert(&anima_store::StoredMessage {
                id: "del-msg-1".into(),
                session_id: "del-1".into(),
                role: "user".into(),
                content: "hi".into(),
                created_at: 1,
                metadata: serde_json::json!({}),
            })
            .unwrap();

        let handlers = handlers(&gateway);
        let delete = handlers.get("sessions.delete").unwrap();

        let reply = delete(
            "sessions.delete",
            &serde_json::json!({ "sessionId": "del-1" }),
        )
        .unwrap();
        assert_eq!(reply["deleted"], true);
        assert!(sessions.get("del-1").unwrap().is_none());
        assert!(messages.list("del-1").unwrap().is_empty());

        // Deleting again is an idempotent success, never an error: the client
        // must be able to clear a stale row without a special case.
        let again = delete(
            "sessions.delete",
            &serde_json::json!({ "sessionId": "del-1" }),
        )
        .unwrap();
        assert_eq!(again["deleted"], false);

        // A malformed request is a typed boundary failure, not an empty-id
        // delete that silently reports `false`.
        let err = delete("sessions.delete", &serde_json::json!({}))
            .expect_err("a request without a session id must fail");
        assert_eq!(err, "invalid request");
    }

    // Contract: `sessions.delete` is a write, so it stays denied until the
    // operator opts in with `allowActions`.
    #[test]
    fn sessions_delete_is_denied_without_actions_opt_in() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = handlers(&gateway);
        let delete = handlers
            .get("sessions.delete")
            .expect("sessions.delete must stay registered");
        let err = delete(
            "sessions.delete",
            &serde_json::json!({ "session_id": "s1" }),
        )
        .expect_err("delete must be denied by default");
        assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "{err}");
    }

    // Contract: the journal scan reads content-only columns, so a large
    // embedding blob is never pulled into memory or deserialized on a search.
    #[test]
    fn journal_search_ignores_embedding_payloads() {
        let (gateway, _tmp) = isolated_gateway();
        let repo = anima_store::JournalRepo::new(gateway.core.db().unwrap());
        let embedding = vec![0.25f32; 4096];
        repo.append("note", "needle-with-embedding", Some(&embedding))
            .unwrap();
        repo.append("note", "plain filler", None).unwrap();

        let handlers = handlers(&gateway);
        let search = handlers.get("journal.search").unwrap();
        let reply = search(
            "journal.search",
            &serde_json::json!({ "query": "needle-with-embedding", "limit": 5 }),
        )
        .unwrap();
        let entries = reply["entries"].as_array().unwrap();
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0]["content"], "needle-with-embedding");
        assert_eq!(entries[0]["kind"], "note");
        assert!(
            entries[0]["created_at"].is_i64(),
            "stored timestamp field names are unchanged"
        );
        assert!(
            entries[0].get("embedding").is_none(),
            "search rows are content-only"
        );
        assert_eq!(reply["truncated"], false);
    }

    #[test]
    fn mutating_verbs_are_denied_without_actions_opt_in() {
        let (gateway, _tmp) = isolated_gateway();
        // No allowActions key: mutating verbs must fail with the actions-
        // disabled prefix, and read-only verbs must still work.
        let handlers = handlers(&gateway);
        for method in [
            "settings.set",
            "journal.append",
            "journal.delete",
            "stmm.rebuild",
            "stmm.upsert",
            "stmm.delete",
            "chat.send",
        ] {
            let h = handlers
                .get(method)
                .unwrap_or_else(|| panic!("{method} must stay registered"));
            let err = h(method, &serde_json::json!({}))
                .expect_err("mutating verb must be denied by default");
            assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "{method}: {err}");
        }
        let read = handlers.get("core.status").unwrap();
        read("core.status", &serde_json::json!({}))
            .expect("read-only verb must work without opt-in");
    }

    #[test]
    fn actions_gate_maps_to_typed_rpc_error_and_allows_when_opted_in() {
        let (gateway, _tmp) = isolated_gateway();
        let handlers = std::sync::Arc::new(handlers(&gateway));

        // Disabled: the daemon returns the actions-disabled prefix, and the
        // channel dispatch maps it to the stable `rpc_actions_disabled` code.
        let set = handlers.get("settings.set").unwrap();
        let err = set(
            "settings.set",
            &serde_json::json!({ "section": "chat", "settings": {} }),
        )
        .expect_err("denied by default");
        assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "got: {err}");
        let rpc_err = anima_channel::dispatch::RpcRegistry::dispatch(
            &anima_channel::RpcContext::new("127.0.0.1", 6121),
            "settings.set",
            &serde_json::json!({ "section": "chat", "settings": {} }),
            &handlers,
        )
        .expect_err("dispatch must surface the refusal");
        assert_eq!(rpc_err.code(), "rpc_actions_disabled");

        // Opt in: the same verb now succeeds.
        enable_actions(&gateway);
        let reply = set(
            "settings.set",
            &serde_json::json!({ "section": "chat", "settings": {} }),
        )
        .expect("allowed when opted in");
        assert_eq!(reply["ok"], true);
    }

    #[test]
    fn actions_gate_rejects_non_boolean_opt_in() {
        let (gateway, _tmp) = isolated_gateway();
        let mut value = serde_json::to_value(ChannelConfig::healed()).unwrap();
        value["allowActions"] = serde_json::json!("true");
        fs::create_dir_all(gateway.config_path.parent().unwrap()).unwrap();
        fs::write(
            &gateway.config_path,
            serde_json::to_string_pretty(&value).unwrap(),
        )
        .unwrap();
        let handlers = handlers(&gateway);
        let err = handlers.get("journal.append").unwrap()(
            "journal.append",
            &serde_json::json!({ "content": "hi" }),
        )
        .expect_err("string \"true\" must not enable actions");
        assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "got: {err}");
    }

    #[test]
    fn persist_preserves_allow_actions_flag() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions_with_remote(&gateway, Some(serde_json::json!(true)));
        let raw = fs::read_to_string(&gateway.config_path).unwrap();
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(value["allowActions"], serde_json::json!(true));
        assert_eq!(value["allowRemoteActions"], serde_json::json!(true));
        // A D-Bus-style rewrite (e.g. token rotation) must not drop either flag.
        // ChannelConfig rewrites pass `allow_actions: None`, like `apply` and
        // `regenerate_token` do.
        let mut config = ChannelConfig::healed();
        config.allow_actions = None;
        Gateway::persist(&gateway.config_path, &config).unwrap();
        let raw = fs::read_to_string(&gateway.config_path).unwrap();
        let value: serde_json::Value = serde_json::from_str(&raw).unwrap();
        assert_eq!(value["allowActions"], serde_json::json!(true));
        assert_eq!(value["allowRemoteActions"], serde_json::json!(true));
        // After the rewrite, a non-loopback bind still permits mutating verbs.
        let handlers = handlers_with_hostname(&gateway, "192.168.1.10");
        handlers.get("journal.append").unwrap()(
            "journal.append",
            &serde_json::json!({ "content": "after rotation" }),
        )
        .expect("persist must keep the remote actions opt-in");
    }

    #[test]
    fn actions_gate_denies_mutating_verbs_on_non_loopback_host_without_remote_opt_in() {
        // A LAN/non-loopback bind must NOT keep mutating verbs enabled just
        // because allowActions is true: the bind-specific trust opt-in is
        // required too.
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers_with_hostname(&gateway, "192.168.1.10");
        let err = handlers.get("settings.set").unwrap()(
            "settings.set",
            &serde_json::json!({ "section": "chat", "settings": {} }),
        )
        .expect_err("LAN hostname must deny mutating verbs");
        assert!(
            err.starts_with(ACTIONS_DISABLED_PREFIX),
            "LAN denial must use the actions-disabled prefix: {err}"
        );
        assert!(
            err.contains("allowRemoteActions"),
            "error should name the missing opt-in: {err}"
        );
        assert!(
            !err.contains("authToken"),
            "error must never expose a credential"
        );
    }

    #[test]
    fn actions_gate_allows_mutating_verbs_on_non_loopback_host_with_remote_opt_in() {
        // An authenticated non-loopback client can mutate once the operator
        // has explicitly opted in to actions on that bind.
        let (gateway, _tmp) = isolated_gateway();
        enable_actions_with_remote(&gateway, Some(serde_json::json!(true)));
        let handlers = handlers_with_hostname(&gateway, "192.168.1.10");
        handlers.get("journal.append").unwrap()(
            "journal.append",
            &serde_json::json!({ "content": "remote hi" }),
        )
        .expect("non-loopback + both opt-ins must allow mutating verbs");
    }

    #[test]
    fn actions_gate_rejects_non_boolean_remote_opt_in() {
        // Only literal JSON true enables remote actions: false, a string, a
        // number, and null all fail closed.
        for remote in [
            serde_json::json!(false),
            serde_json::json!("true"),
            serde_json::json!(1),
            serde_json::Value::Null,
        ] {
            let (gateway, _tmp) = isolated_gateway();
            enable_actions_with_remote(&gateway, Some(remote.clone()));
            let handlers = handlers_with_hostname(&gateway, "192.168.1.10");
            let err = handlers.get("journal.append").unwrap()(
                "journal.append",
                &serde_json::json!({ "content": "hi" }),
            )
            .expect_err("non-boolean remote opt-in must deny mutating verbs");
            assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "got: {err}");
        }
    }

    #[test]
    fn remote_actions_opt_in_never_enables_actions_without_allow_actions() {
        let (gateway, _tmp) = isolated_gateway();
        let mut value = serde_json::to_value(ChannelConfig::healed()).unwrap();
        value["allowActions"] = serde_json::json!(false);
        value["allowRemoteActions"] = serde_json::json!(true);
        fs::write(
            &gateway.config_path,
            serde_json::to_string_pretty(&value).unwrap(),
        )
        .unwrap();
        for hostname in ["127.0.0.1", "192.168.1.10"] {
            let handlers = handlers_with_hostname(&gateway, hostname);
            let err = handlers.get("journal.append").unwrap()(
                "journal.append",
                &serde_json::json!({ "content": "hi" }),
            )
            .expect_err("remote opt-in must not override allowActions");
            assert!(err.starts_with(ACTIONS_DISABLED_PREFIX), "got: {err}");
        }
    }

    #[test]
    fn actions_gate_allows_mutating_verbs_on_loopback_host() {
        let (gateway, _tmp) = isolated_gateway();
        enable_actions(&gateway);
        let handlers = handlers_with_hostname(&gateway, "127.0.0.1");
        handlers.get("journal.append").unwrap()(
            "journal.append",
            &serde_json::json!({ "content": "hi" }),
        )
        .expect("loopback + opt-in must allow mutating verbs");
    }
}
