import type { ShortTermMemoryBlock } from '../types/short-term-memory'

/**
 * Contract for the short-term-memory store's daemon seam.
 *
 * The daemon owns the summary *bodies* (`stmm.list` / `stmm.upsert` /
 * `stmm.rebuild`); the store keeps day bucketing, per-card budgets, universe
 * scoping and the IndexedDB cache. Only the transport and the repo are mocked
 * here — loading, daemon healing, mirroring and pruning all run for real.
 */

import { createTestingPinia } from '@pinia/testing'
import { setActivePinia } from 'pinia'
import { ref } from 'vue'
import { beforeEach, describe, expect, it, vi } from 'vitest'

// Static import (not `await import`) so the mocked transport instance is the
// same module object the store closes over.
import { daemonRequest } from '../composables/daemon-rpc'
import { shortTermMemoryRepo } from '../database/repos/short-term-memory.repo'
import { useShortTermMemoryStore } from './memory-short-term'

const h = vi.hoisted(() => ({
  useDaemon: true,
  summaries: [] as Array<Record<string, unknown>>,
  listCalls: 0,
  upsertCalls: [] as Array<Record<string, unknown>>,
  rebuildCalls: 0,
  deleteCalls: [] as Array<Record<string, unknown>>,
  deleteFails: false,
  cached: [] as ShortTermMemoryBlock[],
  saved: [] as ShortTermMemoryBlock[][],
}))

vi.mock('../composables/daemon-rpc', () => ({
  hasDaemon: () => h.useDaemon,
  daemonRequest: vi.fn(async (action: string, payload: Record<string, unknown> = {}) => {
    if (action === 'stmm.list') {
      h.listCalls += 1
      return { summaries: h.summaries }
    }
    if (action === 'stmm.upsert') {
      const blocks = (payload.blocks ?? []) as Array<Record<string, unknown>>
      h.upsertCalls.push(payload)
      for (const block of blocks) {
        const index = h.summaries.findIndex(row => row.id === block.id)
        const row = {
          id: block.id,
          day: block.day,
          content: block.content,
          source_session_ids: block.sourceSessionIds ?? [],
          token_estimate: block.tokenEstimate ?? 0,
          created_at: block.createdAt ?? 0,
        }
        if (index >= 0)
          h.summaries.splice(index, 1, row)
        else
          h.summaries.push(row)
      }
      return { upserted: blocks.length }
    }
    if (action === 'stmm.delete') {
      h.deleteCalls.push(payload)
      if (h.deleteFails)
        throw new Error('daemon delete unavailable')
      const index = h.summaries.findIndex(row => row.id === payload.id)
      if (index >= 0)
        h.summaries.splice(index, 1)
      return { deleted: index >= 0 }
    }
    if (action === 'stmm.rebuild') {
      h.rebuildCalls += 1
      return { ok: true, pruned: 0 }
    }
    throw new Error(`unexpected daemon action: ${action}`)
  }),
}))

vi.mock('../database/repos/short-term-memory.repo', () => ({
  shortTermMemoryRepo: {
    getAll: vi.fn(async () => h.cached),
    saveAll: vi.fn(async (_userId: string, blocks: ShortTermMemoryBlock[]) => {
      h.saved.push(blocks)
      h.cached = blocks
    }),
  },
}))

// The cast keeps the real module's exports while replacing the broadcast channel.
vi.mock('@vueuse/core', async (importOriginal) => ({ ...(await importOriginal() as object), useBroadcastChannel: () => ({ data: ref(0), post: vi.fn() }) }))

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (key: string) => key }),
}))

// The card/session stores pull in the whole stage UI; the store under test only
// needs their refs, so they are stubbed at the seam.
vi.mock('./modules/airi-card', () => ({
  useAiriCardStore: () => ({
    cards: ref(new Map<string, never>()),
    activeCardId: ref('card-1'),
  }),
}))

vi.mock('./chat/session-store', () => ({
  useChatSessionStore: () => ({
    activeSessionId: 'session-1',
    getCharacterIndex: () => null,
    getSessionMeta: () => null,
  }),
}))

vi.mock('./modules/consciousness', () => ({
  useConsciousnessStore: () => ({ activeProvider: 'p', activeModel: 'm' }),
}))

vi.mock('./providers', () => ({
  useProvidersStore: () => ({ getProviderInstance: vi.fn(async () => ({})) }),
}))

vi.mock('./llm', () => ({
  useLLM: () => ({ generate: vi.fn(async () => ({ text: '', usage: null })) }),
}))

const CARD_ID = 'card-1'
const USER_ID = 'local'

function block(overrides: Partial<ShortTermMemoryBlock> = {}): ShortTermMemoryBlock {
  return {
    id: 'sum-1',
    userId: USER_ID,
    characterId: CARD_ID,
    characterName: 'Airi',
    date: '2026-11-20',
    source: 'rebuilt',
    summary: 'we talked about the rain',
    estimatedTokens: 6,
    messageCount: 4,
    sessionCount: 1,
    createdAt: 1_000,
    updatedAt: 1_000,
    universeId: 'global',
    sessionId: 'session-1',
    ...overrides,
  }
}

function daemonRow(id: string, day: string, content: string) {
  return {
    id,
    day,
    content,
    source_session_ids: ['session-1'],
    token_estimate: 3,
    created_at: 2_000,
  }
}

beforeEach(() => {
  h.useDaemon = true
  h.summaries = []
  h.listCalls = 0
  h.upsertCalls = []
  h.rebuildCalls = 0
  h.deleteCalls = []
  h.deleteFails = false
  h.cached = []
  h.saved = []
  vi.mocked(daemonRequest).mockClear()
  setActivePinia(createTestingPinia({ createSpy: vi.fn, stubActions: false }))
})

