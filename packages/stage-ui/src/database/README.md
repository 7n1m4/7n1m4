# `packages/stage-ui/src/database`

Renderer persistence layer. Source of truth for the storage topology, the remote-sync
enqueue rules, and the per-domain repository key layout. `docs/arch-indexeddb-storage.md`
is only an architecture pointer back here.

## Topology (`storage.ts`)

`storage` is an `unstorage` instance whose root driver is `memory`. Two mounts decide
where a key physically lands, and both fall back to `memory` when `indexedDB` is not
defined (SSR, non-browser test hosts):

| Mount prefix | Driver | Base name |
| :--- | :--- | :--- |
| `local:` | `unstorage/drivers/indexedb` | `airi-local` |
| `outbox:` | `unstorage/drivers/indexedb` | `airi-sync-queue` |

Unprefixed keys stay on the memory root driver; repos always address storage as
`local:<path>` / `outbox:<path>`, e.g. `local:memory/text-journal/${userId}`.

`storageState` is the import window used by remote reconciliation:

- `isImportingRemoteData` — while true, `enqueueSync` diverts writes into
  `pendingImportWrites` instead of the outbox.
- `pendingImportWrites` — `{ key, action }[]`, drained by `flushPendingImportWrites()`
  when the importing window exits. Other windows discard it on their next entry.

## Outbox enqueue rules (`enqueueSync`)

`setItem`, `setItemRaw` and `removeItem` are wrapped so every write/delete passes through
`enqueueSync(key, action)`. A key is **not** synced when any of these hold:

1. it does not start with `local:`;
2. it starts with `local:sync-metadata` (modification timestamps);
3. it is exactly `local:sync/tombstones` (device-local delete tombstones);
4. it is a secret, probed both as the raw key and, for `local:localstorage/...` bridge
   keys, with the `local:localstorage/` prefix stripped (`isSecretStorageKey` from
   `../libs/secret-storage-keys`);
5. an import window is open (held in `pendingImportWrites` instead);
6. `localStorage['settings/sync/enabled'] !== 'true'` in a browser context.

Otherwise the key is enqueued as:

- `local:sync-metadata/timestamps/<keyWithoutPrefix>` = `Date.now()` (removed on delete);
- `outbox:queue/<keyWithoutPrefix>` = `{ key, action, timestamp }`.

## Repositories (`repos/`)

One module per domain, each owning its key shape and (de)serialization:

| Repo | Key |
| :--- | :--- |
| `characters.repo.ts` | `local:characters` |
| `chat-sessions.repo.ts` | `local:chat/index/{userId}` + `local:chat/sessions/{sessionId}` |
| `director-notes.repo.ts` | `local:director/sessions/{sessionId}` |
| `echo-chips.repo.ts` | `local:memory/echo-chips/{userId}` |
| `entity-ledger.repo.ts` | `local:entity-ledger/{characterId}` |
| `lifetime-memory.repo.ts` | `local:memory/lifetime/{characterId}:{universeId}`, legacy `local:memory/lifetime/{characterId}` |
| `peers.repo.ts` | `PEERS_ROSTER_KEY = 'local:peers/roster'` |
| `providers.repo.ts` | `local:providers` |
| `provisioning-session.repo.ts` | `local:memory/provisioning-session/{characterId}:{universeId}`, legacy `local:memory/provisioning-session/{characterId}` (migrated on read) |
| `short-term-memory.repo.ts` | `local:memory/short-term/{userId}` |
| `text-journal.repo.ts` | `local:memory/text-journal/{userId}` |
| `widgets.repo.ts` | `WIDGETS_REGISTRY_KEY = 'local:widgets/registry'` |

`text-journal.repo.ts` is the append-only journal record store: `getAll(userId)` reads the
whole array, `saveAll(userId, entries)` deep-clones through JSON (binary data / Blobs must never
reach IndexedDB) and writes it back under the same key. Merge/LWW semantics live in the
store, not here — see `../../stores/memory-text-journal.ts` and the merge notes in
`docs/data-catalog.md`.

## Local web storage is origin-scoped (the "port switch" effect)

LocalStorage and IndexedDB are partitioned by origin (`protocol + domain + port`). The
Electron main process keeps `app-config.json` in `userData`
(`%APPDATA%\@proj-anima\stage-tamagotchi` on Windows) and is unaffected, so a dev server
that moves from port 5173 to 5174 loads the same global config but presents an empty
`airi-local` / `airi-sync-queue` bucket: settings, credentials and models look "lost".
They are still on disk under the other port's `IndexedDB/*.indexeddb.leveldb` folder.

Pin the port to avoid it — `start_airi.bat` in the repo root prompts for one and exports
`AIRI_RENDERER_PORT` before `pnpm -F @proj-anima/stage-tamagotchi run dev`; the advanced path is `apps/stage-tamagotchi/electrobun.config.ts` plus `hutch.config.ts`, driven by `pnpm -F @proj-anima/stage-tamagotchi run dev` (`hutch run dev`).

## Related

- `docs/data-catalog.md` — persisted key inventory (update it when a key changes).
- Skills: `airi-data-persistence`, `airi-binary-safety`.
