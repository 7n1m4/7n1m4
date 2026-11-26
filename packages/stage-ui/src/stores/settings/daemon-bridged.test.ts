import type * as DaemonRpcModule from '../../composables/daemon-rpc'

/**
 * Focused bridge tests for the simple settings stores.
 *
 * Each store keeps its localStorage-backed refs as the cache; the daemon owns
 * the section. The RPC transport and `hasDaemon()` are mocked to force the
 * daemon path — hydration, write-back and loop suppression run for real, so a
 * store that maps a field to the wrong daemon key fails here.
 *
 * Stores are imported statically (not through a per-test module registry): the
 * bridge is created by `defineStore`'s setup, so a fresh Pinia per test is what
 * gives each case a fresh bridge.
 */
import { createPinia, setActivePinia } from 'pinia'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import { useSettingsCaptions } from './captions'
import { useSettingsChat } from './chat'
import { useSettingsGeneral } from './general'
import { useSettingsLive2d } from './live2d'
import { useSettingsMmd } from './mmd'
import { usePositioningStore } from './positioning'
import { useSettingsSpine } from './spine'
import { useSettingsTheme } from './theme'
import { useSettingsUserProfile } from './user-profile'

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

/** Let hydration settle: the bridge drains its own watcher a microtask later. */
async function settle() {
  await nextTick()
  await Promise.resolve()
  await nextTick()
}

/** The single `settings.set` payload the bridge wrote, if any. */
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
  // `hasDaemon()` is stubbed above; the env stub keeps the real module honest.
  vi.stubEnv('RUNTIME_ENVIRONMENT', 'electron')
})

afterEach(() => {
  vi.unstubAllEnvs()
})

describe('settings/chat daemon bridge', () => {
  it('hydrates every field from the daemon section', async () => {
    h.fetch.mockResolvedValue({
      sendMode: 'ctrl-enter',
      suggestMode: 'disabled',
      streamIdleTimeoutMs: 1234,
      showDirectorNotes: false,
      combineSystemMessages: true,
    })

    const store = useSettingsChat()
    await settle()

    expect(store.sendMode).toBe('ctrl-enter')
    expect(store.suggestMode).toBe('disabled')
    expect(store.streamIdleTimeoutMs).toBe(1234)
    expect(store.showDirectorNotes).toBe(false)
    expect(store.combineSystemMessages).toBe(true)
    expect(h.requests[0]).toEqual({ action: 'settings.get', payload: { section: 'chat' } })
    expect(h.save).not.toHaveBeenCalled()
  })

  it('writes a local edit back with camelCase daemon keys', async () => {
    const store = useSettingsChat()
    await settle()

    store.sendMode = 'double-enter'
    store.streamIdleTimeoutMs = 900000
    await settle()

    expect(lastWritten('chat')).toEqual(expect.objectContaining({
      sendMode: 'double-enter',
      streamIdleTimeoutMs: 900000,
    }))
  })

  it('keeps the 30s -> 10min migration and the localStorage cache', async () => {
    localStorage.setItem('settings/chat/stream-idle-timeout-ms', '30000')
    h.fetch.mockRejectedValue(new Error('daemon unreachable'))

    const store = useSettingsChat()
    await settle()

    expect(store.streamIdleTimeoutMs).toBe(600000)
    expect(localStorage.getItem('settings/chat/stream-idle-timeout-ms')).toBe('600000')
  })
})

describe('settings/captions daemon bridge', () => {
  it('maps enabled/fontSize/opacity/docking and leaves local-only knobs alone', async () => {
    h.fetch.mockResolvedValue({ enabled: false, fontSize: 150, opacity: 70, docking: 'head' })

    const store = useSettingsCaptions()
    await settle()

    expect(store.showCaptions).toBe(false)
    expect(store.fontSize).toBe(150)
    expect(store.opacity).toBe(70)
    expect(store.docking).toBe('head')
    // Not part of the daemon schema: untouched by hydration.
    expect(store.layoutMode).toBe('single')
    expect(store.headTetheredCaptionEnabled).toBe(false)
  })

  it('writes only the daemon-owned fields back', async () => {
    const store = useSettingsCaptions()
    await settle()
    h.requests.length = 0

    // `layoutMode` and `resetTrigger` are local-only; neither may reach the wire.
    store.layoutMode = 'multi'
    store.triggerReset()
    store.opacity = 55
    await settle()

    const writes = h.requests.filter(r => r.action === 'settings.set')
    expect(writes).toHaveLength(1)
    expect(Object.keys(writes[0].payload.settings as object).sort()).toEqual(['docking', 'enabled', 'fontSize', 'opacity'])
  })
})

