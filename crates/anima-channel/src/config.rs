// SPDX-License-Identifier: GPL-3.0-or-later

//! Auto-healing `server-channel/config.json` persistence.
//!
//! Mirrors the Electron stage-tamagotchi contract (`createConfig('server-channel',
//! 'config.json', …, { autoHeal: true })`): if the file is missing or invalid,
//! a fresh random `authToken` (UUIDv4) is generated and the file is rewritten.
//! The token is stored in **plaintext** — same posture as the Electron build,
//! no worse, no better. Protect the data dir accordingly.
//!
//! On-disk shape (the Electron `tlsConfig` flag is round-tripped verbatim —
//! anything else is tolerated on read but dropped on write):
//!
//! ```json
//! { "hostname": "127.0.0.1", "authToken": "<uuid-v4>", "tlsConfig": {}, "allowActions": true }
//! ```
//!
//! `tlsConfig` is an opaque flag object: absent/`null` = plaintext listener,
//! present (any object, even `{}`) = `wss://` with a locally minted CA +
//! SAN-covered server certificate (see [`crate::certs`]).
//!
//! `allowActions` is the strict opt-in for mutating WS verbs (chat.send,
//! settings.set, journal.append, MCP/ACP, …). A freshly healed config — the
//! single-user loopback daemon — writes `true`; parsing preserves only a
//! literal `true` (anything else stays absent, fail-closed); healing an
//! unparseable config drops it. Non-loopback binds stay fail-closed; see
//! `docs/design-daemon-gateway.md` (airi-f03).

use std::fs;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use crate::uuid::uuid_v4;

/// Default bind address. Loopback-only by default — see crate docs.
pub const DEFAULT_HOSTNAME: &str = "127.0.0.1";

/// The persisted channel-server configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, specta::Type)]
pub struct ChannelConfig {
    /// Bind address. Defaults to `127.0.0.1`; use `0.0.0.0` deliberately and
    /// only to permit LAN access (see crate-level security notes).
    pub hostname: String,
    /// Shared secret clients must present as the first message.
    #[serde(rename = "authToken")]
    pub auth_token: String,
    /// Opaque TLS flag: `Some(_)` = serve `wss://`; `None` = plaintext.
    /// Round-tripped verbatim so enabling TLS in one build survives a
    /// reload in another.
    #[serde(rename = "tlsConfig", default, skip_serializing_if = "Option::is_none")]
    // specta rejects serde_json::Value wholesale (BigInt-style Number inside);
    // the opaque flag exports as `unknown`, same as the frame payload fields.
    #[specta(type = specta_typescript::Unknown)]
    pub tls_config: Option<serde_json::Value>,
    /// Strict `allowActions` opt-in for mutating/executing WS verbs
    /// (`chat.send`, `settings.set`, `journal.append`, MCP/ACP, …).
    /// `Some(true)` allows; anything else (absent, `false`, wrong type)
    /// fails closed. Re-read per call by the gateway; never used to
    /// authenticate. See `docs/design-daemon-gateway.md` (airi-f03).
    #[serde(
        rename = "allowActions",
        default,
        skip_serializing_if = "Option::is_none"
    )]
    pub allow_actions: Option<bool>,
}

impl ChannelConfig {
    /// Construct a fresh config with a random token bound to loopback.
    ///
    /// The fresh config carries `"allowActions": true`: the healed default is
    /// the single-user loopback daemon, where thin clients (Flutter/Vue)
    /// need the mutating verbs (chat.send, settings.set, journal.append, …) to
    /// work out of the box. Non-loopback binds stay fail-closed — the gateway
    /// forces TLS there and operators must opt in explicitly. See
    /// `docs/design-daemon-gateway.md` (airi-f03).
    pub fn healed() -> Self {
        Self {
            hostname: DEFAULT_HOSTNAME.to_string(),
            auth_token: uuid_v4(),
            tls_config: None,
            allow_actions: Some(true),
        }
    }
}

