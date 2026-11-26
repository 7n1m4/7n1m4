import type * as DaemonMemoryModule from './daemon-memory'
import type * as DaemonRpcModule from './daemon-rpc'

/**
 * `hasDaemon()` reads the runtime environment, so the env is primed before the
 * modules are resolved through the `fresh*()` helpers below.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The daemon memory client.
 *
 * The seam under test is the memory verb boundary: each function puts the right
 * frame on the wire and normalizes the daemon's snake_case row into the Vue
 * store shape. Only the transport is mocked — the normalization, the kind
 * mapping and the override precedence all run for real.
 */

const h = vi.hoisted(() => ({
  requests: [] as Array<{ action: string, payload: Record<string, unknown> }>,
  reply: vi.fn(async (_action: string, _payload: Record<string, unknown>) => ({})),
}))

vi.mock('./daemon-rpc', async () => {
  const actual = await vi.importActual<typeof DaemonRpcModule>('./daemon-rpc')
  return {
    ...actual,
    daemonRequest: (action: string, payload: Record<string, unknown> = {}) => {
      h.requests.push({ action, payload })
      return h.reply(action, payload)
    },
  }
})

/** Resolve both modules against a module registry reset per test. */
async function freshMemory(): Promise<typeof DaemonMemoryModule> {
  vi.resetModules()
  return import('./daemon-memory')
}

let mod: typeof DaemonMemoryModule

