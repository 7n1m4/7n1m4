# System & Data Management (source of truth)

Where Anima's state physically lives, how the BYOS cloud backup queue drains, and which
destructive actions wipe what. **The in-code storage layer is the source of truth**; this
doc maps the surfaces.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Storage topology (`local:` → IndexedDB `airi-local`, `outbox:` → `airi-sync-queue`) | [`packages/stage-ui/src/database/README.md`](../../../../../stage-ui/src/database/README.md) |
| Persisted-key inventory | [`docs/data-catalog.md`](../../../../../../docs/data-catalog.md) |
| BYOS sync engine, merge rules, quota | [`stores/sync-engine.ts`](../../../../../stage-ui/src/stores/sync-engine.ts) |
| Cloud credential vault bootstrap | [`stores/modules/cloudflare.ts`](../../../../../stage-ui/src/stores/modules/cloudflare.ts) |
| Data management UI (export/import, cache cleanup, danger zone) | [`settings/data/index.vue`](../data/index.vue) |
| Cloud sync UI | [`settings/modules/cloud-sync.vue`](../modules/cloud-sync.vue) |

## 1. Local topology

Three backends, by data profile:

| Layer | Backend | Key pattern |
| :--- | :--- | :--- |
| Structured data | IndexedDB via `unstorage` (base `airi-local`) | `local:{namespace}/…` |
| Blob/binary assets | `localforage` (auto-managed DB) | `{prefix}-{id}` |
| Settings/preferences | `localStorage` | `settings/{group}/{key}` |

Chat sessions, text journals, echo chips, provider accounts, and card metadata are
structured; VRM/Live2D models, textures, animations, and journal backgrounds are blobs.
Nothing leaves the machine unless BYOS is configured — there is no central Anima backend.

## 2. Cloud backup & sync (BYOS)

Bring Your Own Storage targets user-owned S3 / Cloudflare R2 / MinIO buckets and
Google Drive AppData. The pipeline is an offline-first **outbox**: every `local:` write is
intercepted, enqueued onto `outbox:queue/*`, and reconciled by `sync-engine.ts` using
last-write-wins on `mtime`, with union-merge for the designated mergeable keys
(`airi-cards`, `short-term-memory`, `event-log`, display-model manifests).

Configure it under **Settings &rarr; Modules &rarr; Cloud Sync**: pick the adapter, enter
endpoint/bucket/region/credentials, then **Test & Sync Now**. If local credentials are
missing, the Edge Vault bootstrap (`modules/cloudflare.ts`) can restore them.

## 3. Export, import & cache

**Settings &rarr; Data Management** (`settings/data/index.vue`):

- **Export** — a full archive of characters, chats, journals, and settings.
- **Import** — restores a previously exported archive.
- **Model cache cleanup** — drops unused 3D/2D binary caches.

## 4. Reset & danger zone

- **Reset module settings** — restores TTS/STT/LLM defaults, keeps chat history.
- **Delete all conversations** — wipes the chat session database, keeps cards/settings.
- **Factory reset** — purges every IndexedDB database, localforage blob, and local
  preference, returning Anima to first-run onboarding.