/// Errors from config load/heal.
#[derive(Debug, thiserror::Error)]
pub enum ConfigError {
    /// Filesystem failure while reading or writing the config.
    #[error("config I/O error: {0}")]
    Io(#[from] io::Error),
}

/// Default config path: `<data-dir>/airi-slint/server-channel/config.json`.
///
/// Data dir resolution: `dirs::data_dir()` (Linux: `$XDG_DATA_HOME` or
/// `~/.local/share`; macOS: `~/Library/Application Support`; Windows:
/// `%APPDATA%`). Returns `None` when no data dir can be determined.
pub fn default_config_path() -> Option<PathBuf> {
    dirs::data_dir().map(|d| {
        d.join("airi-slint")
            .join("server-channel")
            .join("config.json")
    })
}

/// Load the config at `path`, healing it if missing or invalid.
///
/// - Missing file → created (parent dirs included) with a fresh token.
/// - Unreadable/unparseable JSON, or an empty/missing `authToken` → the token
///   is regenerated (a valid `hostname` is preserved if one was present;
///   otherwise loopback default) and the file is rewritten.
/// - Valid config → returned unchanged.
pub fn load_or_heal(path: &Path) -> Result<ChannelConfig, ConfigError> {
    match fs::read_to_string(path) {
        Ok(raw) => match parse_config(&raw) {
            Some(cfg) => Ok(cfg),
            None => heal_in_place(path, &raw),
        },
        Err(err) if err.kind() == io::ErrorKind::NotFound => {
            let cfg = ChannelConfig::healed();
            write_config(path, &cfg)?;
            Ok(cfg)
        }
        Err(err) => Err(ConfigError::Io(err)),
    }
}

/// Parse and validate raw JSON. Returns `None` if the config is unusable
/// (caller regenerates the token).
fn parse_config(raw: &str) -> Option<ChannelConfig> {
    let value: serde_json::Value = serde_json::from_str(raw).ok()?;
    let obj = value.as_object()?;

    let auth_token = obj.get("authToken")?.as_str()?.trim();
    if auth_token.is_empty() {
        return None;
    }

    let hostname = match obj.get("hostname") {
        Some(v) => v.as_str()?.trim().to_string(),
        None => DEFAULT_HOSTNAME.to_string(),
    };
    if hostname.is_empty() {
        return None;
    }

    // `tlsConfig` is an opaque flag: present (any JSON value except null)
    // means TLS. `null` means plaintext and is dropped on write.
    let tls_config = obj.get("tlsConfig").filter(|v| !v.is_null()).cloned();

    // Preserve `allowActions` verbatim: only literal JSON `true` enables
    // mutating verbs; anything else stays absent (fail-closed).
    let allow_actions = obj
        .get("allowActions")
        .and_then(|v| v.as_bool())
        .filter(|v| *v);

    Some(ChannelConfig {
        hostname,
        auth_token: auth_token.to_string(),
        tls_config,
        allow_actions,
    })
}

/// Rewrite `path` with a fresh token, preserving a usable hostname if present.
fn heal_in_place(path: &Path, raw: &str) -> Result<ChannelConfig, ConfigError> {
    let hostname = serde_json::from_str::<serde_json::Value>(raw)
        .ok()
        .and_then(|v| {
            v.get("hostname")
                .and_then(|h| h.as_str())
                .map(str::to_string)
        })
        .filter(|h| !h.trim().is_empty())
        .unwrap_or_else(|| DEFAULT_HOSTNAME.to_string());

    let tls_config = serde_json::from_str::<serde_json::Value>(raw)
        .ok()
        .and_then(|v| v.get("tlsConfig").cloned())
        .filter(|v| !v.is_null());
    // Healing drops `allowActions` (fail-closed): a config that could not be
    // parsed must not keep executing mutating verbs on a fresh token.
    let cfg = ChannelConfig {
        hostname,
        auth_token: uuid_v4(),
        tls_config,
        allow_actions: None,
    };
    write_config(path, &cfg)?;
    Ok(cfg)
}

/// Write the config, creating parent directories. Written `0600`: this file
/// carries the auth token, and any local uid that can read it can authenticate.
fn write_config(path: &Path, cfg: &ChannelConfig) -> Result<(), ConfigError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    // mode(0o600) only applies at creation; tighten explicitly so a
    // pre-existing 0644 file is fixed on rewrite.
    #[cfg(unix)]
    {
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
        let json = serde_json::to_string_pretty(cfg)
            .map_err(|e| ConfigError::Io(io::Error::new(io::ErrorKind::InvalidData, e)))?;
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(path)?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        io::Write::write_all(&mut file, json.as_bytes())?;
        Ok(())
    }
    #[cfg(not(unix))]
    {
        let json = serde_json::to_string_pretty(cfg)
            .map_err(|e| ConfigError::Io(io::Error::new(io::ErrorKind::InvalidData, e)))?;
        fs::write(path, json)?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrite_tightens_preexisting_0644() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, r#"{ "hostname": "127.0.0.1", "authToken": "keep" }"#).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        write_config(&path, &ChannelConfig::healed()).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "rewritten config.json must be owner-only");
    }

