import type { ShortTermMemoryBlock } from '../types/short-term-memory'
import type { TextJournalEntry, TextJournalEntrySource, TextJournalEntryType } from '../types/text-journal'

import { estimateTokens } from '@proj-anima/stage-shared'

import { LOCAL_USER_ID } from '../local-user'
import { daemonRequest, hasDaemon } from './daemon-rpc'

/**
 * Daemon-backed memory reads and writes.
 *
 * The daemon's SQLite store owns short-term summaries (`stmm.*`), the
 * append-only text journal (`journal.*`) and the retrieval availability flag
 * (`retrieval.status`) — see `crates/anima-daemon/src/gateway.rs`. This module
 * is the renderer seam for those verbs: it puts the right frame on the wire and
 * normalizes the daemon's snake_case rows into the `ShortTermMemoryBlock` /
 * `TextJournalEntry` shapes the Vue stores already use.
 *
 * Deliberately stateless: no caching and no localStorage fallback. Callers keep
 * their IndexedDB/localStorage copy as the cache and decide what to do when the
 * daemon is absent; transport errors propagate.
 */

/** One `summaries` row as `stmm.list` serializes it (snake_case, straight from the store). */
export interface DaemonSummary {
  id: string
  /** Local calendar day key, `YYYY-MM-DD`. */
  day: string
  /** Markdown summary body. */
  content: string
  /** Sessions distilled into this block. */
  sourceSessionIds: string[]
  /** Estimated token count of `content`. */
  tokenEstimate: number
  /** Created timestamp, ms since epoch. */
  createdAt: number
}

/** One `journal_entries` row as `journal.search` serializes it. */
export interface DaemonJournalEntry {
  id: string
  /** `note` | `dream` | `milestone` | `summary`. */
  kind: string
  content: string
  createdAt: number
  updatedAt: number
}

/** `data` payload of a `stmm.list` reply. */
interface StmmListReply {
  summaries?: unknown
}

/** `data` payload of a `stmm.rebuild` reply. */
interface StmmRebuildReply {
  ok?: unknown
  pruned?: unknown
}

/** `data` payload of a `journal.append` reply. */
interface JournalAppendReply {
  id?: unknown
}

/** `data` payload of a `journal.search` reply. */
interface JournalSearchReply {
  entries?: unknown
  truncated?: unknown
}

/** `data` payload of a `retrieval.status` reply. */
interface RetrievalStatusReply {
  available?: unknown
}

/** Journal kinds the daemon accepts; anything else is stored as `note`. */
const DAEMON_JOURNAL_KINDS: Record<string, true> = { note: true, dream: true, milestone: true, summary: true }

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' ? value as Record<string, unknown> : {}
}

/** Millisecond timestamps only; anything else falls back to `fallback`. */
function asTimestamp(value: unknown, fallback: number): number {
  if (typeof value === 'number' && Number.isFinite(value))
    return value
  if (typeof value === 'string') {
    const parsed = Number(value)
    if (Number.isFinite(parsed))
      return parsed
  }
  return fallback
}

function asStringArray(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((item): item is string => typeof item === 'string') : []
}

/** Normalize one `stmm.list` row, tolerating both snake_case and camelCase keys. */
function normalizeSummary(value: unknown): DaemonSummary {
  const row = asRecord(value)
  return {
    id: typeof row.id === 'string' ? row.id : '',
    day: typeof row.day === 'string' ? row.day : typeof row.date === 'string' ? row.date : '',
    content: typeof row.content === 'string' ? row.content : typeof row.summary === 'string' ? row.summary : '',
    sourceSessionIds: asStringArray(row.source_session_ids ?? row.sourceSessionIds),
    tokenEstimate: typeof row.token_estimate === 'number' && Number.isFinite(row.token_estimate) ? row.token_estimate : typeof row.tokenEstimate === 'number' && Number.isFinite(row.tokenEstimate) ? row.tokenEstimate : 0,
    createdAt: asTimestamp(row.created_at ?? row.createdAt, Date.now()),
  }
}

