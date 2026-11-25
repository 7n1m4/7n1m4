import { createPinia, setActivePinia } from 'pinia'
import { beforeEach, describe, expect, it, vi } from 'vitest'

import {
  executeImageJournalAction,
  imageJournalParams,
} from './image-journal'

const mockGenerateHeadless = vi.fn()
const mockAddWidget = vi.fn()
const mockAddBackground = vi.fn().mockResolvedValue('bg-test-123')
const mockSetActiveBackground = vi.fn()

vi.mock('../../../../shared/eventa', () => ({
  artistryGenerateHeadless: 'artistry:generate:headless',
  widgetsAdd: 'widgets:add',
}))

vi.mock('@moeru/eventa', () => ({
  defineInvoke: (_ctx: any, event: string) => {
    if (event === 'artistry:generate:headless')
      return (...args: any[]) => mockGenerateHeadless(...args)
    if (event === 'widgets:add')
      return (...args: any[]) => mockAddWidget(...args)
    return vi.fn()
  },
}))

// The tool now resolves the shared Electrobun view context instead of building an
// Electron-adapter context over `window.electron`. `defineInvoke` is mocked above, so a
// truthy placeholder is all the context accessor needs to return.
vi.mock('@proj-anima/electron-vueuse', () => ({
  getElectronEventaContext: () => ({}),
}))

const mockGetSessionMessages = vi.fn().mockReturnValue([])

vi.mock('@proj-anima/stage-ui/stores', () => ({
  resolveArtistryConfigFromStore: vi.fn().mockReturnValue({
    provider: 'pollinations',
    model: '',
    promptPrefix: '',
  }),
  stageArtistryIntrusion: vi.fn(),
  useAiriCardStore: () => ({
    activeCard: {
      extensions: {
        airi: {
          artistry: {
            provider: 'pollinations',
            model: '',
            spawnMode: 'inline',
          },
        },
      },
    },
    activeCardId: 'card-test-1',
    cards: new Map(),
    updateCard: vi.fn(),
  }),
  useArtistryStore: () => ({
    activeProvider: 'pollinations',
    configured: true,
  }),
  useBackgroundStore: () => ({
    entries: new Map([
      ['bg-1', { id: 'bg-1', title: 'Sunset at Beach', type: 'journal', characterId: 'card-test-1' }],
    ]),
    addBackground: mockAddBackground,
    setActiveBackground: mockSetActiveBackground,
  }),
  useChatSessionStore: () => ({
    activeSessionId: 'session-test-1',
    getSessionMessages: mockGetSessionMessages,
  }),
}))

describe('image_journal tool parameter normalization and execution', () => {
  beforeEach(() => {
    setActivePinia(createPinia())
    vi.clearAllMocks()
    mockGetSessionMessages.mockReturnValue([])
    mockGenerateHeadless.mockResolvedValue({
      base64: 'fake-base64-data',
    })
    globalThis.fetch = vi.fn().mockResolvedValue({
      blob: () => Promise.resolve(new Blob(['fake-image'], { type: 'image/png' })),
    }) as any
  })

  describe('schema validation', () => {
    it('parses valid create params', () => {
      const parsed = imageJournalParams.safeParse({ action: 'create', prompt: 'a cute anime girl' })
      expect(parsed.success).toBe(true)
    })

    it('allows aliases in schema', () => {
      const parsed = imageJournalParams.safeParse({
        action: 'create',
        description: 'a sunset over the city',
        title: 'City Sunset',
      })
      expect(parsed.success).toBe(true)
    })
  })

  describe('executeImageJournalAction parameter aliasing and recovery', () => {
    it('blocks create with a deprecation error and makes no generation call', async () => {
      const result = await executeImageJournalAction({
        prompt: 'a cyberpunk skyline',
      })

      expect(mockGenerateHeadless).not.toHaveBeenCalled()
      expect(result).toContain('Error:')
      expect(result).toContain('deprecated')
    })

    it('blocks create recovered from description alias without generating', async () => {
      const result = await executeImageJournalAction({
        action: 'create',
        description: 'a fluffy white cat',
      })

      expect(mockGenerateHeadless).not.toHaveBeenCalled()
      expect(result).toContain('deprecated')
    })

    it('blocks create recovered from query alias without generating', async () => {
      const result = await executeImageJournalAction({
        action: 'create',
        query: 'an autumn park in rain',
      })

      expect(mockGenerateHeadless).not.toHaveBeenCalled()
      expect(result).toContain('deprecated')
    })

    it('blocks create recovered from text alias without generating', async () => {
      const result = await executeImageJournalAction({
        action: 'create',
        text: 'a futuristic robot barista',
      })

      expect(mockGenerateHeadless).not.toHaveBeenCalled()
      expect(result).toContain('deprecated')
    })

    it('blocks create even when falling back to the last user message', async () => {
      mockGetSessionMessages.mockReturnValue([
        { role: 'user', content: 'draw me a cozy fireplace with snow outside' },
      ])

      const result = await executeImageJournalAction({ action: 'create' })

      expect(mockGenerateHeadless).not.toHaveBeenCalled()
      expect(result).toContain('deprecated')
    })

    it('handles apply action with search query or prompt alias', async () => {
      const result = await executeImageJournalAction({
        action: 'apply',
        query: 'Sunset',
      })

      expect(result).toContain('Background set to "Sunset at Beach"')
      expect(mockSetActiveBackground).toHaveBeenCalledWith('bg-1')
    })
  })
})
