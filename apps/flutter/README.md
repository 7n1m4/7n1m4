# Anima — Flutter stage UI (desktop + mobile)

Flutter is the primary renderer with native model rendering. The daemon owns core
state (settings, chat sessions, cards, memory). The Vue/electrobun apps are
references; Godot is purged. "Thin" means no competing state writer — view state
only, closable without stopping the agent.

Authoritative design contract: [`docs/design-flutter-godot-pivot.md`](../../docs/design-flutter-godot-pivot.md)
(decisions 1, 3, 10 and invariants 1–3, 5) and
[`docs/design-daemon-client.md`](../../docs/design-daemon-client.md) (decision 1).

## What is in this scaffold

| Area | Files | Notes |
| --- | --- | --- |
| Entry + theme | `lib/main.dart`, `lib/app.dart`, `lib/theme/app_theme.dart` | Material 3 dark companion palette. **Design parity with Vue is deferred** (see below). |
| Navigation shell | `lib/navigation/navigation_shell.dart` | Control/Home, Chat, Settings, Connections, About — full stage-UI navigation shell; detailed Vue-parity surfaces are tracked in docs/feature-parity-checklist.md |
| Feature placeholders | `lib/features/**` | No business logic; settings/providers/memory/cards/sessions are future daemon RPC verbs. |
| Connection form | `lib/connection/connection_settings.dart`, `connection_settings_screen.dart` | Host/port/`ws`↔`wss`/token, validation, derived endpoint placeholder, fail-closed TLS note. |
| Daemon client | `lib/daemon_client/**` | Frame codec, transport abstraction, auth handshake, typed RPC, `core.status` probe, backoff, clear error states. |
| Tests | `test/**` | Pure Dart; in-memory fake transport, no live daemon and no socket. |

## How it talks to the daemon

Protocol is reused verbatim from `crates/anima-channel/src/wire.rs` — nothing new
is invented here:

- WebSocket path `/ws`, default port `6121` (env override on the daemon side).
- **First frame must be auth**: `{"type":"auth","authToken":"…"}` (or the mirror
  `{"type":"module:authenticate","data":{"token":"…"}}`). Bad token → close 1008.
- JSON text frames only, 1 MiB cap. Loopback plaintext `ws://`; non-loopback
  forced `wss://` with the locally minted CA.
- Built-in RPC actions: `runtime.ping`, `runtime.status`, `gateway.config`,
  `gateway.auth`; the daemon registers `core.status`. Replies carry `ok`,
  optional `data`/`error`, and echo the client-supplied `id`.
- Protocol identifier is the **literal carve-out `airi-channel/1`** — do not
  rename it to `anima-*` (wire version 1 stays additive).
- **Keepalive**: once authenticated, the client sends `{"type":"ping"}` every
  30 s (`DaemonClient.heartbeatInterval`). The daemon closes a peer that sends
  no frame for `DEAD_PEER_TTL` (75 s), so this is what keeps an idle session
  alive; it stops on disconnect/reconnect and never runs pre-auth.

`ConnectionSettings` mirrors the derivation rules of the Vue reference
`resolveWebSocketUrl` (`packages/stage-ui/src/stores/mods/api/channel-server.ts`)
and its settings form (`packages/stage-pages/src/pages/settings/system/ConnectionSettings.vue`):
an unset endpoint derives from the daemon-mirrored gateway keys (default
`ws://127.0.0.1:6121/ws`), and a non-loopback `ws://` is **fail-closed to
`wss://`** rather than sending the bearer token in cleartext.

### Transport seams

`DaemonTransport` (`lib/daemon_client/transport.dart`) is the only socket-facing
abstraction. `DirectWebSocketTransport` implements direct LAN/loopback WS today.
Per the resolved mobile decision (D10 / decision B, 2026-11-21), mobile is a
**remote client** over libp2p, Cloudflare Tunnel, or tunnel + libp2p — there is
**no `flutter_rust_bridge` embedded core and no local mobile daemon**. A daemon
hosted under Termux on Android is another acceptable endpoint for the same
interface. Those remote transports are TODO seams (`airi-wxp.3.5`), not
hard-wired; the UI stays thin in every topology for battery life.

