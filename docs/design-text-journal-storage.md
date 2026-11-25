# Text Journal Storage (pointer)

**Status:** accepted proposal, implemented; the technical content moved into code.

The `text_journal` capability — `TextJournalEntry` record shape, per-user IndexedDB
storage, merge/LWW persistence, the `write`/`search` tool surface, keyword + layered
semantic retrieval, proactivity and UI rules, and the phase plan — is documented in
[`packages/stage-ui/src/database/repos/README-text-journal.md`](../packages/stage-ui/src/database/repos/README-text-journal.md).

Persisted key and merge inventory: [`docs/data-catalog.md`](./data-catalog.md) §1.6.

Skills: `airi-data-persistence`, `airi-memory-text-journal`.