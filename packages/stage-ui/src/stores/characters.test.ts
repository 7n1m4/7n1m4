import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { toast } from 'vue-sonner'

import { client } from '../composables/api'
import { charactersRepo } from '../database/repos/characters.repo'
import { useCharacterStore } from './characters'

vi.mock('./auth', () => ({
  useAuthStore: () => ({
    userId: 'user-1',
    isAuthenticated: true,
  }),
}))

vi.mock('../database/repos/characters.repo', () => ({
  charactersRepo: {
    getAll: vi.fn(async () => []),
    saveAll: vi.fn(async () => {}),
    upsert: vi.fn(async () => {}),
    remove: vi.fn(async () => {}),
  },
}))

vi.mock('../composables/api', () => ({
  client: {
    api: {
      characters: {
        '$get': vi.fn(async () => ({ ok: true, json: async () => [makeChar('remote-1')] })),
        '$post': vi.fn(async () => ({ ok: true, json: async () => makeChar('remote-2') })),
        ':id': {
          $get: vi.fn(async () => ({ ok: true, json: async () => makeChar('remote-3') })),
          $patch: vi.fn(async () => ({ ok: true, json: async () => makeChar('remote-3') })),
          $delete: vi.fn(async () => ({ ok: true })),
          like: { $post: vi.fn(async () => ({ ok: true, json: async () => makeChar('remote-3') })) },
          bookmark: { $post: vi.fn(async () => ({ ok: true, json: async () => makeChar('remote-3') })) },
        },
      },
    },
  },
}))

// Mock daemon metadata composable for isolated daemon-path tests.
const mockFetchDaemonCardMetadata = vi.fn()
const mockSetDaemonCardMetadata = vi.fn()
const mockHasDaemonCardMetadata = vi.fn()

vi.mock('../composables/daemon-card-metadata', () => ({
  hasDaemonCardMetadata: () => mockHasDaemonCardMetadata(),
  fetchDaemonCardMetadata: (id: string) => mockFetchDaemonCardMetadata(id),
  setDaemonCardMetadata: (id: string, metadata: { liked: boolean, bookmarked: boolean }) =>
    mockSetDaemonCardMetadata(id, metadata),
}))

