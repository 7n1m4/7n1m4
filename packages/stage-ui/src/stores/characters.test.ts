import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { toast } from 'vue-sonner'

import { charactersRepo } from '../database/repos/characters.repo'
import { useCharacterStore } from './characters'

vi.mock('../database/repos/characters.repo', () => ({
  charactersRepo: {
    getAll: vi.fn(async () => []),
    saveAll: vi.fn(async () => {}),
    upsert: vi.fn(async () => {}),
    remove: vi.fn(async () => {}),
  },
}))

const mockFetchDaemonCardMetadata = vi.fn()
const mockSetDaemonCardMetadata = vi.fn()
const mockHasDaemonCardMetadata = vi.fn()
const mockListDaemonCards = vi.fn()
const mockGetDaemonCard = vi.fn()
const mockCreateDaemonCard = vi.fn()
const mockUpdateDaemonCard = vi.fn()
const mockDeleteDaemonCard = vi.fn()

vi.mock('../composables/daemon-card-metadata', () => ({
  hasDaemonCardMetadata: () => mockHasDaemonCardMetadata(),
  fetchDaemonCardMetadata: (...args: unknown[]) => mockFetchDaemonCardMetadata(...args),
  setDaemonCardMetadata: (...args: unknown[]) => mockSetDaemonCardMetadata(...args),
  listDaemonCards: (...args: unknown[]) => mockListDaemonCards(...args),
  getDaemonCard: (...args: unknown[]) => mockGetDaemonCard(...args),
  createDaemonCard: (...args: unknown[]) => mockCreateDaemonCard(...args),
  updateDaemonCard: (...args: unknown[]) => mockUpdateDaemonCard(...args),
  deleteDaemonCard: (...args: unknown[]) => mockDeleteDaemonCard(...args),
}))

vi.mock('vue-sonner', () => ({
  toast: { error: vi.fn() },
}))

function makeChar(id: string) {
  return {
    id,
    version: '1',
    coverUrl: '',
    priceCredit: '0',
    likesCount: 0,
    bookmarksCount: 0,
    interactionsCount: 0,
    forksCount: 0,
    creatorId: 'local',
    ownerId: 'local',
    characterId: 'c1',
    createdAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    capabilities: [],
    avatarModels: [],
    i18n: [],
    prompts: [],
    likes: [],
    bookmarks: [],
  }
}

function daemonDocument(id: string) {
  return { card: makeChar(id) }
}

async function flush() {
  for (let i = 0; i < 20; i++)
    await Promise.resolve()
}

