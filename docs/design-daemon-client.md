# Daemon client (Slice A)

**Status:** accepted direction; transport (Slice A), the daemon core-service split (Slices B/C), and the slint-side ownership deletion (Slice D) are implemented; the gateway has since grown far past the original single handler.
**Scope:** `crates/anima-channel` Rust client; no daemon business logic in the client layer.
**Architecture (user-directed 2026-11-25):** the Rust daemon/backend is the single source of truth; Flutter is the sole active renderer on desktop/mobile with full Vue parity and native rendering; Vue/Electrobun are behavior references; Godot is retired. "Thin client" below means no competing state writer, not a reduced UI surface. TS business-logic retirement (the gated `airi-3cp` remote-sync slice) never retires the Vue renderer; gateway trust gates and the `airi-3cp` DO NOT START gate stay in force unless the user explicitly says otherwise.

## Decisions

1. **The daemon is the single owner of core state in daemon mode.** Slint must
   not run a competing `AppCore`/store writer while talking to the daemon.
   A thin bridge may keep a local fallback only until the daemon path is
   complete; after deletion, only one side owns the store.
2. **Client placement:** the gateway client lives in `crates/anima-channel`
   next to the server implementation and wire types — not in a new crate and
   not in `anima-slint`. This keeps the protocol, both sides, and the shared
   codec under one roof.
3. **Protocol evolution is additive.** Existing `auth`, `module:authenticate`,
   `ping`, `transport:connection:heartbeat` and `rpc` semantics do not change.
   Chat/memory/settings streaming requires a new event lane/frame, chosen
   before Slice C — it is not modelled in Slice A.
4. **`wss://` beyond loopback.** Plain `ws://` remains acceptable only on
   loopback. Remote slint/clients must use `wss://` with the locally minted
   CA, matching the server posture.
5. **Sequencing:** transport first (this slice), then a read-only core RPC in
   the daemon, then chat streaming, then memory/settings/cards migration. No
   bulk move of `anima-slint/src/bridges/*` into the daemon.

## Slice A (implemented here)

- RFC6455 client handshake over plain `ws://` or `wss://`.
- `GatewayClient::connect`, `authenticate`, `rpc`, typed `runtime_ping` /
  `runtime_status`, `close`.
- Integration tests against the real `ChannelServer`, including TLS.
- No reconnect policy, daemon wiring, UI, or token storage.

- **B (Slice B, implemented).** Daemon owns core state via `CoreService` (crates/anima-daemon/src/core.rs); `Gateway` holds it (gateway.rs) and `renderer_handlers` registers the wire-facing verbs; `CoreStatusReply` (crates/anima-channel/src/wire.rs) is additive/read-only/no secrets; `GatewayClient::core_status()` (client.rs). Slice B originally registered exactly one handler (`core.status`); the registry has since grown to **33** `renderer.*` verbs (see `docs/rosetta-stone.md` §1b for the enumerated list) plus the **6** built-ins in `crates/anima-channel/src/dispatch.rs:299-304`. Slint-side ownership deletion done (Slice D: anima-slint removed).
- **C (implemented).** Chat over WS: `chat.send` streams `token.delta` events; `chat.cancel` stops a turn; `chat.history` replays persisted turns. Registrations: `chat.send` at `crates/anima-daemon/src/gateway.rs:736`, `chat.cancel` at `:898`, `chat.history` at `:924`.
- **D (implemented).** Slint-side ownership deleted (`anima-slint` removed); memory/settings remains daemon-owned via `CoreService`, while cards (`cards.list`/`.get`/`.import`) are explicitly out of daemon scope and return "not implemented" (`gateway.rs:1054-1075`).
