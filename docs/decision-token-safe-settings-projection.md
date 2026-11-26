# Decision: token-safe settings projection

Status: ratified by implementation (commit `1bbe6942`, bead `airi-bav5`, closed 2026-11-26).

## Decision

Credential-bearing settings reads never return a credential field. The daemon projects it away at the data layer, so every caller is safe, not just one handler.

1. **Omit, don't echo.** `DiscordSettingsView` has no `token` field; it carries a wire-only `hasToken` (serde `has_token`) so a thin client can show "configured" without receiving the secret (`crates/anima-core/src/settings.rs:1943-1983`). Both `settings.get("discord")` entry points route through `discord_view`: the ungated gateway read (`crates/anima-daemon/src/gateway.rs:966`, Discord projection at `:986-992`) and `CoreService::settings_get` (`core.rs:331-335,733-758`).
2. **Mask the older precedent.** `mcp.config.get` / `settings.get("mcp")` replace `env`/`headers` values and credential-shaped fields (including `token`) with `********` rather than inventing a presence flag (`core.rs:29-84,831-842`; `settings.get` MCP mask at `gateway.rs:966,975-981`; verbs `mcp.config.get`/`.set` at `gateway.rs:2528,2537`).
3. **Masked-echo PATCHes preserve the stored secret.** A Discord PATCH that omits `token`, nulls it, or echoes the mask removes the field before merge; only an explicit new token rotates it (`core.rs:231-243`, regression test `core.rs:1607`). MCP applies the same rule to masked `env`/`headers`/secret keys (`core.rs:150-231`, test `core.rs:1703`). No `settings.set` reply echoes the config (`gateway.rs:1027`); `mcp.config.set` (`gateway.rs:2537`) returns only `{"ok": true}` (`:2545`).
4. **Writes stay gated.** `settings.set` and `mcp.config.set` are registered through `gated()`; the read paths are ungated only because their replies are scrubbed (`gateway.rs:1009-1010`, `gateway.rs:2537-2548`).

## Scope

Settings projection only. Live Discord start/stop/status verbs shipped separately in `bbdf37fa` (`airi-ro6o`, closed 2026-11-27) and reuse this same token-free projection: `CoreService::discord_status` (`crates/anima-daemon/src/core.rs:859`) returns only wire-only `DiscordStatusReply` `{ running, hasToken }` (`crates/anima-channel/src/wire.rs:288`); `discord.status` is ungated while `discord.start` / `discord.stop` stay gated (`crates/anima-daemon/src/gateway.rs:2566,2576,2590`). No credential value or config echo crosses the wire. The parity row is `docs/feature-parity-checklist.md` (Discord / MCP config); the persisted keys are inventoried in `docs/data-catalog.md` §4.7 and §4.21.