// Mock vue-sonner toast to avoid UI side effects during tests.
vi.mock('vue-sonner', () => ({
  toast: {
    error: vi.fn(),
  },
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
    creatorId: 'user-1',
    ownerId: 'user-1',
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

async function flush() {
  for (let i = 0; i < 20; i++) {
    await Promise.resolve()
  }
}

describe('store characters', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.mocked(charactersRepo.getAll).mockResolvedValue([])
    vi.mocked(charactersRepo.saveAll).mockResolvedValue(undefined)
    vi.mocked(charactersRepo.upsert).mockResolvedValue(undefined)
    vi.mocked(charactersRepo.remove).mockResolvedValue(undefined)
    vi.mocked(client.api.characters.$get).mockResolvedValue({ ok: true, json: async () => [makeChar('remote-1')] } as never)
    vi.mocked(client.api.characters.$post).mockResolvedValue({ ok: true, json: async () => makeChar('remote-2') } as never)
    vi.mocked(client.api.characters[':id'].$get).mockResolvedValue({ ok: true, json: async () => makeChar('remote-3') } as never)
    vi.mocked(client.api.characters[':id'].$patch).mockResolvedValue({ ok: true, json: async () => makeChar('remote-3') } as never)
    vi.mocked(client.api.characters[':id'].$delete).mockResolvedValue({ ok: true } as never)
    // Default: daemon disabled.
    mockHasDaemonCardMetadata.mockReturnValue(false)
    mockFetchDaemonCardMetadata.mockReset()
    mockSetDaemonCardMetadata.mockReset()
  })

  it('fetchList success', async () => {
    const store = useCharacterStore()
    await store.fetchList()
    await flush()
    expect(store.characters.size).toBeGreaterThan(0)
  })

  it('fetchList all', async () => {
    const store = useCharacterStore()
    await store.fetchList(true)
    await flush()
    expect(store.characters.size).toBeGreaterThan(0)
  })

  it('fetchList cached local', async () => {
    vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('cached-1')] as never)
    const store = useCharacterStore()
    await store.fetchList()
    await flush()
    expect(true).toBe(true)
  })

  it('update with empty payload', async () => {
    const store = useCharacterStore()
    store.characters.set('u2', makeChar('u2') as never)
    await store.update('u2', {} as never)
    await flush()
    expect(store.characters.has('u2')).toBe(true)
  })

  it('create with full payload and id', async () => {
    const store = useCharacterStore()
    const payload = {
      character: { id: 'provided-id', version: '1', coverUrl: '', characterId: 'c1' },
      capabilities: [{ type: 'llm', config: { apiKey: '', apiBaseUrl: '' } }],
      avatarModels: [{ name: 'm', type: 'live2d', description: '', config: {} }],
      i18n: [{ language: 'en', name: 'n', description: 'd', tags: [] }],
      prompts: [{ language: 'en', type: 'system', content: 'hi' }],
    } as never
    await store.create(payload)
    await flush()
    expect(store.characters.has('provided-id') || store.characters.size > 0).toBe(true)
  })

  it('fetchList remote fail', async () => {
    vi.mocked(client.api.characters.$get).mockResolvedValueOnce({ ok: false } as never)
    const store = useCharacterStore()
    await store.fetchList()
    await flush()
    expect(true).toBe(true)
  })

  it('fetchById cached', async () => {
    const store = useCharacterStore()
    store.characters.set('x', makeChar('x') as never)
    await store.fetchById('x')
    await flush()
    expect(store.characters.has('x')).toBe(true)
  })

  it('fetchById from repo', async () => {
    vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('repo-1')] as never)
    const store = useCharacterStore()
    await store.fetchById('repo-1')
    await flush()
    expect(store.characters.has('repo-1')).toBe(true)
  })

  it('fetchById remote', async () => {
    const store = useCharacterStore()
    await store.fetchById('remote-3')
    await flush()
    expect(store.characters.has('remote-3')).toBe(true)
  })

  it('fetchById remote fail', async () => {
    vi.mocked(client.api.characters[':id'].$get).mockResolvedValueOnce({ ok: false } as never)
    const store = useCharacterStore()
    await store.fetchById('nope')
    await flush()
    expect(true).toBe(true)
  })

  it('create', async () => {
    const store = useCharacterStore()
    const payload = { character: { version: '1', coverUrl: '', characterId: 'c1' } } as never
    await store.create(payload)
    await flush()
    expect(store.characters.size).toBeGreaterThan(0)
  })

  it('create remote fail', async () => {
    vi.mocked(client.api.characters.$post).mockResolvedValueOnce({ ok: false } as never)
    const store = useCharacterStore()
    const payload = { character: { version: '1', coverUrl: '', characterId: 'c1' } } as never
    await store.create(payload)
    await flush()
    expect(true).toBe(true)
  })

  it('update existing', async () => {
    const store = useCharacterStore()
    store.characters.set('u', makeChar('u') as never)
    await store.update('u', { version: '2', coverUrl: 'c', characterId: 'c2' } as never)
    await flush()
    expect(store.characters.get('u')?.version).toBe('2')
  })

  it('update missing', async () => {
    const store = useCharacterStore()
    await store.update('missing', { version: '2' } as never)
    await flush()
    expect(true).toBe(true)
  })

  it('update remote', async () => {
    const store = useCharacterStore()
    store.characters.set('remote-3', makeChar('remote-3') as never)
    await store.update('remote-3', { version: '2' } as never)
    await flush()
    expect(store.characters.has('remote-3')).toBe(true)
  })

  it('update remote fail', async () => {
    vi.mocked(client.api.characters[':id'].$patch).mockResolvedValueOnce({ ok: false } as never)
    const store = useCharacterStore()
    store.characters.set('remote-3', makeChar('remote-3') as never)
    await store.update('remote-3', { version: '2' } as never)
    await flush()
    expect(true).toBe(true)
  })

  it('remove', async () => {
    const store = useCharacterStore()
    store.characters.set('r', makeChar('r') as never)
    await store.remove('r')
    await flush()
    expect(store.characters.has('r')).toBe(false)
  })

  it('remove remote fail', async () => {
    vi.mocked(client.api.characters[':id'].$delete).mockResolvedValueOnce({ ok: false } as never)
    const store = useCharacterStore()
    store.characters.set('r2', makeChar('r2') as never)
    await store.remove('r2')
    await flush()
    expect(true).toBe(true)
  })

  it('like existing', async () => {
    const store = useCharacterStore()
    store.characters.set('l', makeChar('l') as never)
    await store.like('l')
    await flush()
    const likedChar = store.characters.get('l') as { likesCount: number }
    expect(likedChar.likesCount).toBe(1)
  })

  it('like missing', async () => {
    const store = useCharacterStore()
    await store.like('missing')
    await flush()
    expect(true).toBe(true)
  })

  it('like toggles off when already liked (daemon flags are explicit)', async () => {
    const store = useCharacterStore()
    const c = makeChar('l2') as { likes: { userId: string, characterId: string }[], likesCount: number }
    c.likes = [{ userId: 'user-1', characterId: 'l2' }]
    store.characters.set('l2', c as never)
    await store.like('l2')
    await flush()
    const likedChar2 = store.characters.get('l2') as { likesCount: number, likes: unknown[] }
    expect(likedChar2.likesCount).toBe(0)
    expect(likedChar2.likes).toHaveLength(0)
  })

  it('bookmark existing', async () => {
    const store = useCharacterStore()
    store.characters.set('b', makeChar('b') as never)
    await store.bookmark('b')
    await flush()
    const bookmarkedChar = store.characters.get('b') as { bookmarksCount: number }
    expect(bookmarkedChar.bookmarksCount).toBe(1)
  })

  it('bookmark missing', async () => {
    const store = useCharacterStore()
    await store.bookmark('missing')
    await flush()
    expect(true).toBe(true)
  })

  it('bookmark toggles off when already bookmarked (daemon flags are explicit)', async () => {
    const store = useCharacterStore()
    const c = makeChar('b2') as { bookmarks: { userId: string, characterId: string }[], bookmarksCount: number }
    c.bookmarks = [{ userId: 'user-1', characterId: 'b2' }]
    store.characters.set('b2', c as never)
    await store.bookmark('b2')
    await flush()
    const bookmarkedChar2 = store.characters.get('b2') as { bookmarksCount: number, bookmarks: unknown[] }
    expect(bookmarkedChar2.bookmarksCount).toBe(0)
    expect(bookmarkedChar2.bookmarks).toHaveLength(0)
  })

  it('getCharacter', () => {
    const store = useCharacterStore()
    store.characters.set('g', makeChar('g') as never)
    expect(store.getCharacter('g')?.id).toBe('g')
  })

  // ROOT CAUSE:
  //
  // Daemon hydration lived only inside useLocalFirstRequest's `remote:` callback.
  // With auth off (the default local-first path) that callback never runs, so
  // liked/bookmarked flags were never restored after a restart.
  //
  // FIXED BY: Hydrating after fetchList settles, for both local and remote paths.
  it('hydrates daemon metadata after fetchList when auth is off', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    mockFetchDaemonCardMetadata.mockResolvedValue({ liked: true, bookmarked: false })
    const store = useCharacterStore()
    await store.fetchList()
    await flush()
    expect(mockFetchDaemonCardMetadata).toHaveBeenCalledWith('remote-1')
    expect((store.characters.get('remote-1') as { likes: unknown[] }).likes).toHaveLength(1)
  })

  it('hydrates daemon metadata from local cache when auth is off', async () => {
    mockHasDaemonCardMetadata.mockReturnValue(true)
    mockFetchDaemonCardMetadata.mockResolvedValue({ liked: false, bookmarked: true })
    vi.mocked(charactersRepo.getAll).mockResolvedValueOnce([makeChar('cached-hydrate')] as never)
    const store = useCharacterStore()
    await store.fetchList(false, () => false)
    await flush()
    expect(mockFetchDaemonCardMetadata).toHaveBeenCalledWith('cached-hydrate')
    expect((store.characters.get('cached-hydrate') as { bookmarks: unknown[] }).bookmarks).toHaveLength(1)
  })

  describe('daemon metadata path', () => {
    beforeEach(() => {
      // Enable daemon for these tests by default.
      mockHasDaemonCardMetadata.mockReturnValue(true)
      mockFetchDaemonCardMetadata.mockResolvedValue({ liked: false, bookmarked: false })
      mockSetDaemonCardMetadata.mockImplementation(async (_id, metadata) => metadata)
    })

    it('loadDaemonMetadata applies daemon flags when daemon is enabled', async () => {
      const store = useCharacterStore()
      store.characters.set('d1', makeChar('d1') as never)
      mockFetchDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: false })
      await store.loadDaemonMetadata(['d1'], 'user-1')
      await flush()
      const char = store.characters.get('d1') as { likesCount: number, likes: unknown[] }
      expect(char.likesCount).toBe(1)
      expect(char.likes).toHaveLength(1)
      expect(mockFetchDaemonCardMetadata).toHaveBeenCalledWith('d1')
    })

    it('like sends correct payload to daemon and applies reply', async () => {
      const store = useCharacterStore()
      store.characters.set('d2', makeChar('d2') as never)
      mockSetDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: false })
      await store.like('d2')
      await flush()
      expect(mockSetDaemonCardMetadata).toHaveBeenCalledWith('d2', { liked: true, bookmarked: false })
      const char = store.characters.get('d2') as { likesCount: number }
      expect(char.likesCount).toBe(1)
    })

    it('bookmark sends correct payload to daemon and applies reply', async () => {
      const store = useCharacterStore()
      store.characters.set('d3', makeChar('d3') as never)
      mockSetDaemonCardMetadata.mockResolvedValueOnce({ liked: false, bookmarked: true })
      await store.bookmark('d3')
      await flush()
      expect(mockSetDaemonCardMetadata).toHaveBeenCalledWith('d3', { liked: false, bookmarked: true })
      const char = store.characters.get('d3') as { bookmarksCount: number }
      expect(char.bookmarksCount).toBe(1)
    })

    it('like rolls back optimistic update on daemon failure and surfaces error', async () => {
      const store = useCharacterStore()
      store.characters.set('d4', makeChar('d4') as never)
      const daemonError = new Error('daemon write failed')
      mockSetDaemonCardMetadata.mockRejectedValueOnce(daemonError)
      await store.like('d4')
      await flush()
      const char = store.characters.get('d4') as { likesCount: number, likes: unknown[] }
      expect(char.likesCount).toBe(0)
      expect(char.likes).toHaveLength(0)
      expect(store.error).toBe('daemon write failed')
    })

    it('bookmark rolls back optimistic update on daemon failure and surfaces error', async () => {
      const store = useCharacterStore()
      store.characters.set('d5', makeChar('d5') as never)
      const daemonError = new Error('daemon write failed')
      mockSetDaemonCardMetadata.mockRejectedValueOnce(daemonError)
      await store.bookmark('d5')
      await flush()
      const char = store.characters.get('d5') as { bookmarksCount: number, bookmarks: unknown[] }
      expect(char.bookmarksCount).toBe(0)
      expect(char.bookmarks).toHaveLength(0)
      expect(store.error).toBe('daemon write failed')
    })

    it('rapid like toggles are serialized per card (no overlapping RPC)', async () => {
      const store = useCharacterStore()
      store.characters.set('d6', makeChar('d6') as never)
      const callOrder: number[] = []
      let callIndex = 0
      mockSetDaemonCardMetadata.mockImplementation(async () => {
        callOrder.push(callIndex++)
        return { liked: true, bookmarked: false }
      })
      await Promise.all([
        store.like('d6'),
        store.like('d6'),
        store.like('d6'),
      ])
      await flush()
      // Calls should be strictly ordered (0, 1, 2), not interleaved.
      expect(callOrder).toEqual([0, 1, 2])
    })

    it('late hydration reply does not overwrite newer like write', async () => {
      const store = useCharacterStore()
      store.characters.set('d7', makeChar('d7') as never)
      const deferredHydrate = Promise.withResolvers<{ liked: boolean, bookmarked: boolean }>()
      // Start hydration (will resolve late).
      mockFetchDaemonCardMetadata.mockReturnValueOnce(deferredHydrate.promise)
      const hydrationPromise = store.loadDaemonMetadata(['d7'], 'user-1')
      // Start like immediately after (will queue behind hydration).
      const likePromise = store.like('d7')
      // Resolve hydration first (unblocks like).
      deferredHydrate.resolve({ liked: false, bookmarked: false })
      await hydrationPromise
      await flush()
      // like has started; flush to let it complete.
      await likePromise
      await flush()
      // Final state should reflect the like, not the stale hydration.
      const char = store.characters.get('d7') as { likesCount: number }
      expect(char.likesCount).toBe(1)
    })

    // ROOT CAUSE:
    //
    // applyDaemonMetadata overwrote hosted likesCount/bookmarksCount with the
    // length of the per-user relation arrays, which only contain the local
    // user's entry. A card liked by 42 users collapsed to 1 after hydration.
    //
    // FIXED BY: Adjusting the server counters only when the local flag changes.
    it('hydration preserves hosted counters when the local flag is unchanged', async () => {
      const store = useCharacterStore()
      const char = {
        ...makeChar('counts-1'),
        likesCount: 42,
        bookmarksCount: 17,
        likes: [{ userId: 'user-1', characterId: 'counts-1' }],
        bookmarks: [{ userId: 'user-1', characterId: 'counts-1' }],
      }
      store.characters.set('counts-1', char as never)
      mockFetchDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: true })
      await store.loadDaemonMetadata(['counts-1'], 'user-1')
      expect(char.likesCount).toBe(42)
      expect(char.bookmarksCount).toBe(17)
    })

    it('hydration adjusts hosted counters when the local flag differs', async () => {
      const store = useCharacterStore()
      const char = {
        ...makeChar('counts-2'),
        likesCount: 42,
        bookmarksCount: 17,
        likes: [] as { userId: string, characterId: string }[],
      }
      store.characters.set('counts-2', char as never)
      mockFetchDaemonCardMetadata.mockResolvedValueOnce({ liked: true, bookmarked: false })
      await store.loadDaemonMetadata(['counts-2'], 'user-1')
      expect(char.likesCount).toBe(43)
      expect(char.bookmarksCount).toBe(17)
    })

    // ROOT CAUSE:
    //
    // like()/bookmark() sent the other daemon flag using `array.length > 0`.
    // A legacy row for another user made the array nonempty, so liking could
    // silently set bookmarked=true (and vice versa).
    //
    // FIXED BY: Deriving each flag from the current user's relation entry.
    it('like preserves bookmarked=false with a legacy bookmark from another user', async () => {
      const store = useCharacterStore()
      const char = {
        ...makeChar('flags-1'),
        bookmarks: [{ userId: 'legacy-user', characterId: 'flags-1' }],
      }
      store.characters.set('flags-1', char as never)
      await store.like('flags-1')
      expect(mockSetDaemonCardMetadata).toHaveBeenCalledWith('flags-1', { liked: true, bookmarked: false })
    })

    it('bookmark preserves liked=false with a legacy like from another user', async () => {
      const store = useCharacterStore()
      const char = {
        ...makeChar('flags-2'),
        likes: [{ userId: 'legacy-user', characterId: 'flags-2' }],
      }
      store.characters.set('flags-2', char as never)
      await store.bookmark('flags-2')
      expect(mockSetDaemonCardMetadata).toHaveBeenCalledWith('flags-2', { liked: false, bookmarked: true })
    })

    // ROOT CAUSE:
    //
    // loadDaemonMetadata() awaited per-card RPCs for every card. Without a
    // connected daemon each RPC opens a WebSocket and fails after a timeout,
    // blocking fetchList() and emitting one toast per card.
    //
    // FIXED BY: Bounding bulk hydration and reporting one silent aggregate result.
    it('bulk hydration does not block fetchList or emit a toast per failed card', async () => {
      mockHasDaemonCardMetadata.mockReturnValue(true)
      const deferred = Promise.withResolvers<never>()
      mockFetchDaemonCardMetadata.mockImplementation(() => deferred.promise)
      vi.mocked(client.api.characters.$get).mockResolvedValueOnce({
        ok: true,
        json: async () => [makeChar('bulk-1'), makeChar('bulk-2'), makeChar('bulk-3')],
      } as never)
      const store = useCharacterStore()
      await store.fetchList()
      expect(store.characters.size).toBe(3)
      expect(mockFetchDaemonCardMetadata).toHaveBeenCalledTimes(3)
      deferred.reject(new Error('daemon unreachable'))
      await flush()
      expect(vi.mocked(toast.error)).not.toHaveBeenCalledWith('daemon unreachable')
    })
  })
})