/** Normalize one `journal.search` row. */
function normalizeJournalEntry(value: unknown): DaemonJournalEntry {
  const row = asRecord(value)
  const createdAt = asTimestamp(row.created_at ?? row.createdAt, Date.now())
  return {
    id: typeof row.id === 'string' ? row.id : '',
    kind: (typeof row.kind === 'string' ? row.kind : 'note') || 'note',
    content: typeof row.content === 'string' ? row.content : '',
    createdAt,
    // Append-only rows are never mutated; `updated_at` is stored equal to
    // `created_at`, so a missing column means "never updated".
    updatedAt: asTimestamp(row.updated_at ?? row.updatedAt, createdAt),
  }
}

/**
 * Whether this stage ever talks to a daemon. Stage-web (no daemon) returns
 * false; the caller falls back to its local memory cache.
 */
export function hasDaemonMemory(): boolean {
  return hasDaemon()
}

/** Read the most recent daily summary blocks, newest first. */
export async function listDaemonSummaries(limit?: number): Promise<DaemonSummary[]> {
  const payload: Record<string, unknown> = {}
  if (limit !== undefined)
    payload.limit = limit

  const reply = await daemonRequest<StmmListReply>('stmm.list', payload)
  const summaries = asRecord(reply).summaries
  if (!Array.isArray(summaries))
    return []

  return summaries.map(normalizeSummary)
}

/** Prune stale summary blocks; the daemon owns the rebuild policy. */
export async function rebuildDaemonShortTermMemory(): Promise<{ ok: boolean, pruned: number }> {
  const reply = asRecord(await daemonRequest<StmmRebuildReply>('stmm.rebuild'))
  return {
    ok: reply.ok === true,
    pruned: typeof reply.pruned === 'number' && Number.isFinite(reply.pruned) ? reply.pruned : 0,
  }
}

/** `data` payload of a `stmm.upsert` reply. */
interface StmmUpsertReply {
  upserted?: unknown
}

/** Daemon cap on blocks per `stmm.upsert` call (`STMM_UPSERT_MAX_BLOCKS`). */
const STMM_UPSERT_CHUNK_SIZE = 100

/** One `stmm.upsert` block, in the daemon's wire shape. */
interface DaemonSummaryUpsertBlock {
  id: string
  day: string
  content: string
  tokenEstimate: number
  sourceSessionIds: string[]
  createdAt: number
}

/**
 * Persist store blocks through the daemon-owned summary store.
 *
 * The daemon row has no user/character/universe column, so scoping stays
 * Vue-side; only the fields the store actually persists go on the wire. Blocks
 * are sent in chunks of {@link STMM_UPSERT_CHUNK_SIZE} because the daemon
 * rejects larger batches, and an empty batch is never sent.
 */
export async function upsertDaemonSummaries(blocks: ShortTermMemoryBlock[]): Promise<number> {
  let upserted = 0

  for (let offset = 0; offset < blocks.length; offset += STMM_UPSERT_CHUNK_SIZE) {
    const chunk: DaemonSummaryUpsertBlock[] = blocks.slice(offset, offset + STMM_UPSERT_CHUNK_SIZE).map(block => ({
      id: block.id,
      day: block.date,
      content: block.summary,
      tokenEstimate: block.estimatedTokens,
      sourceSessionIds: block.sessionId ? [block.sessionId] : [],
      createdAt: block.createdAt,
    }))
    const reply = asRecord(await daemonRequest<StmmUpsertReply>('stmm.upsert', { blocks: chunk }))
    if (typeof reply.upserted === 'number' && Number.isFinite(reply.upserted))
      upserted += reply.upserted
  }

  return upserted
}

/** Append one journal entry and return its new id (empty when the daemon omits it). */
export async function appendDaemonJournalEntry(content: string, kind: string = 'note'): Promise<string> {
  const reply = asRecord(await daemonRequest<JournalAppendReply>('journal.append', {
    content,
    kind: DAEMON_JOURNAL_KINDS[kind] ? kind : 'note',
  }))
  return typeof reply.id === 'string' ? reply.id : ''
}

