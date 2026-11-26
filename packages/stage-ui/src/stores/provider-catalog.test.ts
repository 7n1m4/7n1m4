import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { providersRepo } from '../database/repos/providers.repo'
import { providerOpenAICompatible } from '../libs/providers/providers/openai-compatible'
import { useProviderCatalogStore } from './provider-catalog'

vi.mock('../database/repos/providers.repo', () => ({
  providersRepo: {
    getAll: vi.fn(async () => ({})),
    saveAll: vi.fn(async () => {}),
    upsert: vi.fn(async () => {}),
    remove: vi.fn(async () => {}),
  },
}))

const mockHasDaemon = vi.fn()
const mockListDaemonProviders = vi.fn()
const mockSaveDaemonProvider = vi.fn()
const mockDeleteDaemonProvider = vi.fn()

vi.mock('../composables/daemon-card-metadata', () => ({
  hasDaemonCardMetadata: () => mockHasDaemon(),
  listDaemonProviders: (...args: unknown[]) => mockListDaemonProviders(...args),
  saveDaemonProvider: (...args: unknown[]) => mockSaveDaemonProvider(...args),
  deleteDaemonProvider: (...args: unknown[]) => mockDeleteDaemonProvider(...args),
}))

describe('store provider-catalog (local-first + daemon RPC)', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    vi.mocked(providersRepo.getAll).mockResolvedValue({})
    vi.mocked(providersRepo.saveAll).mockResolvedValue(undefined)
    vi.mocked(providersRepo.upsert).mockResolvedValue(undefined)
    vi.mocked(providersRepo.remove).mockResolvedValue(undefined)
    mockHasDaemon.mockReturnValue(false)
    mockListDaemonProviders.mockResolvedValue([])
    mockSaveDaemonProvider.mockResolvedValue({ id: 'id' })
    mockDeleteDaemonProvider.mockResolvedValue({ deleted: true })
  })

  it('add persists locally without a daemon', async () => {
    const store = useProviderCatalogStore()
    await store.addProvider(providerOpenAICompatible.id)
    const providers = Object.values(store.configs)
    expect(providers).toHaveLength(1)
    expect(providers[0].definitionId).toBe(providerOpenAICompatible.id)
    expect(mockSaveDaemonProvider).not.toHaveBeenCalled()
  })

  it('add mirrors to the daemon when available', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id, { model: 'gpt-test', baseUrl: 'http://local' })
    expect(mockSaveDaemonProvider).toHaveBeenCalledWith({
      id: provider.id,
      kind: 'open-ai-compatible',
      definitionId: providerOpenAICompatible.id,
      enabled: true,
      model: 'gpt-test',
      baseUrl: 'http://local',
    })
  })

  it('remove deletes locally and through the daemon', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    await store.removeProvider(provider.id)
    expect(Object.values(store.configs)).toHaveLength(0)
    expect(mockDeleteDaemonProvider).toHaveBeenCalledWith(provider.id)
  })

  it('commitProviderConfig persists the full local config and mirrors model fields', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    await store.commitProviderConfig(provider.id, {
      model: 'gpt-test',
      baseUrl: 'http://local',
      apiKey: 'sk-test',
    }, { validated: true, validationBypassed: false })
    expect(store.configs[provider.id].config.apiKey).toBe('sk-test')
    expect(mockSaveDaemonProvider).toHaveBeenLastCalledWith({
      id: provider.id,
      kind: 'open-ai-compatible',
      definitionId: providerOpenAICompatible.id,
      enabled: true,
      model: 'gpt-test',
      baseUrl: 'http://local',
      apiKey: 'sk-test',
      rotateSecrets: true,
    })
  })

  it('fetchList keeps local configs and merges daemon metadata', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    vi.mocked(providersRepo.getAll).mockResolvedValueOnce({ [provider.id]: provider })
    mockListDaemonProviders.mockResolvedValueOnce({
      providers: [{ id: provider.id, model: 'daemon-model', baseUrl: '', enabled: true, updatedAt: 1 }],
    })
    await store.fetchList()
    expect(store.configs[provider.id].config.model).toBe('daemon-model')
    expect(store.configs[provider.id].definitionId).toBe(providerOpenAICompatible.id)
  })

  it('commitProviderConfig preserves the enabled flag and definition id', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    await store.commitProviderConfig(provider.id, { model: 'gpt-test' }, { validated: true, validationBypassed: false })
    expect(mockSaveDaemonProvider).toHaveBeenLastCalledWith({
      id: provider.id,
      kind: 'open-ai-compatible',
      enabled: true,
      definitionId: providerOpenAICompatible.id,
      model: 'gpt-test',
      baseUrl: '',
    })
  })

  it('maps local-only definition IDs to daemon IDs before mirroring', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider('minimax-global')
    expect(mockSaveDaemonProvider).toHaveBeenCalledWith(expect.objectContaining({
      definitionId: 'minimax',
    }))
    expect(provider.definitionId).toBe('minimax-global')
    await store.commitProviderConfig(provider.id, { model: 'mini' }, { validated: false, validationBypassed: false })
    expect(mockSaveDaemonProvider).toHaveBeenLastCalledWith(expect.objectContaining({
      definitionId: 'minimax',
    }))
  })

  it('retains the daemon kind and enabled flag when reconciling daemon-only rows', async () => {
    mockHasDaemon.mockReturnValue(true)
    mockListDaemonProviders.mockResolvedValueOnce({
      providers: [{ id: 'daemon-row', kind: 'anthropic', model: 'claude', baseUrl: '', enabled: false, updatedAt: 1 }],
    })
    const store = useProviderCatalogStore()
    await store.fetchList()
    expect(store.configs['daemon-row']).toMatchObject({ definitionId: '', enabled: false })
    await store.commitProviderConfig('daemon-row', { model: 'claude' }, { validated: false, validationBypassed: false })
    expect(mockSaveDaemonProvider).toHaveBeenLastCalledWith({
      id: 'daemon-row',
      kind: 'anthropic',
      enabled: false,
      model: 'claude',
      baseUrl: '',
    })
  })

  it('fetchList keeps the daemon enabled flag for existing local configs', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    vi.mocked(providersRepo.getAll).mockResolvedValueOnce({ [provider.id]: provider })
    mockListDaemonProviders.mockResolvedValueOnce({
      providers: [{ id: provider.id, kind: 'open-ai-compatible', model: '', baseUrl: '', enabled: false, updatedAt: 1 }],
    })
    await store.fetchList()
    expect(store.configs[provider.id].enabled).toBe(false)
    await store.commitProviderConfig(provider.id, { model: 'gpt-test' }, { validated: false, validationBypassed: false })
    expect(mockSaveDaemonProvider).toHaveBeenLastCalledWith({
      id: provider.id,
      kind: 'open-ai-compatible',
      definitionId: providerOpenAICompatible.id,
      enabled: false,
      model: 'gpt-test',
      baseUrl: '',
    })
  })

  it('fetchList falls back to local configs when the daemon list fails', async () => {
    mockHasDaemon.mockReturnValue(true)
    const store = useProviderCatalogStore()
    const provider = await store.addProvider(providerOpenAICompatible.id)
    vi.mocked(providersRepo.getAll).mockResolvedValueOnce({ [provider.id]: provider })
    mockListDaemonProviders.mockRejectedValueOnce(new Error('daemon unreachable'))
    await store.fetchList()
    expect(store.configs[provider.id].definitionId).toBe(providerOpenAICompatible.id)
  })

  it('omits enabled on commit when a cached row has no daemon flag', async () => {
    mockHasDaemon.mockReturnValue(true)
    const cached = {
      id: 'stale-row',
      definitionId: providerOpenAICompatible.id,
      name: 'cached',
      config: {},
      validated: false,
      validationBypassed: false,
    }
    mockListDaemonProviders.mockResolvedValueOnce({ providers: [] })
    vi.mocked(providersRepo.getAll).mockResolvedValueOnce({ 'stale-row': cached })
    const store = useProviderCatalogStore()
    await store.fetchList()
    await store.commitProviderConfig('stale-row', { model: 'gpt-test' }, { validated: false, validationBypassed: false })
    expect(mockSaveDaemonProvider).toHaveBeenCalledWith({
      id: 'stale-row',
      kind: 'open-ai-compatible',
      definitionId: providerOpenAICompatible.id,
      model: 'gpt-test',
      baseUrl: '',
    })
  })
})