    #[test]
    fn config_file_is_owner_only() {
        use std::os::unix::fs::PermissionsExt;
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("server-channel").join("config.json");
        let cfg = load_or_heal(&path).unwrap();
        assert!(cfg.auth_token.len() == 36);
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(
            mode, 0o600,
            "config.json must never be world/group readable"
        );
    }

    #[test]
    fn missing_file_is_created_with_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir
            .path()
            .join("nested")
            .join("server-channel")
            .join("config.json");

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.hostname, DEFAULT_HOSTNAME);
        assert_eq!(cfg.auth_token.len(), 36); // canonical UUID shape
        assert!(path.exists());

        // Second load preserves the generated token.
        let again = load_or_heal(&path).unwrap();
        assert_eq!(again, cfg);
    }

    #[test]
    fn invalid_json_regenerates_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, "{ not json !").unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.hostname, DEFAULT_HOSTNAME);
        assert_eq!(cfg.auth_token.len(), 36);

        let rewritten: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(rewritten["authToken"].as_str().unwrap(), cfg.auth_token);
    }

    #[test]
    fn empty_auth_token_regenerates_token() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, r#"{ "hostname": "127.0.0.1", "authToken": "" }"#).unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert!(!cfg.auth_token.is_empty());
        assert_eq!(cfg.auth_token.len(), 36);
    }

    #[test]
    fn valid_config_is_preserved() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(
            &path,
            r#"{ "hostname": "0.0.0.0", "authToken": "keep-me" }"#,
        )
        .unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.hostname, "0.0.0.0");
        assert_eq!(cfg.auth_token, "keep-me");
    }

    #[test]
    fn tls_config_is_round_tripped() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(
            &path,
            r#"{ "hostname": "0.0.0.0", "authToken": "keep-me", "tlsConfig": {} }"#,
        )
        .unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.tls_config, Some(serde_json::json!({})));
        assert_eq!(cfg.auth_token, "keep-me");

        // Rewritten file keeps the flag.
        let raw = fs::read_to_string(&path).unwrap();
        assert!(raw.contains("tlsConfig"));
    }

    #[test]
    fn tls_config_null_remains_plaintext() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(
            &path,
            r#"{ "hostname": "0.0.0.0", "authToken": "keep-me", "tlsConfig": null }"#,
        )
        .unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.tls_config, None);
    }

    #[test]
    fn hostname_preserved_when_token_regenerated() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, r#"{ "hostname": "0.0.0.0", "authToken": "" }"#).unwrap();

        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.hostname, "0.0.0.0");
        assert_ne!(cfg.auth_token, "");
    }

    #[test]
    fn healed_config_opts_into_actions_for_local_use() {
        // Production healing is the single-user loopback daemon: it provisions
        // `allowActions: true` so thin clients' mutating verbs work out of the
        // box. Non-loopback binds stay fail-closed (see gateway docs).
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.allow_actions, Some(true));
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(raw["allowActions"], serde_json::json!(true));
    }

    #[test]
    fn allow_actions_parsing_is_strict() {
        let dir = tempfile::tempdir().unwrap();
        // Literal true survives; everything else stays absent (fail-closed).
        for (raw, expected) in [
            (r#"{ "authToken": "t", "allowActions": true }"#, Some(true)),
            (r#"{ "authToken": "t", "allowActions": false }"#, None),
            (r#"{ "authToken": "t", "allowActions": "true" }"#, None),
            (r#"{ "authToken": "t", "allowActions": 1 }"#, None),
            (r#"{ "authToken": "t" }"#, None),
        ] {
            let path = dir.path().join("config.json");
            fs::write(&path, raw).unwrap();
            let cfg = load_or_heal(&path).unwrap();
            assert_eq!(cfg.allow_actions, expected, "raw: {raw}");
        }
    }

    #[test]
    fn healing_drops_allow_actions_fail_closed() {
        // An unparseable config regenerates the token and must NOT keep the
        // actions opt-in.
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("config.json");
        fs::write(&path, r#"{ "authToken": "", "allowActions": true }"#).unwrap();
        let cfg = load_or_heal(&path).unwrap();
        assert_eq!(cfg.allow_actions, None);
        let raw: serde_json::Value =
            serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert!(raw.get("allowActions").is_none());
    }
}