/** Full-text-ish substring search over the daemon's journal, newest first. */
export async function searchDaemonJournal(query: string, limit?: number): Promise<DaemonJournalEntry[]> {
  const payload: Record<string, unknown> = { query }
  if (limit !== undefined)
    payload.limit = limit

  const reply = asRecord(await daemonRequest<JournalSearchReply>('journal.search', payload))
  const entries = reply.entries
  if (!Array.isArray(entries))
    return []

  return entries.map(normalizeJournalEntry)
}

/** Whether the daemon's retrieval/augmented-memory lane is available. */
export async function getDaemonRetrievalStatus(): Promise<boolean> {
  const reply = asRecord(await daemonRequest<RetrievalStatusReply>('retrieval.status'))
  return reply.available === true
}

/**
 * Project a daemon summary onto the store's block shape.
 *
 * The daemon row carries no user/character/scope, so those come from
 * `overrides` (universe/session included); anything unset falls back to the
 * local-only defaults the store already uses.
 *
 * @param overrides Partial overrides; fields omitted keep their derived value.
 */
export function toShortTermMemoryBlock(
  summary: DaemonSummary,
  overrides: Partial<ShortTermMemoryBlock> = {},
): ShortTermMemoryBlock {
  const summaryBody = summary.content ?? ''
  const createdAt = summary.createdAt
  const block = {
    id: summary.id,
    userId: LOCAL_USER_ID,
    characterId: '',
    characterName: '',
    date: summary.day,
    source: 'rebuilt',
    summary: summaryBody,
    estimatedTokens: summary.tokenEstimate > 0 ? summary.tokenEstimate : estimateTokens(summaryBody),
    messageCount: 0,
    sessionCount: summary.sourceSessionIds.length,
    createdAt,
    updatedAt: createdAt,
    ...overrides,
  } as ShortTermMemoryBlock // `overrides` is partial: the derived fields below fill what it omits

  // Re-apply the derived fields after the spread: an override object may
  // carry them as `undefined` (e.g. a `Partial` built from optional data),
  // which would otherwise erase the derived value.
  block.createdAt = overrides.createdAt ?? createdAt
  block.updatedAt = overrides.updatedAt ?? createdAt
  // A single source session identifies the block's session; an explicit
  // override still wins.
  block.sessionId = overrides.sessionId ?? (summary.sourceSessionIds.length === 1 ? summary.sourceSessionIds[0] : undefined)
  return block
}

/** Daemon journal kind → store source/type. Unknown kinds read as `tool`/`message`. */
function journalKindToSource(kind: string): TextJournalEntrySource {
  switch (kind) {
    case 'dream':
      return 'dream'
    case 'milestone':
    case 'summary':
      return 'seed'
    default:
      return 'tool'
  }
}

/**
 * Project a daemon journal row onto the store's entry shape.
 *
 * `kind` maps to `source`/`type`; FSRS and embedding fields are owned by the
 * local store and default to the same zeroed values a fresh entry gets.
 */
export function toTextJournalEntry(
  entry: DaemonJournalEntry,
  overrides: Partial<TextJournalEntry> = {},
): TextJournalEntry {
  const type: TextJournalEntryType = entry.kind === 'summary' ? 'episode' : 'message'
  const normalized = {
    id: entry.id,
    userId: LOCAL_USER_ID,
    characterId: '',
    characterName: '',
    title: entry.content.trim().slice(0, 40) || 'Journal Entry',
    content: entry.content,
    source: journalKindToSource(entry.kind),
    type,

    stability: 0,
    difficulty: 0,
    elapsed_days: 0,
    scheduled_days: 0,
    last_review: entry.createdAt,
    ...overrides,
  } as TextJournalEntry // `overrides` is partial: `last_review` below fills what it omits

  // Re-apply the derived field after the spread: an override object may carry
  // it as `undefined`, which would otherwise erase the derived value.
  normalized.last_review = overrides.last_review ?? entry.createdAt
  return normalized
}