describe('short-term memory store daemon authority', () => {
  it('lists daemon summaries on load and keeps the local cache when no daemon exists', async () => {
    h.cached = [block()]
    h.summaries = [daemonRow('sum-1', '2026-11-20', 'daemon healed body')]
    const store = useShortTermMemoryStore()

    await store.load(true)

    expect(h.listCalls).toBe(1)
    // Daemon body wins, local scope (card/universe/source) is preserved.
    expect(store.blocks).toHaveLength(1)
    expect(store.blocks[0].summary).toBe('daemon healed body')
    expect(store.blocks[0].characterId).toBe(CARD_ID)
    expect(store.blocks[0].source).toBe('rebuilt')

    h.useDaemon = false
    h.cached = [block({ id: 'sum-2', summary: 'local only' })]
    const webStore = useShortTermMemoryStore()
    await webStore.load(true)
    expect(webStore.blocks[0].summary).toBe('local only')
  })

  it('drops daemon rows the local cache does not know, so per-card/universe scope stays Vue-owned', async () => {
    h.cached = [block()]
    h.summaries = [daemonRow('sum-1', '2026-11-20', 'known'), daemonRow('sum-9', '2026-11-19', 'orphan')]
    const store = useShortTermMemoryStore()

    await store.load(true)

    expect(store.blocks.map(b => b.id)).toEqual(['sum-1'])
  })

  it('mirrors generated blocks through stmm.upsert in chunks of 100', async () => {
    const store = useShortTermMemoryStore()
    const many = Array.from({ length: 250 }, (_, index) => block({
      // zero-padded ids so lexicographic id ordering keeps the fixture order (normalizeBlocks sorts by id)
      id: `sum-${String(index).padStart(3, '0')}`,
      // 250 distinct days: normalizeBlocks dedupes by (user, card, date, universe), so the fixture must not share a day.
      date: `2026-11-${String(index + 1).padStart(2, '0')}`,
      sessionId: `session-${index}`,
    }))

    await store.persist(many)

    expect(h.upsertCalls).toHaveLength(3)
    expect(h.upsertCalls.map(call => (call.blocks as unknown[]).length)).toEqual([100, 100, 50])
    expect((h.upsertCalls[0].blocks as Array<Record<string, unknown>>)[0]).toEqual({
      id: 'sum-000',
      day: '2026-11-01',
      content: 'we talked about the rain',
      tokenEstimate: 6,
      sourceSessionIds: ['session-0'],
      createdAt: 1_000,
    })
  })

  it('keeps the local snapshot when the daemon upsert fails', async () => {
    vi.mocked(daemonRequest).mockRejectedValueOnce(new Error('daemon unreachable'))
    const store = useShortTermMemoryStore()

    await expect(store.persist([block()])).resolves.toBeUndefined()
    expect(h.saved).toHaveLength(1)
    expect(store.blocks).toHaveLength(1)
  })

  // ROOT CAUSE:
  //
  // The old delete re-upserted the surviving snapshot and relied on a
  // prune-by-age rebuild, which never removed the deleted row. A fresh load
  // then merged the row back from `stmm.list` and resurrected the block.
  it('deletes the daemon row directly so it cannot resurrect on reload', async () => {
    h.cached = [block(), block({ id: 'sum-2', date: '2026-11-21', summary: 'second' })]
    h.summaries = [daemonRow('sum-1', '2026-11-20', 'first'), daemonRow('sum-2', '2026-11-21', 'second')]
    const store = useShortTermMemoryStore()
    await store.load(true)

    await expect(store.deleteBlock('sum-1')).resolves.toBe(true)

    expect(h.deleteCalls).toEqual([{ id: 'sum-1' }])
    expect(h.rebuildCalls).toBe(0)
    expect(h.summaries.map(row => row.id)).toEqual(['sum-2'])

    // Fresh store/window: the daemon no longer carries the deleted row.
    h.cached = []
    const fresh = useShortTermMemoryStore()
    await fresh.load(true)
    expect(fresh.blocks.map(b => b.id)).toEqual([])
  })

  it('keeps the local block when the daemon delete fails', async () => {
    h.cached = [block()]
    h.summaries = [daemonRow('sum-1', '2026-11-20', 'first')]
    h.deleteFails = true
    const store = useShortTermMemoryStore()
    await store.load(true)

    await expect(store.deleteBlock('sum-1')).rejects.toThrow('daemon delete unavailable')
    expect(store.blocks.map(b => b.id)).toEqual(['sum-1'])
    expect(h.saved).toHaveLength(0)
    expect(h.summaries.map(row => row.id)).toEqual(['sum-1'])
  })

  it('dedupes blocks that share user/card/date/universe on load', async () => {
    h.cached = [
      block({ id: 'sum-1', updatedAt: 10 }),
      block({ id: 'sum-1b', updatedAt: 99, messageCount: 9 }),
    ]
    h.useDaemon = false
    const store = useShortTermMemoryStore()

    await store.load(true)

    expect(store.blocks).toHaveLength(1)
    expect(store.blocks[0].id).toBe('sum-1b')
  })

  it('surfaces a repo load failure through error and rethrows', async () => {
    vi.mocked(shortTermMemoryRepo.getAll).mockRejectedValueOnce(new Error('indexeddb down'))
    const store = useShortTermMemoryStore()

    await expect(store.load(true)).rejects.toThrow('indexeddb down')
    expect(store.error).toBe('indexeddb down')
  })
})