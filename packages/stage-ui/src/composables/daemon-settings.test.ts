/**
 * The daemon settings client.
 *
 * The seam under test is the settings section boundary: `fetchDaemonSettings`
 * and `saveDaemonSettings` put the right frames on the wire, and
 * `bridgeDaemonSettings` makes the daemon the authority for a section while the
 * localStorage-backed state stays the cache. Only the transport is mocked —
 * the bridge's hydration, write-back and loop suppression all run for real.
 */
import type * as DaemonRpcModule from './daemon-rpc'
import type * as DaemonSettingsModule from './daemon-settings'

import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick, ref } from 'vue'

const h = vi.hoisted(() => ({
  requests: [] as Array<{ action: string, payload: Record<string, unknown> }>,
  fetch: vi.fn(async (_section: string) => ({} as Record<string, unknown>)),
  save: vi.fn(async (_section: string, _value: unknown) => {}),
}))

vi.mock('./daemon-rpc', async () => {
  const actual = await vi.importActual<typeof DaemonRpcModule>('./daemon-rpc')
  return {
    ...actual,
    hasDaemon: () => true,
    daemonRequest: async (action: string, payload: Record<string, unknown> = {}) => {
      h.requests.push({ action, payload })
      if (action === 'settings.get')
        return { section: String(payload.section), settings: JSON.stringify(await h.fetch(String(payload.section))) } as never
      await h.save(String(payload.section), payload.settings)
      return { ok: true } as never
    },
  }
})

/**
 * Resolve the settings module against a module registry reset per test, so the
 * transport mock is re-applied to a fresh module graph.
 */
async function freshSettings(): Promise<typeof DaemonSettingsModule> {
  vi.resetModules()
  return import('./daemon-settings')
}

let mod: typeof DaemonSettingsModule

beforeEach(() => {
  h.requests = []
  h.fetch.mockReset()
  h.fetch.mockResolvedValue({})
  h.save.mockReset()
  h.save.mockResolvedValue(undefined)
  localStorage.clear()
  vi.stubEnv('RUNTIME_ENVIRONMENT', 'electron')
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('fetchDaemonSettings', () => {
  it('asks settings.get for the section and decodes the JSON string the daemon carries', async () => {
    mod = await freshSettings()
    h.fetch.mockResolvedValue({ enabled: false, fontSize: 150 })

    await expect(mod.fetchDaemonSettings<{ enabled: boolean, fontSize: number }>('captions')).resolves.toEqual({ enabled: false, fontSize: 150 })
    expect(h.requests).toEqual([{ action: 'settings.get', payload: { section: 'captions' } }])
  })

  it('propagates a daemon failure so the caller can fall back to its cache', async () => {
    mod = await freshSettings()
    h.fetch.mockRejectedValue(new Error('unknown settings section: captions'))

    await expect(mod.fetchDaemonSettings('captions')).rejects.toThrow('unknown settings section: captions')
  })
})

describe('saveDaemonSettings', () => {
  it('writes the value under settings.set for the section', async () => {
    mod = await freshSettings()

    await mod.saveDaemonSettings('theme', { hue: 12.5, hueDynamic: false })

    expect(h.requests).toEqual([{
      action: 'settings.set',
      payload: { section: 'theme', settings: { hue: 12.5, hueDynamic: false } },
    }])
  })
})

describe('bridgeDaemonSettings', () => {
  it('hydrates the local state from the daemon and never writes the hydrated value back', async () => {
    mod = await freshSettings()
    h.fetch.mockResolvedValue({ name: 'daemon-name' })
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    })

    await nextTick()
    await Promise.resolve()
    await nextTick()

    expect(state.value).toEqual({ name: 'daemon-name' })
    expect(h.requests).toEqual([{ action: 'settings.get', payload: { section: 'user-profile' } }])
    bridge.stop()
  })

  it('saves a local change back to the daemon', async () => {
    mod = await freshSettings()
    h.fetch.mockResolvedValue({ name: 'daemon-name' })
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    })

    await nextTick()
    await Promise.resolve()
    await nextTick()
    await nextTick()
    // Drop the hydration read; only the write-back below is under test.
    h.requests.length = 0

    state.value = { name: 'local-edit' }
    await nextTick()
    await nextTick()

    expect(h.requests).toEqual([{
      action: 'settings.set',
      payload: { section: 'user-profile', settings: { name: 'local-edit' } },
    }])
    bridge.stop()
  })

  it('keeps the local cache when the daemon has nothing to say', async () => {
    mod = await freshSettings()
    h.fetch.mockRejectedValue(new Error('daemon unreachable'))
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    })

    await nextTick()
    await Promise.resolve()

    expect(state.value).toEqual({ name: 'cached-name' })
    bridge.stop()
  })

  it('stops writing after the bridge is stopped', async () => {
    mod = await freshSettings()
    h.fetch.mockResolvedValue({ name: 'daemon-name' })
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    })

    await nextTick()
    await Promise.resolve()
    await nextTick()
    bridge.stop()
    h.save.mockClear()

    state.value = { name: 'after-stop' }
    await nextTick()
    await nextTick()

    expect(h.save).not.toHaveBeenCalled()
  })

  it('skips the daemon entirely when the bridge is disabled', async () => {
    mod = await freshSettings()
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    }, { enabled: false })

    await nextTick()

    expect(h.requests).toEqual([])
    expect(state.value).toEqual({ name: 'cached-name' })
    bridge.stop()
  })

  // ROOT CAUSE:
  //
  // `enabled: false` suppressed hydration but not the watcher: a later local
  // edit still hit settings.set and overwrote the daemon. An explicitly
  // disabled bridge must never write to the daemon, nor hydrate from it.
  it('never writes to the daemon when the bridge is disabled', async () => {
    mod = await freshSettings()
    const state = ref({ name: 'cached-name' })

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
    }, { enabled: false })

    state.value = { name: 'local-only-edit' }
    await nextTick()
    await nextTick()

    expect(h.requests).toEqual([])
    expect(h.save).not.toHaveBeenCalled()
    bridge.stop()
  })

  // ROOT CAUSE:
  //
  // The hydration guard initially stayed up until a full tick after
  // `write(value)`, swallowing any local edit made while settings.get was in
  // flight; the stale daemon value then replaced it in local state. Hydration
  // must skip state edited during the fetch, and the queued write-back for
  // that edit must still reach the daemon.
  it('preserves a local edit made while settings.get is in flight', async () => {
    mod = await freshSettings()
    let finishFetch!: (value: Record<string, unknown>) => void
    h.fetch.mockImplementation(() => new Promise((resolve) => {
      finishFetch = resolve
    }))
    const state = ref({ name: 'cached-name' })
    const writes: string[] = []

    const bridge = mod.bridgeDaemonSettings('user-profile', () => state.value, (value) => {
      state.value = value
      writes.push(`hydrate:${value.name}`)
    })

    await nextTick()
    // The user edits while the daemon fetch is still pending.
    state.value = { name: 'local-edit' }
    await nextTick()
    await nextTick()

    finishFetch({ name: 'daemon-name' })
    await nextTick()
    await Promise.resolve()
    await nextTick()
    await nextTick()

    expect(state.value).toEqual({ name: 'local-edit' })
    expect(writes).toEqual([])
    expect(h.requests).toEqual([
      { action: 'settings.get', payload: { section: 'user-profile' } },
      { action: 'settings.set', payload: { section: 'user-profile', settings: { name: 'local-edit' } } },
    ])
    bridge.stop()
  })
})