beforeEach(async () => {
  h.requests.length = 0
  h.reply.mockReset()
  h.reply.mockImplementation(async () => ({}))
  vi.stubEnv('RUNTIME_ENVIRONMENT', 'electron')
  mod = await freshMemory()
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('hasDaemonMemory', () => {
  it('reports a daemon for a desktop runtime and none for stage-web', async () => {
    expect(mod.hasDaemonMemory()).toBe(true)

    vi.stubEnv('RUNTIME_ENVIRONMENT', 'browser')
    expect(await freshMemory().then(m => m.hasDaemonMemory())).toBe(false)
  })
})

describe('listDaemonSummaries', () => {
  it('normalizes snake_case rows and omits the limit when none is given', async () => {
    h.reply.mockResolvedValue({
      summaries: [
        {
          id: 'sum-1',
          day: '2026-11-24',
          content: '# Recap\n\nShipped the daemon transport.',
          source_session_ids: ['s-1', 's-2'],
          token_estimate: 42,
          created_at: 1_700_000_000_000,
        },
      ],
    })

    await expect(mod.listDaemonSummaries()).resolves.toEqual([{
      id: 'sum-1',
      day: '2026-11-24',
      content: '# Recap\n\nShipped the daemon transport.',
      sourceSessionIds: ['s-1', 's-2'],
      tokenEstimate: 42,
      createdAt: 1_700_000_000_000,
    }])
    expect(h.requests).toEqual([{ action: 'stmm.list', payload: {} }])
  })

  it('forwards the limit and drops non-string session ids', async () => {
    h.reply.mockResolvedValue({
      summaries: [{ id: 'sum-2', day: '2026-11-25', content: 'x', source_session_ids: ['s-1', 7, null], token_estimate: 'nope', created_at: 5 }],
    })

    const [summary] = await mod.listDaemonSummaries(5)
    expect(h.requests).toEqual([{ action: 'stmm.list', payload: { limit: 5 } }])
    expect(summary).toEqual({
      id: 'sum-2',
      day: '2026-11-25',
      content: 'x',
      sourceSessionIds: ['s-1'],
      tokenEstimate: 0,
      createdAt: 5,
    })
  })

  it('defaults missing fields and tolerates a reply without summaries', async () => {
    h.reply.mockResolvedValue({ summaries: [{ id: 'sum-3' }, null] })
    const [partial] = await mod.listDaemonSummaries()
    expect(partial.id).toBe('sum-3')
    expect(partial.day).toBe('')
    expect(partial.sourceSessionIds).toEqual([])
    expect(partial.tokenEstimate).toBe(0)
    expect(partial.createdAt).toBeGreaterThan(0)

    h.reply.mockResolvedValue({})
    await expect(mod.listDaemonSummaries()).resolves.toEqual([])
  })

  it('propagates transport failures', async () => {
    h.reply.mockRejectedValue(new Error('daemon unreachable'))
    await expect(mod.listDaemonSummaries()).rejects.toThrow('daemon unreachable')
  })
})

describe('rebuildDaemonShortTermMemory', () => {
  it('reports what the daemon pruned', async () => {
    h.reply.mockResolvedValue({ ok: true, pruned: 3 })
    await expect(mod.rebuildDaemonShortTermMemory()).resolves.toEqual({ ok: true, pruned: 3 })
    expect(h.requests).toEqual([{ action: 'stmm.rebuild', payload: {} }])
  })

  it('defaults a malformed reply to nothing done', async () => {
    h.reply.mockResolvedValue({ pruned: 'many' })
    await expect(mod.rebuildDaemonShortTermMemory()).resolves.toEqual({ ok: false, pruned: 0 })
  })
})
describe('upsertDaemonSummaries', () => {
  const block = {
    id: 'sum-1',
    userId: 'local',
    characterId: 'char-1',
    characterName: 'AIRI',
    date: '2026-11-24',
    source: 'rebuilt' as const,
    summary: 'Shipped the daemon transport.',
    estimatedTokens: 42,
    messageCount: 0,
    sessionCount: 1,
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
    sessionId: 's-1',
  }

  it('maps store blocks onto the daemon wire shape and sums the reply', async () => {
    h.reply.mockResolvedValue({ upserted: 1 })
    await expect(mod.upsertDaemonSummaries([block])).resolves.toBe(1)
    expect(h.requests).toEqual([{
      action: 'stmm.upsert',
      payload: {
        blocks: [{
          id: 'sum-1',
          day: '2026-11-24',
          content: 'Shipped the daemon transport.',
          tokenEstimate: 42,
          sourceSessionIds: ['s-1'],
          createdAt: 1_700_000_000_000,
        }],
      },
    }])
  })

  it('sends nothing for an empty batch', async () => {
    await expect(mod.upsertDaemonSummaries([])).resolves.toBe(0)
    expect(h.requests).toEqual([])
  })

  it('chunks at the daemon cap and sums every reply', async () => {
    h.reply.mockResolvedValue({ upserted: 100 })
    const blocks = Array.from({ length: 250 }, (_, index) => ({ ...block, id: `sum-${index}` }))

    await expect(mod.upsertDaemonSummaries(blocks)).resolves.toBe(300)
    expect(h.requests.map(r => (r.payload.blocks as unknown[]).length)).toEqual([100, 100, 50])
  })

  it('omits the session id list when the block has no session', async () => {
    h.reply.mockResolvedValue({ upserted: 1 })
    await mod.upsertDaemonSummaries([{ ...block, sessionId: undefined }])
    expect((h.requests[0].payload.blocks as Array<Record<string, unknown>>)[0].sourceSessionIds).toEqual([])
  })
})

describe('appendDaemonJournalEntry', () => {
  it('sends content and kind and resolves the new id', async () => {
    h.reply.mockResolvedValue({ id: 'entry-1' })
    await expect(mod.appendDaemonJournalEntry('met the user', 'milestone')).resolves.toBe('entry-1')
    expect(h.requests).toEqual([{ action: 'journal.append', payload: { content: 'met the user', kind: 'milestone' } }])
  })

  it('defaults the kind to note and rejects kinds the daemon does not store', async () => {
    h.reply.mockResolvedValue({ id: 'entry-2' })
    await mod.appendDaemonJournalEntry('a note')
    await mod.appendDaemonJournalEntry('a note', 'kg_claim')
    expect(h.requests.map(r => r.payload.kind)).toEqual(['note', 'note'])
  })

  it('resolves an empty id when the daemon omits one', async () => {
    h.reply.mockResolvedValue({})
    await expect(mod.appendDaemonJournalEntry('a note')).resolves.toBe('')
  })
})

describe('searchDaemonJournal', () => {
  it('normalizes rows and defaults updated_at to created_at', async () => {
    h.reply.mockResolvedValue({
      entries: [
        { id: 'e-1', kind: 'dream', content: 'a dream', created_at: 10, updated_at: 10 },
        { id: 'e-2', kind: 'note', content: 'a note', created_at: 20 },
      ],
      truncated: false,
    })

    await expect(mod.searchDaemonJournal('dream')).resolves.toEqual([
      { id: 'e-1', kind: 'dream', content: 'a dream', createdAt: 10, updatedAt: 10 },
      { id: 'e-2', kind: 'note', content: 'a note', createdAt: 20, updatedAt: 20 },
    ])
    expect(h.requests).toEqual([{ action: 'journal.search', payload: { query: 'dream' } }])
  })

  it('forwards the limit and tolerates a reply without entries', async () => {
    h.reply.mockResolvedValue({ entries: [{ id: 'e-3', content: 'x', created_at: 1 }] })
    const [entry] = await mod.searchDaemonJournal('x', 3)
    expect(h.requests).toEqual([{ action: 'journal.search', payload: { query: 'x', limit: 3 } }])
    expect(entry.kind).toBe('note')

    h.reply.mockResolvedValue({})
    await expect(mod.searchDaemonJournal('x')).resolves.toEqual([])
  })
})

describe('getDaemonRetrievalStatus', () => {
  it('reads the availability flag', async () => {
    h.reply.mockResolvedValue({ available: true })
    await expect(mod.getDaemonRetrievalStatus()).resolves.toBe(true)
    expect(h.requests).toEqual([{ action: 'retrieval.status', payload: {} }])

    h.reply.mockResolvedValue({ available: 'yes' })
    await expect(mod.getDaemonRetrievalStatus()).resolves.toBe(false)
  })
})

describe('toShortTermMemoryBlock', () => {
  const summary = {
    id: 'sum-1',
    day: '2026-11-24',
    content: 'Shipped the daemon transport.',
    sourceSessionIds: ['s-1', 's-2'],
    tokenEstimate: 42,
    createdAt: 1_700_000_000_000,
  }

  it('projects a daemon row onto the store block with local defaults', () => {
    expect(mod.toShortTermMemoryBlock(summary)).toEqual({
      id: 'sum-1',
      userId: 'local',
      characterId: '',
      characterName: '',
      date: '2026-11-24',
      source: 'rebuilt',
      summary: 'Shipped the daemon transport.',
      estimatedTokens: 42,
      messageCount: 0,
      sessionCount: 2,
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000,
      universeId: undefined,
      sessionId: undefined,
    })
  })

  it('keeps universe, session and derived fields from overrides', () => {
    expect(mod.toShortTermMemoryBlock(summary, {
      userId: 'user-1',
      characterId: 'char-1',
      characterName: 'AIRI',
      universeId: 'universe-1',
      sessionId: 's-9',
      source: 'automatic',
      messageCount: 12,
    })).toMatchObject({
      userId: 'user-1',
      characterId: 'char-1',
      characterName: 'AIRI',
      universeId: 'universe-1',
      sessionId: 's-9',
      source: 'automatic',
      messageCount: 12,
    })
  })

  it('estimates tokens when the daemon reports none and adopts a lone source session', () => {
    const block = mod.toShortTermMemoryBlock({ ...summary, tokenEstimate: 0, sourceSessionIds: ['s-1'] })
    expect(block.estimatedTokens).toBeGreaterThan(0)
    expect(block.sessionId).toBe('s-1')
    expect(block.sessionCount).toBe(1)
  })
})

describe('toTextJournalEntry', () => {
  const entry = {
    id: 'e-1',
    kind: 'milestone',
    content: 'First daemon memory landed.',
    createdAt: 1_700_000_000_000,
    updatedAt: 1_700_000_000_000,
  }

  it('maps the daemon kind onto the store source and type', () => {
    expect(mod.toTextJournalEntry(entry)).toEqual({
      id: 'e-1',
      userId: 'local',
      characterId: '',
      characterName: '',
      title: 'First daemon memory landed.',
      content: 'First daemon memory landed.',
      source: 'seed',
      type: 'message',
      stability: 0,
      difficulty: 0,
      elapsed_days: 0,
      scheduled_days: 0,
      last_review: 1_700_000_000_000,
      universeId: undefined,
      sessionId: undefined,
    })

    expect(mod.toTextJournalEntry({ ...entry, kind: 'dream' }).source).toBe('dream')
    expect(mod.toTextJournalEntry({ ...entry, kind: 'summary' }).type).toBe('episode')
    expect(mod.toTextJournalEntry({ ...entry, kind: 'note' }).source).toBe('tool')
    expect(mod.toTextJournalEntry({ ...entry, kind: 'kg_claim' }).source).toBe('tool')
  })

  it('keeps universe, session and derived fields from overrides', () => {
    expect(mod.toTextJournalEntry(entry, {
      userId: 'user-1',
      characterId: 'char-1',
      characterName: 'AIRI',
      title: 'Custom title',
      universeId: 'universe-1',
      sessionId: 's-9',
      source: 'chat',
      type: 'episode',
      stability: 1.5,
      embedding: [0.1, 0.2],
    })).toMatchObject({
      userId: 'user-1',
      characterId: 'char-1',
      characterName: 'AIRI',
      title: 'Custom title',
      universeId: 'universe-1',
      sessionId: 's-9',
      source: 'chat',
      type: 'episode',
      stability: 1.5,
      embedding: [0.1, 0.2],
    })
  })

  it('falls back to a placeholder title for blank content', () => {
    expect(mod.toTextJournalEntry({ ...entry, content: '   ' }).title).toBe('Journal Entry')
  })
})