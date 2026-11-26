import type * as DaemonRpcModule from '../../composables/daemon-rpc'

/**
 * The stage-model bridge owns the whole `stage-model` settings blob. A
 * selection write must carry the catalog hydrated from the daemon: dropping it
 * makes `display-model.resolve` unable to find previously registered ids.
 */
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import { useDisplayModelsStore } from '../display-models'
import { useSettingsStageModel } from './stage-model'

const h = vi.hoisted(() => ({
  requests: [] as Array<{ action: string, payload: Record<string, unknown> }>,
  fetch: vi.fn(async (_section: string) => ({} as Record<string, unknown>)),
  save: vi.fn(async (_section: string, _value: unknown) => {}),
}))

vi.mock('../../composables/daemon-rpc', async () => {
  const actual = await vi.importActual<typeof DaemonRpcModule>('../../composables/daemon-rpc')
  return {
    ...actual,
    hasDaemon: () => true,
    daemonRequest: async (action: string, payload: Record<string, unknown> = {}) => {
      h.requests.push({ action, payload })
      if (action === 'settings.get') {
        return {
          section: String(payload.section),
          settings: JSON.stringify(await h.fetch(String(payload.section))),
        } as never
      }
      await h.save(String(payload.section), payload.settings)
      return { ok: true } as never
    },
  }
})

async function settle() {
  await nextTick()
  await Promise.resolve()
  await nextTick()
}

function lastWritten(section: string): Record<string, unknown> | undefined {
  const call = [...h.requests].reverse().find(r => r.action === 'settings.set' && r.payload.section === section)
  return call?.payload.settings as Record<string, unknown> | undefined
}

beforeEach(() => {
  localStorage.clear()
  setActivePinia(createPinia())
  h.requests.length = 0
  h.fetch.mockReset()
  h.fetch.mockResolvedValue({})
  h.save.mockReset()
  h.save.mockResolvedValue(undefined)
  vi.stubEnv('RUNTIME_ENVIRONMENT', 'electron')
})

afterEach(() => {
  vi.restoreAllMocks()
  vi.unstubAllEnvs()
})

// ROOT CAUSE:
//
// The bridge `read()` returned `{ modelId, catalog: [] }`, replacing the whole
// `stage-model` blob on every selection. `display-model.resolve` reads ids from
// that catalog, so previously registered descriptors became unresolvable.
//
// FIXED BY: retaining the hydrated catalog and writing it back with the new id.
describe('settings/stage-model daemon bridge', () => {
  // Selection changes reload the model from IndexedDB; only the catalog
  // write-back is under test here. Instantiate the store lazily in each test
  // so no watcher runs before the bridge captures its baseline.
  function stubModelLookup() {
    vi.spyOn(useDisplayModelsStore(), 'getDisplayModel').mockResolvedValue(undefined)
  }

  it('preserves the hydrated daemon catalog on selection write-back', async () => {
    stubModelLookup()
    const descriptor = { id: 'imported-vrm-1', name: 'Imported VRM', format: 'vrm' }
    h.fetch.mockResolvedValue({ modelId: 'none', catalog: [descriptor] })

    const store = useSettingsStageModel()
    await settle()

    expect(h.requests[0]).toEqual({ action: 'settings.get', payload: { section: 'stage-model' } })
    expect(h.save).not.toHaveBeenCalled()

    store.stageModelSelected = descriptor.id
    await settle()

    expect(lastWritten('stage-model')).toEqual({ modelId: descriptor.id, catalog: [descriptor] })
  })

  it('keeps every hydrated descriptor, not just the selected one', async () => {
    stubModelLookup()
    const catalog = [
      { id: 'model-a', name: 'A', format: 'vrm' },
      { id: 'model-b', name: 'B', format: 'live2d-zip' },
    ]
    h.fetch.mockResolvedValue({ modelId: 'model-a', catalog })

    const store = useSettingsStageModel()
    await settle()

    store.stageModelSelected = 'model-b'
    await settle()

    expect(lastWritten('stage-model')).toEqual({ modelId: 'model-b', catalog })
    expect(h.fetch).toHaveBeenCalledTimes(1)
  })

  it('includes the catalog in every subsequent selection write', async () => {
    stubModelLookup()
    const catalog = [{ id: 'model-a', name: 'A', format: 'vrm' }]
    h.fetch.mockResolvedValue({ modelId: 'model-a', catalog })

    const store = useSettingsStageModel()
    await settle()

    for (const id of ['unlisted-model', 'model-a', 'another-model']) {
      store.stageModelSelected = id
      await settle()
    }

    const writes = h.requests.filter(r => r.action === 'settings.set' && r.payload.section === 'stage-model')
    expect(writes).toHaveLength(3)
    for (const write of writes) {
      expect(write.payload.settings).toEqual({ modelId: expect.any(String), catalog })
    }
    const selectedIds = writes.map((write) => {
      const settings = write.payload.settings
      return settings && typeof settings === 'object' && 'modelId' in settings ? settings.modelId : undefined
    })
    expect(selectedIds).toEqual([
      'unlisted-model',
      'model-a',
      'another-model',
    ])
  })

  it('does not leak unrelated stage settings into the daemon blob', async () => {
    stubModelLookup()
    h.fetch.mockResolvedValue({ modelId: 'none', catalog: [{ id: 'model-a' }] })

    const store = useSettingsStageModel()
    await settle()

    store.cycleGunslingerStance()
    store.stageViewControlsEnabled = false
    store.stageModelSelected = 'model-a'
    await settle()

    expect(Object.keys(lastWritten('stage-model') ?? {}).sort()).toEqual(['catalog', 'modelId'])
    expect(store.gunslingerStance).toBe('cat')
    expect(store.stageViewControlsEnabled).toBe(false)
  })

  it('falls back to an empty catalog when the daemon section has none', async () => {
    stubModelLookup()
    h.fetch.mockResolvedValue({ modelId: 'none' })

    const store = useSettingsStageModel()
    await settle()

    store.stageModelSelected = 'preset-live2d-1'
    await settle()

    expect(lastWritten('stage-model')).toEqual({ modelId: 'preset-live2d-1', catalog: [] })
  })
})
