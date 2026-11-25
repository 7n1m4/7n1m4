# Text journal storage

Source of truth for the `text_journal` capability: record shape, storage, retrieval and
product rules. `docs/design-text-journal-storage.md` is only an architecture pointer here.

## Record shape

`TextJournalEntry` lives in `../../types/text-journal.ts` and is the schema of record:

```ts
export type TextJournalEntrySource = 'tool' | 'chat' | 'proactivity' | 'dream' | 'user' | 'seed' | 'episode'
export type TextJournalEntryType = 'message' | 'episode'

export interface TextJournalEntry {
  id: string
  userId: string
  characterId: string
  characterName: string
  title: string
  content: string
  source: TextJournalEntrySource
  type?: TextJournalEntryType

  // FSRS fields
  stability: number
  difficulty: number
  elapsed_days: number
  scheduled_days: number
  last_review: number
  surprise?: number

  // Search fields
  embedding?: number[]
  version?: string

  universeId?: string
  sessionId?: string

  createdAt: number
  updatedAt: number
}
```

Rules that the shape encodes:

- `content` is the payload; `title` is an optional label AIRI writes when it naturally
  wants to name a thought.
- `characterId` / `characterName` scope entries per card; `universeId` and `sessionId`
  scope retrieval to the active session's universe (`global` when unset).
- `source` records how the entry came to exist: `tool` (model called the journal tool),
  `chat`, `proactivity` (heartbeat turn), `dream`, `user`, `seed` (starter card),
  `episode`.
- `embedding` + `version` are search metadata owned by the layered index, not by the
  model; the FSRS fields drive spaced review.

## Storage

`textJournalRepo` (`text-journal.repo.ts`) persists the whole array per user under
`local:memory/text-journal/{userId}` in IndexedDB (mount `airi-local`, see
`../README.md`). `localStorage` is deliberately not used: the journal is durable app
state with a large budget and async access, not a UI preference.

The store (`../../stores/memory-text-journal.ts`, `useTextJournalStore`) owns merge
semantics: `persist()` re-reads the stored array and unions by id via
`mergeById(stored, nextEntries, removedIds)` (current entries win; ids that vanished
from memory are tombstoned through `markSyncTombstone` so the BYOS merge cannot
resurrect them), then writes the normalized whole-array snapshot. Saves are
whole-array — there are no per-entry keys yet.

## Model-facing tool

The model-facing tool (`../../stores/modules/tools/text-journal.ts`) exposes exactly two actions: `create` (append an entry, `source: 'tool'`, title defaults to the first 40 chars) and `search` (keyword/concept query over dialogue history, recaps, knowledge graph and journal, limit 1–10). v1 ships no `delete`, `edit`, `list all` or `open by id`: those are admin mechanics, not journal behavior, and the model never manages ids. User-facing deletion exists only through the journal viewer /
data maintenance, not through the tool.

## Retrieval

- Keyword search over `title`, `content` and `characterName` (weighted scoring; the record
  has no `tags` field) with local filtering, plus the layered index
  (`../../libs/search/layered-memory.ts`) for embedding-backed reranking when an embedder is loaded.
- Semantic retrieval is layered on top, never a replacement: entries are emotional and
  narrative, so lexical recall still matters.
- Index ordering uses one time base (`docIndexTime` in the store): `timestamp` stays
  creation-anchored because temporal scoring depends on it, while `createdAt` is the
  wider recency key (max of creation/update) so edited or backfilled docs re-index
  instead of hiding below the watermark forever.

## Product rules

- Append-only by default; this is a memory surface, not a table editor or a
  knowledge-base admin panel.
- Retrieval must make the journal useful rather than a write-only dump: "what have I
  written about this before?" is the primary query shape.
- Proactive journaling is prompt-driven: a heartbeat turn may spend one extra turn
  writing an entry. No bespoke checkbox is required while the tool is available and the
  prompting is good enough.
- UI stays minimal (reverse-chronological viewer + search); no date filters, no rich
  document editing.
- The journal is self-authored textual memory only. Structured user facts, preferences,
  chat-history embeddings and world-state snapshots are separate systems.

## Phasing

1. IndexedDB storage layer, `write`, keyword retrieval, no edit/delete/list-all. (done)
2. Semantic search improvement, better titles/tags, card-aware ownership/filtering.
3. Proactive reflection integration, optional toolchain gating, richer memory-context
   retrieval policies.

## Related

- `docs/data-catalog.md` §1.6 — key, repo, store and merge inventory.
- Skills: `airi-memory-text-journal`, `airi-data-persistence`.