describe('settings/theme daemon bridge', () => {
  it('hydrates hue/hueDynamic/chromaMultiplier/dark', async () => {
    h.fetch.mockResolvedValue({ hue: 12.5, hueDynamic: true, chromaMultiplier: 1.5, dark: false })

    const store = useSettingsTheme()
    await settle()

    expect(store.themeColorsHue).toBe(12.5)
    expect(store.themeColorsHueDynamic).toBe(true)
    expect(store.themeColorsChromaMultiplier).toBe(1.5)
    expect(store.themeDark).toBe(false)
  })

  it('writes setThemeColorsHue back as hue + hueDynamic=false', async () => {
    const store = useSettingsTheme()
    await settle()

    store.setThemeColorsHue(300)
    await settle()

    expect(lastWritten('theme')).toEqual(expect.objectContaining({ hue: 300, hueDynamic: false }))
  })
})

describe('settings/general daemon bridge', () => {
  it('hydrates the flat general blob', async () => {
    h.fetch.mockResolvedValue({
      language: 'ja',
      disableTransitions: false,
      usePageSpecificTransitions: false,
      remoteSyncEnabled: true,
      websocketSecureEnabled: true,
      autostart: true,
    })

    const store = useSettingsGeneral()
    await settle()

    expect(store.language).toBe('ja')
    expect(store.disableTransitions).toBe(false)
    expect(store.usePageSpecificTransitions).toBe(false)
    expect(store.websocketSecureEnabled).toBe(true)
    expect(store.remoteSyncEnabled).toBe(true)
    expect(store.autostart).toBe(true)
  })

  it('writes a local edit back under the general section', async () => {
    const store = useSettingsGeneral()
    await settle()

    store.disableTransitions = false
    await settle()

    expect(lastWritten('general')).toEqual(expect.objectContaining({ disableTransitions: false }))
  })
})

describe('model settings daemon bridges', () => {
  it('live2d hydrates and writes its seven daemon fields', async () => {
    h.fetch.mockResolvedValue({
      live2dDisableFocus: true,
      live2dFollowSpeed: 0.9,
      live2dIdleAnimationEnabled: false,
      live2dAutoBlinkEnabled: false,
      live2dForceAutoBlinkEnabled: true,
      live2dShadowEnabled: false,
      live2dMaxFps: 60,
    })

    const store = useSettingsLive2d()
    await settle()

    expect(store.live2dDisableFocus).toBe(true)
    expect(store.live2dFollowSpeed).toBe(0.9)
    expect(store.live2dMaxFps).toBe(60)

    store.live2dMaxFps = 30
    await settle()
    expect(lastWritten('live2d')).toEqual(expect.objectContaining({ live2dMaxFps: 30 }))
  })

  it('spine maps default-mix to mixDuration and keeps mirrored fields', async () => {
    h.fetch.mockResolvedValue({
      maxFps: 24,
      renderScale: 2,
      mixDuration: 0.5,
      animationSpeed: 1.5,
      idleAnimationEnabled: false,
      scalePos: { x: 1, y: 2, scale: 3 },
    })

    const store = useSettingsSpine()
    await settle()

    expect(store.spineMaxFps).toBe(24)
    expect(store.spineRenderScale).toBe(2)
    expect(store.spineDefaultMixDuration).toBe(0.5)
    expect(store.spineAnimationSpeed).toBe(1.5)
    expect(store.spineIdleAnimationEnabled).toBe(false)
    expect(store.spineScalePos).toEqual({ x: 1, y: 2, scale: 3 })
  })

  it('mmd hydrates and writes its two daemon fields', async () => {
    h.fetch.mockResolvedValue({ mmdIdleAnimationEnabled: false, mmdRenderScale: 1.25 })

    const store = useSettingsMmd()
    await settle()

    expect(store.mmdIdleAnimationEnabled).toBe(false)
    expect(store.mmdRenderScale).toBe(1.25)

    store.mmdRenderScale = 0.5
    await settle()
    expect(lastWritten('mmd')).toEqual(expect.objectContaining({ mmdRenderScale: 0.5 }))
  })

  it('user-profile hydrates and writes voiceProfileId', async () => {
    h.fetch.mockResolvedValue({ name: 'daemon', description: 'd', prompt: 'p', voiceProfileId: 'v1' })

    const store = useSettingsUserProfile()
    await settle()

    expect(store.name).toBe('daemon')
    expect(store.voiceProfileId).toBe('v1')

    store.voiceProfileId = 'v2'
    await settle()
    expect(lastWritten('user-profile')).toEqual(expect.objectContaining({ voiceProfileId: 'v2' }))
  })

  it('positioning hydrates the models map and writes edits back', async () => {
    h.fetch.mockResolvedValue({ models: { 'preset-live2d-1': { x: 5, y: 6, scale: 7 } } })

    const store = usePositioningStore()
    await settle()

    expect(store.getPosition('preset-live2d-1')).toEqual({ x: 5, y: 6, scale: 7 })

    store.setPosition('preset-live2d-1', { x: 1, y: 1, scale: 1 })
    await settle()
    expect(lastWritten('positioning')).toEqual({
      models: { 'preset-live2d-1': { x: 1, y: 1, scale: 1 } },
    })
  })
})
