<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Plan: BYOS / daemon-gateway chat sync

- **Status:** accepted (2026-11-22)
- **Bead:** `airi-94l`
- **Supersedes:** the hosted `/api/chats/sync` mirror and the stage-ui
  `syncSessionToRemote()` path.

## Decision

Chat multi-device sync is a **paired daemon-to-daemon snapshot exchange**
carried by the existing authenticated `anima-channel` RPC, with optional
**user-owned BYOS storage** (S3/R2/local FS) as the snapshot backing. AIRI
never stores user chat history in an AIRI-hosted database or object store.

The daemon remains the source of truth for daemon mode:
`crates/anima-store` (`sessions`, `messages`) is written only by the daemon.
Thin clients (Flutter, Godot, the Vue reference) call daemon RPCs; they do not
invent a second HTTP chat API.

BYOS reconciliation for the TypeScript/IndexedDB store already exists and
stays in place: `packages/stage-ui/src/stores/sync-engine.ts` reconciles
`db/chat/sessions/*` with per-session LWW rules
(`docs/project-byos-cloud-sync.md`, “Index-Driven Selective Sync for
Sessions”). The daemon snapshot exchange uses the same snapshot file shape so
a user can copy an exported JSONL file to their own bucket without AIRI
custody.

## Transport

```text
Flutter / Godot / Vue
        │  authenticated anima-channel RPC
        ▼
  local daemon (SQLite: sessions, messages)
        │  sessions.export / sessions.import
        ▼
paired daemon on another device  ──────────┐
        │                                   │
        └── user-owned S3 / R2 / local FS ──┘
            (snapshot file, never AIRI-hosted)
```

- `sessions.export` (existing) returns `{"jsonl": "..."}` for one session;
  line 1 is `{"type":"session","session":{...}}` and following lines are
  `{"type":"message","message":{...}}`
  (`crates/anima-core/src/sessions.rs`).
- `sessions.import` (new) accepts the same JSONL snapshot and applies it to
  the receiving daemon's store.
- No AIRI-hosted custody: the gateway/relay only carries the authenticated
  RPC; it does not persist chat snapshots. A paired daemon, or the user's own
  S3/R2/local FS, is the only durable copy outside the two daemons.
- Flutter and Godot participate by calling the daemon RPCs (for example
  `DaemonClient.sessionsExport()` in
  `apps/flutter/lib/daemon_client/daemon_client.dart`). They never call an
  AIRI REST endpoint for chat sync.

## Snapshot revision and conflict policy

The revision is the snapshot session's `updated_at` (milliseconds since
epoch, already persisted in `sessions.updated_at`). It is monotonic for a
given session under daemon ownership because every message insert and session
update advances it.

Import is deterministic and idempotent:

| Local vs. incoming | Result |
| --- | --- |
| No local session | **applied** — insert the incoming session and messages |
| incoming `updated_at` > local `updated_at` | **applied** — replace the session snapshot atomically |
| same `updated_at`, same snapshot content | **duplicate** — no write |
| same `updated_at`, different content | **conflict** — local stays canonical; caller resolves explicitly |
| incoming `updated_at` < local `updated_at` | **older** — reject the snapshot |

`SessionImportReply` reports one of those statuses plus the stored
`updated_at` so the caller can surface “keep local / keep remote / merge”
without silently losing data. A conflict is never auto-resolved by deleting
the local session. Session deletion across devices remains an explicit,
future tombstone operation; this snapshot format has no tombstone, so import
never resurrects or deletes a session implicitly.

## Phased migration

1. **Design (this document).** Record the transport, no-custody rule, and
   conflict policy before removing the old path.
2. **Daemon snapshot exchange.** Keep `sessions.export`; add
   `sessions.import` in `crates/anima-core/src/sessions.rs`,
   `CoreService`, and the daemon gateway, with a typed
   `SessionImportReply` in `crates/anima-channel/src/wire.rs` and regenerated
   TypeScript wire types.
3. **Retire the hosted mirror.** Remove `syncSessionToRemote()` and its
   `remoteSyncEnabled && isAuthenticated` gate from
   `packages/stage-ui/src/stores/chat/session-store.ts`; delete the
   `/api/chats/sync` route, its service/schema, and its tests. Local
   IndexedDB persistence and BYOS reconciliation are unchanged.
4. **Thin-client adoption.** Flutter/Godot call `sessions.export` /
   `sessions.import` through their daemon clients. The Vue reference uses the
   daemon RPC when running in daemon mode and BYOS otherwise.

## Non-goals

- No AIRI-hosted chat custody, community graph, or cross-user sharing.
- No CRDT or per-message merge in this change; per-session LWW is the
  documented policy.
- No new REST endpoint replaces `/api/chats/sync`.