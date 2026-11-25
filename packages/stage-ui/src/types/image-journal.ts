/**
 * Persisted append-only image record, scoped to `characterId` (the active card). `blob` is the source of truth for bytes; `url` is a store-managed object URL for rendering; `originalUrl` is the external URL used for deduplication; `remixId` links a derivative to its source. The live gallery is backed by the background store (`type: 'journal'` entries); the `image_journal` LLM tool (`create`/`apply`) writes here, and `apply`/`set_as_background` promotes an entry to the stage background.
 */
export interface ImageJournalEntry {
  id: string
  characterId: string
  blob: Blob
  url?: string // Object URL for rendering (managed by store)
  prompt: string
  title: string
  remixId?: string | number
  createdAt: number
  originalUrl?: string // External URL for deduplication
}

/**
 * Input for appending a new journal entry; `characterId` defaults to the active card when omitted.
 */
export interface CreateImageJournalEntryInput {
  blob: Blob
  prompt: string
  title: string
  characterId?: string
  remixId?: string | number
  originalUrl?: string
}
