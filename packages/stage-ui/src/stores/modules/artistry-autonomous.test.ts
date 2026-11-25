import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import { useAutonomousArtistryStore } from './artistry-autonomous'

vi.mock('vue-i18n', () => ({
  useI18n: () => ({ t: (k: string) => k }),
}))

describe('artistry-autonomous store', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    if (typeof localStorage !== 'undefined')
      localStorage.clear()
    vi.restoreAllMocks()
  })

  it('initializes', () => {
    const store = useAutonomousArtistryStore()
    expect(store).toBeTruthy()
  })

  it('runArtistTask never starts while image generation is deprecated', async () => {
    const store = useAutonomousArtistryStore()
    // Should resolve immediately without flipping isProcessing or throwing.
    await expect(store.runArtistTask('a scene', [])).resolves.toBeUndefined()
    expect(store.isProcessing).toBe(false)
  })
})