describe('store characters (local-first + daemon RPC)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(charactersRepo.getAll).mockResolvedValue([])
    vi.mocked(charactersRepo.saveAll).mockResolvedValue(undefined)
    vi.mocked(charactersRepo.upsert).mockResolvedValue(undefined)
    vi.mocked(charactersRepo.remove).mockResolvedValue(undefined)
    mockHasDaemonCardMetadata.mockReturnValue(false)
    mockFetchDaemonCardMetadata.mockReset()
    mockSetDaemonCardMetadata.mockReset()
    mockListDaemonCards.mockReset()
    mockGetDaemonCard.mockReset()
    mockCreateDaemonCard.mockReset()
    mockUpdateDaemonCard.mockReset()
    mockDeleteDaemonCard.mockReset()
    mockListDaemonCards.mockResolvedValue({ cards: [], truncated: false })
    mockGetDaemonCard.mockImplementation(async (id: string) => daemonDocument(id))
    mockCreateDaemonCard.mockImplementation(async (id: string) => ({ id }))
    mockUpdateDaemonCard.mockResolvedValue({ updated: true })
    mockDeleteDaemonCard.mockResolvedValue({ deleted: true })
  })

  it('loads the local cache without a daemon', async () => {
    vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('cached-1')] as never)
    const store = useCharacterStore()
    await store.fetchList()
    expect(store.characters.get('cached-1')?.id).toBe('cached-1')
    expect(mockListDaemonCards).not.toHaveBeenCalled()
  })

  it('hydrates from daemon cards when a daemon is available', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    mockListDaemonCards.mockResolvedValueOnce({ cards: [{ id: 'daemon-1', name: 'daemon-1' }], truncated: false })
    const store = useCharacterStore()
    await store.fetchList()
    expect(mockGetDaemonCard).toHaveBeenCalledWith('daemon-1')
    expect(store.characters.get('daemon-1')?.id).toBe('daemon-1')
    expect(charactersRepo.saveAll).toHaveBeenCalled()
  })

  it('keeps local cards when daemon listing fails', async () => {
    vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('cached-2')] as never)
    mockHasDaemonCardMetadata.mockReturnValue(true)
    mockListDaemonCards.mockRejectedValueOnce(new Error('daemon unreachable'))
    const store = useCharacterStore()
    await store.fetchList()
    expect(store.characters.get('cached-2')?.id).toBe('cached-2')
  })

  it('fetchById reads from the daemon and caches locally', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    const store = useCharacterStore()
    const found = await store.fetchById('remote-3')
    expect(found?.id).toBe('remote-3')
    expect(charactersRepo.upsert).toHaveBeenCalled()
  })

  it('fetchById returns undefined for a missing card', async () => {
    const store = useCharacterStore()
    expect(await store.fetchById('nope')).toBeUndefined()
  })

  it('create persists locally then writes the full document to the daemon', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    const store = useCharacterStore()
    const created = await store.create({
      character: { id: 'provided-id', version: '1', coverUrl: '', characterId: 'c1' },
      capabilities: [],
      avatarModels: [],
      i18n: [],
      prompts: [],
    } as never)
    expect(created.id).toBe('provided-id')
    expect(mockCreateDaemonCard).toHaveBeenCalledWith('provided-id', expect.objectContaining({ id: 'provided-id' }))
    expect(charactersRepo.upsert).toHaveBeenCalled()
  })

  it('create keeps the local copy when daemon write fails', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    mockCreateDaemonCard.mockRejectedValueOnce(new Error('daemon write failed'))
    const store = useCharacterStore()
    const created = await store.create({ character: { version: '1', coverUrl: '', characterId: 'c1' } } as never)
    expect(store.characters.has(created.id)).toBe(true)
    expect(store.error).toBe('daemon write failed')
    expect(toast.error).toHaveBeenCalledWith('daemon write failed')
  })

  it('update applies locally and mirrors to daemon', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    const store = useCharacterStore()
    store.characters.set('u', makeChar('u') as never)
    await store.update('u', { version: '2', coverUrl: 'c', characterId: 'c2' } as never)
    expect(store.characters.get('u')?.version).toBe('2')
    expect(mockUpdateDaemonCard).toHaveBeenCalledWith('u', expect.objectContaining({ version: '2' }))
  })

  it('update on a missing card is a no-op', async () => {
    const store = useCharacterStore()
    await store.update('missing', { version: '2' } as never)
    expect(mockUpdateDaemonCard).not.toHaveBeenCalled()
  })

  it('remove deletes locally and through the daemon', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    const store = useCharacterStore()
    store.characters.set('r', makeChar('r') as never)
    await store.remove('r')
    expect(store.characters.has('r')).toBe(false)
    expect(mockDeleteDaemonCard).toHaveBeenCalledWith('r')
    expect(charactersRepo.remove).toHaveBeenCalledWith('r')
  })

  it('like toggles on/off using the local user id', async () => {
    const store = useCharacterStore()
    store.characters.set('l', makeChar('l') as never)
    await store.like('l')
    await flush()
    expect((store.characters.get('l') as { likesCount: number }).likesCount).toBe(1)
    await store.like('l')
    await flush()
    expect((store.characters.get('l') as { likesCount: number }).likesCount).toBe(0)
  })

  it('bookmark toggles on/off using the local user id', async () => {
    const store = useCharacterStore()
    store.characters.set('b', makeChar('b') as never)
    await store.bookmark('b')
    await flush()
    expect((store.characters.get('b') as { bookmarksCount: number }).bookmarksCount).toBe(1)
  })

  it('getCharacter returns the cached character', () => {
    const store = useCharacterStore()
    store.characters.set('g', makeChar('g') as never)
    expect(store.getCharacter('g')?.id).toBe('g')
  })

  describe('daemon metadata path', () => {
    beforeEach(() => {
      mockHasDaemonCardMetadata.mockReturnValue(true)
      mockFetchDaemonCardMetadata.mockResolvedValue({ liked: false, bookmarked: false })
      mockSetDaemonCardMetadata.mockImplementation(async (_id: string, metadata: unknown) => metadata)
    })

    it('hydrates daemon flags after fetchList', async () => {
      mockFetchDaemonCardMetadata.mockResolvedValue({ liked: true, bookmarked: false })
      vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('cached-hydrate')] as never)
      const store = useCharacterStore()
      await store.fetchList()
      await flush()
      expect(mockFetchDaemonCardMetadata).toHaveBeenCalledWith('cached-hydrate')
      expect((store.characters.get('cached-hydrate') as { likes: unknown[] }).likes).toHaveLength(1)
    })

    it('applies daemon flags from loadDaemonMetadata', async () => {
      const store = useCharacterStore()
      store.characters.set('d1', makeChar('d1') as never)
      mockFetchDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: false })
      await store.loadDaemonMetadata(['d1'])
      await flush()
      expect((store.characters.get('d1') as { likesCount: number }).likesCount).toBe(1)
    })

    it('like sends explicit daemon metadata and applies the reply', async () => {
      const store = useCharacterStore()
      store.characters.set('d2', makeChar('d2') as never)
      mockSetDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: false })
      await store.like('d2')
      await flush()
      expect(mockSetDaemonCardMetadata).toHaveBeenCalledWith('d2', { liked: true, bookmarked: false })
      expect((store.characters.get('d2') as { likesCount: number }).likesCount).toBe(1)
    })

    it('like rolls back optimistic state on daemon failure', async () => {
      const store = useCharacterStore()
      store.characters.set('d4', makeChar('d4') as never)
      mockSetDaemonCardMetadata.mockRejectedValueOnce(new Error('daemon write failed'))
      await store.like('d4')
      await flush()
      const char = store.characters.get('d4') as { likesCount: number, likes: unknown[] }
      expect(char.likesCount).toBe(0)
      expect(char.likes).toHaveLength(0)
      expect(store.error).toBe('daemon write failed')
    })

    it('bookmark rolls back optimistic state on daemon failure', async () => {
      const store = useCharacterStore()
      store.characters.set('d5', makeChar('d5') as never)
      mockSetDaemonCardMetadata.mockRejectedValueOnce(new Error('daemon write failed'))
      await store.bookmark('d5')
      await flush()
      const char = store.characters.get('d5') as { bookmarksCount: number, bookmarks: unknown[] }
      expect(char.bookmarksCount).toBe(0)
      expect(char.bookmarks).toHaveLength(0)
    })

    it('rapid toggles are serialized per card', async () => {
      const store = useCharacterStore()
      store.characters.set('d6', makeChar('d6') as never)
      let callIndex = 0
      const callOrder: number[] = []
      mockSetDaemonCardMetadata.mockImplementation(async () => {
        callOrder.push(callIndex++)
        return { liked: true, bookmarked: false }
      })
      await Promise.all([store.like('d6'), store.like('d6'), store.like('d6')])
      expect(callOrder).toStrictEqual([0, 1, 2])
    })

    it('bulk hydration never blocks fetchList or emits a toast per failed card', async () => {
      vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([
        makeChar('bulk-1'),
        makeChar('bulk-2'),
        makeChar('bulk-3'),
      ] as never)
      const deferred = Promise.withResolvers<never>()
      mockFetchDaemonCardMetadata.mockImplementation(() => deferred.promise)
      const store = useCharacterStore()
      await store.fetchList()
      expect(store.characters.size).toBe(3)
      expect(mockFetchDaemonCardMetadata).toHaveBeenCalledTimes(3)
      deferred.reject(new Error('daemon unreachable'))
      await flush()
      expect(toast.error).not.toHaveBeenCalledWith('daemon unreachable')
    })
  })
})
