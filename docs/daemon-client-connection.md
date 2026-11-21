# Daemon Client Connection

How external clients (Rust, Dart/Flutter, C#/Godot) connect to the
always-on `anima-daemon` gateway.

## Endpoint

- Default: `ws://127.0.0.1:6121` (loopback, plaintext).
- Override host/port/path via `ConnectionSettings` (Dart) or the constructor
  args (C#); the Rust client parses the full URI.
- Beyond loopback the daemon **forces** `wss://` with a locally minted CA
  (see "TLS / CA trust"). Never send `ws://` to a non-loopback host.

The gateway speaks one WebSocket text-frame protocol (`airi-channel/1`); path
is `/ws`. The daemon binds port 6121 (`DEFAULT_PORT` in
`crates/anima-channel/src/lib.rs`).

## Auth handshake

The **first frame** on every connection must be an auth frame:

```json
{"type":"auth","authToken":"<uuid-v4>"}
```

The daemon replies `{"type":"auth","ok":true}` on success, or an `error`
frame followed by close code 1008 on failure. Anything else sent before auth is
rejected. The token is a random UUIDv4 (122-bit) read from the daemon-owned
config file:

- Linux: `$XDG_DATA_HOME/airi-slint/server-channel/config.json`
  (fallback `~/.local/share/airi-slint/server-channel/config.json`)
- macOS: `~/Library/Application Support/airi-slint/server-channel/config.json`
- Windows: `%APPDATA%\airi-slint\server-channel\config.json`

Override path with `AIRI_SERVER_CHANNEL_CONFIG`. The file is `0600` (owner
only). The token can also be fetched over the session bus via
`org.moeru.airi.Daemon1.GetGatewayConfig` (returns `authToken`).

## Wire format

Frames are JSON text frames, internally tagged on `type`. Field names on the
wire are **camelCase** (`authToken`, `uptimeSeconds`, `sessionStartedMs`),
matching the existing Electron/Bun gateway exactly. Rust structs use
`#[serde(rename = ...)]` / `rename_all = "camelCase"`; Dart and C# hand-written
codecs mirror those names.

> Naming note: the helper entry points are named in each language's
> snake_case/camelCase convention (`daemon_connect` in Rust, `fromUri` in Dart
> because a static `connect` collides with the instance `connect`, `ConnectAsync`
> in C#), but the **JSON keys remain camelCase**. Do not "fix" the wire to
> snake_case — auth would break.

## Reconnect policy

Clients own reconnect. Recommended: bounded exponential backoff
(initial 1 s, multiplier 2, cap 30 s, max 5 attempts) as implemented by
Dart's `ReconnectPolicy`. Auth failures are terminal (do not retry a bad
token). Transport drops trigger reconnect; the daemon does not force-close on
token rotation (existing sessions stay authenticated).

## TLS / CA trust (wss beyond loopback)

For `wss://` the daemon mints a local CA (`websocket-ca-cert.pem`) plus a
SAN-covered leaf. Clients must trust that CA. Fetch it from the daemon's
certs dir (`<data>/airi-slint/server-channel/certs/websocket-ca-cert.pem`)
or via D-Bus; never disable verification.

## Helpers

### Rust (`crates/anima-channel`)

```rust
use anima_channel::{daemon_connect, daemon_connect_with_ca};

// loopback
let mut client = daemon_connect("ws://127.0.0.1:6121", &token)?;
// remote (wss) — supply the CA PEM
let mut client = daemon_connect_with_ca("wss://host:6121", &token, ca_pem)?;
```

Also available as associated functions: `GatewayClient::daemon_connect`,
`GatewayClient::daemon_connect_with_ca`.

### Dart / Flutter (`apps/flutter/lib/daemon_client`)

```dart
final client = await DaemonClient.fromUri('ws://127.0.0.1:6121', token);
// or instance form:
final c = DaemonClient();
await c.connectUri('ws://127.0.0.1:6121', token);
```

`fromUri` is named (not `connect`) because Dart forbids a static and an
instance member sharing the name.

### C# / Godot (`godot/scripts/Net`)

```csharp
var client = await DaemonClient.ConnectAsync("ws://127.0.0.1:6121", token);
```

## Conformance rule

A wire change merges only when all three are green:
- `cargo test -p anima-channel --locked` (Rust drift check)
- Flutter tests (`dart test`)
- Godot tests (`dotnet test godot/`)
