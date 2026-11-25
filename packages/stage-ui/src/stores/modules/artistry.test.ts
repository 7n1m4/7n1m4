import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { resolveArtistryConfigFromStore, useArtistryStore } from './artistry'

describe('artistry store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    if (typeof localStorage !== 'undefined')
      localStorage.clear()
    vi.restoreAllMocks()
  })

  it('initializes with defaults', () => {
    const store = useArtistryStore()
    expect(store.activeProvider).toBe('comfyui')
    expect(store.activeModel).toBe('')
    expect(store.comfyuiServerUrl).toBe('http://localhost:8188')
    // Image generation is deprecated/disabled, so `configured` is always false.
    expect(store.configured).toBe(false)
  })

  it('configured is always false while generation is deprecated', () => {
    const store = useArtistryStore()
    store.activeProvider = 'replicate'
    store.replicateApiKey = 'key'
    expect(store.configured).toBe(false)

    store.activeProvider = 'comfyui'
    store.comfyuiServerUrl = 'http://x'
    expect(store.configured).toBe(false)

    store.activeProvider = 'pollinations'
    expect(store.configured).toBe(false)
  })

  it('resetState resets all', () => {
    const store = useArtistryStore()
    store.activeProvider = 'replicate'
    store.replicateApiKey = 'key'
    store.resetState()
    expect(store.activeProvider).toBe('comfyui')
    expect(store.replicateApiKey).toBe('')
  })

  it('fetchPollinationsModels returns cached when not forced', async () => {
    const store = useArtistryStore()
    store.pollinationsCachedModels = [{ id: 'x', name: 'X' }]
    const res = await store.fetchPollinationsModels()
    expect(res).toEqual([{ id: 'x', name: 'X' }])
  })

  it('fetchPollinationsModels fetches and parses', async () => {
    const store = useArtistryStore()
    const mockData = [{ name: 'm1', title: 'M1', category: 'image', pricing: { completionImageTokens: 0.5 } }]
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: async () => mockData,
    }))
    const res = await store.fetchPollinationsModels(true)
    expect(res[0].id).toBe('')
    expect(res[1].id).toBe('m1')
    expect(store.pollinationsCachedModels).toEqual(res)
  })

  it('fetchPollinationsModels non-ok falls back', async () => {
    const store = useArtistryStore()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({ ok: false, status: 500, json: async () => ({}) }))
    const res = await store.fetchPollinationsModels(true)
    expect(res.length).toBeGreaterThan(1)
  })

  it('fetchPollinationsModels fallback on failure', async () => {
    const store = useArtistryStore()
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('net')))
    const res = await store.fetchPollinationsModels(true)
    expect(res.length).toBeGreaterThan(1)
    expect(store.pollinationsCachedModels).toEqual(res)
  })

  it('fetchPollinationsModels failure with existing cache keeps cache', async () => {
    const store = useArtistryStore()
    store.pollinationsCachedModels = [{ id: 'c', name: 'C' }]
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('net')))
    const res = await store.fetchPollinationsModels(true)
    expect(res).toEqual([{ id: 'c', name: 'C' }])
  })

  it('resolveArtistryConfigFromStore unwraps refs and raw', () => {
    const store = useArtistryStore()
    store.activeProvider = 'replicate'
    store.activeModel = 'm'
    store.defaultPromptPrefix = 'pref'
    store.providerOptions = { a: 1 }
    const cfg = resolveArtistryConfigFromStore(store)
    expect(cfg.provider).toBe('replicate')
    expect(cfg.model).toBe('m')
    expect(cfg.promptPrefix).toBe('pref')
    expect(cfg.options).toEqual({ a: 1 })
    expect(cfg.Globals).toBeTruthy()
  })

  it('resolveArtistryConfigFromStore handles non-ref-like object', () => {
    const fake = {
      activeProvider: 'x',
      activeModel: 'y',
      defaultPromptPrefix: 'z',
      providerOptions: { b: 2 },
      artistryGlobals: { g: 1 },
    }
    const cfg = resolveArtistryConfigFromStore(fake as unknown as Parameters<typeof resolveArtistryConfigFromStore>[0])
    expect(cfg.provider).toBe('x')
    expect(cfg.Globals).toEqual({ g: 1 })
  })
})
