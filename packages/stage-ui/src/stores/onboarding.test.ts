import type * as DaemonRpcModule from '../composables/daemon-rpc'

import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { nextTick } from 'vue'

import { useOnboardingV3Draft } from '../components/scenarios/dialogs/onboarding/v3/stores/useOnboardingV3Draft'
import { useOnboardingStore } from './onboarding'

vi.mock('vue-i18n', () => ({
  useI18n: () => ({
    t: (key: string) => key,
  }),
}))

type Section = Record<string, unknown>

const h = vi.hoisted(() => ({
  hasDaemon: true,
  requests: [] as Array<{ action: string, payload: Record<string, unknown> }>,
  stored: {} as Section,
}))

vi.mock('../composables/daemon-rpc', async () => {
  const actual = await vi.importActual<typeof DaemonRpcModule>('../composables/daemon-rpc')

  // Stand in for the daemon's recursive PATCH: a one-field write must not
  // clobber the draft or the other flag stored alongside it.
  const merge = (base: Section, patch: Section) => {
    for (const [key, value] of Object.entries(patch)) {
      if (value === null || value === undefined) {
        delete base[key]
      }
      else if (value && typeof value === 'object' && !Array.isArray(value) && base[key] && typeof base[key] === 'object') {
        merge(base[key] as Section, value as Section)
      }
      else {
        base[key] = value
      }
    }
  }

  return {
    ...actual,
    hasDaemon: () => h.hasDaemon,
    daemonRequest: async (action: string, payload: Record<string, unknown> = {}) => {
      h.requests.push({ action, payload })
      // Unrelated module-level warm-up (secret policy) must not spam stderr.
      if (action === 'vault.secret_key_policy') {
        return {
          substrings: ['key'],
          suffixes: ['_key'],
          storage_substrings: ['key'],
          storage_prefixes: ['secret_'],
        }
      }
      if (action === 'settings.get')
        return { section: String(payload.section), settings: JSON.stringify(h.stored) }
      if (action === 'settings.set') {
        merge(h.stored, payload.settings as Section)
        return { ok: true }
      }
      throw new Error(`unexpected action: ${action}`)
    },
  }
})

async function flush() {
  for (let i = 0; i < 6; i++) {
    await Promise.resolve()
    await nextTick()
  }
}

describe('useOnboardingStore', () => {
  beforeEach(() => {
    localStorage.clear()
    setActivePinia(createPinia())
    h.requests = []
    h.hasDaemon = true
    h.stored = {
      'onboarding/v3-draft': {
        experienceArchetype: 'casual',
        userName: 'Richy',
        modules: { hearing: true },
      },
      'onboarding/v3-completed': false,
      'onboarding/v3-skipped': false,
    }
  })

  it('initializes with needsOnboarding = true when neither completed nor skipped', async () => {
    const store = useOnboardingStore()
    await flush()

    expect(store.hasCompletedSetup).toBe(false)
    expect(store.hasSkippedSetup).toBe(false)
    expect(store.needsOnboarding).toBe(true)
  })

  it('hydrates the wizard draft without dropping locally entered credentials', async () => {
    localStorage.setItem('onboarding/v3-draft', JSON.stringify({
      architecture: 'local',
      experienceArchetype: 'quiet',
      userName: 'Local',
      llmApiKey: 'local-llm-secret',
      artistryApiKey: 'local-artistry-secret',
      modules: { hearing: true, speech: true },
    }))
    h.stored = {
      'onboarding/v3-draft': {
        architecture: 'cloud',
        experienceArchetype: 'muse',
        userName: 'Hydra',
        modules: { hearing: true },
      },
      'onboarding/v3-completed': false,
      'onboarding/v3-skipped': false,
    }

    const store = useOnboardingV3Draft()
    await flush()

    // The daemon projection omits scrubbed keys; local credentials survive.
    expect(store.state.llmApiKey).toBe('local-llm-secret')
    expect(store.state.artistryApiKey).toBe('local-artistry-secret')
    expect(store.state.experienceArchetype).toBe('muse')
    expect(store.state.userName).toBe('Hydra')
  })

  it('marks setup skipped with a one-field PATCH that preserves sibling draft fields', async () => {
    const store = useOnboardingStore()
    await flush()
    h.requests.length = 0

    store.markSetupSkipped()
    await flush()

    expect(store.hasSkippedSetup).toBe(true)
    expect(store.hasCompletedSetup).toBe(false)
    expect(store.needsOnboarding).toBe(false)
    expect(h.requests).toEqual([{
      action: 'settings.set',
      payload: { section: 'onboarding', settings: { 'onboarding/v3-skipped': true } },
    }])
    // The daemon-side recursive merge keeps the draft and the other flag.
    expect(h.stored['onboarding/v3-skipped']).toBe(true)
    expect(h.stored['onboarding/v3-completed']).toBe(false)
    expect(h.stored['onboarding/v3-draft']).toEqual({
      experienceArchetype: 'casual',
      userName: 'Richy',
      modules: { hearing: true },
    })
  })

  it('hydrates both flags from settings.get(\'onboarding\')', async () => {
    h.stored['onboarding/v3-completed'] = true
    h.stored['onboarding/v3-skipped'] = true
    const store = useOnboardingStore()

    await flush()

    expect(store.hasCompletedSetup).toBe(true)
    expect(store.hasSkippedSetup).toBe(true)
    expect(store.needsOnboarding).toBe(false)
    expect(h.requests.filter(r => r.action === 'settings.get')).toHaveLength(2)
  })

  it('marks setup completed and clears skipped state', async () => {
    const store = useOnboardingStore()
    await flush()

    store.markSetupSkipped()
    await flush()
    expect(store.hasSkippedSetup).toBe(true)

    store.markSetupCompleted()
    await flush()
    expect(store.hasCompletedSetup).toBe(true)
    expect(store.hasSkippedSetup).toBe(false)
    expect(store.needsOnboarding).toBe(false)

    const sets = h.requests.filter(r => r.action === 'settings.set')
    expect(sets).toContainEqual({
      action: 'settings.set',
      payload: { section: 'onboarding', settings: { 'onboarding/v3-completed': true } },
    })
    expect(sets).toContainEqual({
      action: 'settings.set',
      payload: { section: 'onboarding', settings: { 'onboarding/v3-skipped': false } },
    })
  })

  it('ignores legacy V1/V2 flags: prior completed/skipped still needs V3 onboarding', async () => {
    localStorage.setItem('onboarding/completed', 'true')
    localStorage.setItem('onboarding/skipped', 'true')
    const store = useOnboardingStore()
    await flush()

    expect(store.needsOnboarding).toBe(true)
  })

  it('resets setup state when explicitly requested', async () => {
    const store = useOnboardingStore()
    await flush()

    store.markSetupSkipped()
    await flush()
    expect(store.needsOnboarding).toBe(false)

    store.resetSetupState()
    await flush()
    expect(store.hasCompletedSetup).toBe(false)
    expect(store.hasSkippedSetup).toBe(false)
    expect(store.needsOnboarding).toBe(true)
    expect(h.stored['onboarding/v3-skipped']).toBe(false)
  })

  it('keeps the localStorage path and makes no RPC when no daemon is present', async () => {
    h.hasDaemon = false
    const store = useOnboardingStore()
    await flush()

    store.markSetupSkipped()
    await flush()

    expect(store.hasSkippedSetup).toBe(true)
    expect(localStorage.getItem('onboarding/v3-skipped')).toBe('true')
    expect(h.requests).toEqual([])
  })
})