## Toolchain prerequisites

- Flutter SDK with Dart `>=3.4.0` (use a stable channel).
- `flutter pub get` to fetch `web_socket_channel` and `flutter_lints`.

Then:

```sh
flutter analyze
flutter test
```

**Verified toolchain:** the scaffold was validated with Flutter 3.38.5 / Dart
3.10.4 (fvm at `~/fvm/versions/3.38.5/bin`). `flutter analyze` reports 0 errors
(a handful of info-level lint hints remain), and `flutter test` passes all 52
tests. `pubspec.lock` is present, and the desktop hosts `linux/`,
`macos/` and `windows/` now exist (generated with
`flutter create --platforms=linux,macos,windows .` and checked in). They are
build scaffolding only, not a release: no desktop release pipeline exists,
and CI does not run `flutter build linux/macos/windows` because the
platform-native plugin implementations are not landed. To regenerate a host
with the SDK present, run
`flutter create --platforms=linux,macos,windows,android,ios .` then
`flutter pub get`.

### Desktop hosts in CI

Job `flutter-desktop-hosts` in `.github/workflows/ci.yml` runs on
`ubuntu-latest`: it asserts the generated host files exist, then runs
`flutter config --enable-linux-desktop`, `flutter pub get`, `flutter analyze`
and `flutter test` in `apps/flutter`. It is not release validation, and no
macOS or Windows runner is involved.

## Intentionally deferred (with reasons)

- **Event subscription + typed Dart event models.** The client owns the
  `event.subscribe` RPC for `token.delta` and re-subscribes after every
  reconnect. Received `event` frames are decoded into a typed envelope and
  dispatched to every listener registered with `onEvent` (which returns an
  unsubscribe handle callers must use in `dispose`). The long-term binding
  strategy is still open (`airi-wxp.10`): generated bindings versus hand-written
  models plus Rust golden conformance fixtures are not prejudged here.
- **Chat streaming.** Working: `chat.send` returns an early ack, tokens arrive as
  `token.delta` events, and the composer stays active until a final delta or a
  `chat.cancel`. Cards remain out of scope and show an unavailable banner.
- **Real control surfaces** (settings/providers/memory/sessions) are daemon RPC
  verbs, never a second Dart store writer. Settings are read with `settings.get`
  before any write so an empty section cannot reset unrelated keys.
- **Secure token storage.** Token is memory-only this session; Keychain/Keystore
  persistence and the LAN CA-trust UX are `airi-u71.6`.
- **Remote transports / pairing / trust**: `airi-wxp.3.5`, `airi-wxp.3.4`.
- **Packaging & signing**, **i18n/a11y parity with Vue**, **adaptive desktop
  NavigationRail**, and **precise visual parity** with `apps/stage-web` are later
  work (`airi-wxp.3.6`, `airi-wxp.3.7`).
- The Vue web app is kept as the full-UI **behaviour reference** only; do not
  fork its business logic into Dart to "catch up". Extend the daemon instead.


## Remote-client transport (libp2p / Cloudflare Tunnel)

Flutter is a thin client: it never embeds core or runs a local daemon. It
reaches the desktop daemon (or a Termux-hosted daemon) over the same WebSocket
gateway, whether directly (LAN `ws://`/`wss://`), through a libp2p relay, or
through a Cloudflare Tunnel URL. The connection settings `host`/`port`/`scheme`/
`path`/`authToken` describe the reachable endpoint; `reconnect_policy.dart`
governs backoff. Trust boundaries follow `docs/design-daemon-gateway.md`: the
auth token is the shared secret, non-loopback plaintext is fail-closed to
`wss://`, and remote endpoints must present a valid TLS certificate. Wrong-peer
or tunnel rejection surfaces as a terminal `failed` connection state with a
clear reason; no credentials are persisted beyond memory.
