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
    mockListDaemonProviders.mockResolvedValueOnce({ providers: [{ id: provider.id, model: 'daemon-model' }] })
    await store.fetchList()
    expect(store.configs[provider.id].config.model).toBe('daemon-model')
    expect(store.configs[provider.id].definitionId).toBe(providerOpenAICompatible.id)
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
})
