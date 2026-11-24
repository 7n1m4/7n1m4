import type { DaemonCardMetadata } from '../composables/daemon-card-metadata'
import type { Character, CreateCharacterPayload, UpdateCharacterPayload } from '../types/character'

import { nanoid } from 'nanoid'
import { defineStore } from 'pinia'
import { parse } from 'valibot'
import { ref } from 'vue'
import { toast } from 'vue-sonner'

import { client } from '../composables/api'
import { fetchDaemonCardMetadata, hasDaemonCardMetadata, setDaemonCardMetadata } from '../composables/daemon-card-metadata'
import { useLocalFirstRequest } from '../composables/use-local-first'
import { charactersRepo } from '../database/repos/characters.repo'
import { CharacterWithRelationsSchema } from '../types/character'
import { useAuthStore } from './auth'

// Serialization per card for daemon metadata work (hydrate / like / bookmark).
// A promise chain per id guarantees one in-flight daemon request per card.
const daemonMetadataQueues = new Map<string, Promise<void>>()

function enqueueDaemonMetadata(cardId: string, task: () => Promise<void>): Promise<void> {
  const previous = daemonMetadataQueues.get(cardId) ?? Promise.resolve()
  const run = previous.then(async () => {
    try {
      await task()
    }
    finally {
      if (daemonMetadataQueues.get(cardId) === run)
        daemonMetadataQueues.delete(cardId)
    }
  })
  daemonMetadataQueues.set(cardId, run)
  return run
}

function applyDaemonMetadata(character: Character, metadata: DaemonCardMetadata, userId: string) {
  // The daemon owns the local user's flags. The relation arrays are the
  // optimistic mirrors used by the card toggles. Counts are hosted totals:
  // adjust them only when the daemon disagrees with the local flag, never
  // recompute them from the per-user arrays.
  const wasLiked = character.likes?.some(item => item.userId === userId) ?? false
  if (wasLiked !== metadata.liked) {
    character.likesCount = Math.max(0, character.likesCount + (metadata.liked ? 1 : -1))
  }
  character.likes = metadata.liked
    ? [...(character.likes ?? []).filter(item => item.userId !== userId), { userId, characterId: character.id }]
    : (character.likes ?? []).filter(item => item.userId !== userId)

  const wasBookmarked = character.bookmarks?.some(item => item.userId === userId) ?? false
  if (wasBookmarked !== metadata.bookmarked) {
    character.bookmarksCount = Math.max(0, character.bookmarksCount + (metadata.bookmarked ? 1 : -1))
  }
  character.bookmarks = metadata.bookmarked
    ? [...(character.bookmarks ?? []).filter(item => item.userId !== userId), { userId, characterId: character.id }]
    : (character.bookmarks ?? []).filter(item => item.userId !== userId)
}

function buildLocalCharacter(userId: string, payload: CreateCharacterPayload) {
  const id = payload.character.id ?? nanoid()
  const now = new Date()

  return parse(CharacterWithRelationsSchema, {
    id,
    version: payload.character.version,
    coverUrl: payload.character.coverUrl,
    avatarUrl: undefined,
    characterAvatarUrl: undefined,
    coverBackgroundUrl: undefined,
    creatorRole: undefined,
    priceCredit: '0',
    likesCount: 0,
    bookmarksCount: 0,
    interactionsCount: 0,
    forksCount: 0,
    creatorId: userId,
    ownerId: userId,
    characterId: payload.character.characterId,
    createdAt: now,
    updatedAt: now,
    deletedAt: undefined,
    capabilities: payload.capabilities?.map(capability => ({
      id: nanoid(),
      characterId: id,
      type: capability.type,
      config: capability.config,
    })),
    avatarModels: payload.avatarModels?.map(model => ({
      id: nanoid(),
      characterId: id,
      name: model.name,
      type: model.type,
      description: model.description,
      config: model.config,
      createdAt: now,
      updatedAt: now,
    })),
    i18n: payload.i18n?.map(item => ({
      id: nanoid(),
      characterId: id,
      language: item.language,
      name: item.name,
      description: item.description,
      tags: item.tags,
      createdAt: now,
      updatedAt: now,
    })),
    prompts: payload.prompts?.map(prompt => ({
      id: nanoid(),
      characterId: id,
      language: prompt.language,
      type: prompt.type,
      content: prompt.content,
    })),
    likes: [],
    bookmarks: [],
  })
}

export const useCharacterStore = defineStore('characters', () => {
  const characters = ref<Map<string, Character>>(new Map())
  const error = ref<string | null>(null)
  const auth = useAuthStore()

  async function fetchList(all: boolean = false, allowRemote?: () => boolean | Promise<boolean>) {
    const request = useLocalFirstRequest({
      lazy: true,
      allowRemote,
      local: async () => {
        const cached = await charactersRepo.getAll()
        if (cached.length > 0) {
          characters.value.clear()
          for (const char of cached) {
            characters.value.set(char.id, char)
          }
        }
      },
      remote: async () => {
        const res = await client.api.characters.$get({
          query: { all: String(all) },
        })
        if (!res.ok) {
          throw new Error('Failed to fetch characters')
        }
        const data = (await res.json()) as any[]

        characters.value.clear()
        const parsedData: Character[] = []
        for (const char of data) {
          const parsed = parse(CharacterWithRelationsSchema, char)
          characters.value.set(char.id, parsed)
          parsedData.push(parsed)
        }
        await charactersRepo.saveAll(parsedData)
      },
    })
    await request.execute()
    void loadDaemonMetadata(undefined, auth.userId)
    return request
  }

  async function fetchById(id: string) {
    return useLocalFirstRequest({
      local: async () => {
        const cached = characters.value.get(id) ?? (await charactersRepo.getAll()).find(char => char.id === id)
        if (cached) {
          characters.value.set(cached.id, cached)
        }
        return cached
      },
      remote: async () => {
        const res = await client.api.characters[':id'].$get({
          param: { id },
        })
        if (!res.ok) {
          throw new Error('Failed to fetch character')
        }
        const data = await res.json()
        const character = parse(CharacterWithRelationsSchema, data)

        characters.value.set(character.id, character)
        await charactersRepo.upsert(character)
        await loadDaemonMetadata([character.id], auth.userId)
        return character
      },
    })
  }

  async function create(payload: CreateCharacterPayload) {
    let localCharacter: Character
    return useLocalFirstRequest({
      local: async () => {
        localCharacter = buildLocalCharacter(auth.userId, payload)
        characters.value.set(localCharacter.id, localCharacter)
        await charactersRepo.upsert(localCharacter)
        return localCharacter
      },
      remote: async () => {
        const res = await client.api.characters.$post({
          json: payload,
        })
        if (!res.ok) {
          throw new Error('Failed to create character')
        }
        const data = await res.json()
        const character = parse(CharacterWithRelationsSchema, data)

        // Replace local temp character with remote data
        characters.value.delete(localCharacter.id)
        characters.value.set(character.id, character)
        await charactersRepo.remove(localCharacter.id)
        await charactersRepo.upsert(character)
        return character
      },
    })
  }

  async function update(id: string, payload: UpdateCharacterPayload) {
    return useLocalFirstRequest({
      local: async () => {
        const character = characters.value.get(id)
        if (!character) {
          return
        }
        if (payload.version !== undefined)
          character.version = payload.version
        if (payload.coverUrl !== undefined)
          character.coverUrl = payload.coverUrl
        if (payload.characterId !== undefined)
          character.characterId = payload.characterId
        character.updatedAt = new Date()
        characters.value.set(character.id, character)
        await charactersRepo.upsert(character)
        return character
      },
      remote: async () => {
        const res = await (client.api.characters[':id'].$patch)({
          param: { id },
          // @ts-expect-error FIXME: hono client typing misses json option for this route
          json: payload,
        })
        if (!res.ok) {
          throw new Error('Failed to update character')
        }
        const data = await res.json()
        const character = parse(CharacterWithRelationsSchema, data)

        characters.value.set(character.id, character)
        await charactersRepo.upsert(character)
        return character
      },
    })
  }

  async function remove(id: string) {
    return useLocalFirstRequest({
      local: async () => {
        characters.value.delete(id)
        await charactersRepo.remove(id)
      },
      remote: async () => {
        const res = await client.api.characters[':id'].$delete({
          param: { id },
        })
        if (!res.ok) {
          throw new Error('Failed to remove character')
        }
      },
    })
  }

  // Likes/bookmarks are one-local-user state owned by the daemon
  // (`cards.metadata` / `cards.metadata.set` RPCs, backed by the daemon's
  // `card_metadata` SQLite table). The local character row keeps the
  // optimistic counters so the card grid renders immediately; the daemon
  // flags are the durable source of truth and win on failure rollback.
  async function like(id: string) {
    const character = characters.value.get(id)
    if (!character) {
      return
    }
    const wasLiked = character.likes?.some(item => item.userId === auth.userId) ?? false
    const nextLiked = !wasLiked

    // Optimistic local update, reverted below if the daemon write fails.
    const likes = character.likes ?? []
    character.likes = nextLiked
      ? [...likes.filter(item => item.userId !== auth.userId), { userId: auth.userId, characterId: id }]
      : likes.filter(item => item.userId !== auth.userId)
    character.likesCount = Math.max(0, character.likesCount + (nextLiked ? 1 : -1))
    character.updatedAt = new Date()
    characters.value.set(character.id, character)
    await charactersRepo.upsert(character)

    if (!hasDaemonCardMetadata()) {
      return
    }
    await enqueueDaemonMetadata(id, async () => {
      try {
        const bookmarked = character.bookmarks?.some(item => item.userId === auth.userId) ?? false
        const metadata = await setDaemonCardMetadata(id, { liked: nextLiked, bookmarked })
        applyDaemonMetadata(character, metadata, auth.userId)
        await charactersRepo.upsert(character)
      }
      catch (err) {
        // Daemon write failed: restore the pre-toggle optimistic state so the
        // local row matches what the daemon still believes.
        character.likes = likes
        character.likesCount = Math.max(0, character.likesCount + (nextLiked ? -1 : 1))
        character.updatedAt = new Date()
        characters.value.set(character.id, character)
        await charactersRepo.upsert(character)
        const message = err instanceof Error ? err.message : String(err)
        error.value = message
        console.error('[CharacterStore] Failed to persist like state for', id, err)
        toast.error(message)
      }
    })
  }

  async function bookmark(id: string) {
    const character = characters.value.get(id)
    if (!character) {
      return
    }
    const wasBookmarked = character.bookmarks?.some(item => item.userId === auth.userId) ?? false
    const nextBookmarked = !wasBookmarked

    const bookmarks = character.bookmarks ?? []
    character.bookmarks = nextBookmarked
      ? [...bookmarks.filter(item => item.userId !== auth.userId), { userId: auth.userId, characterId: id }]
      : bookmarks.filter(item => item.userId !== auth.userId)
    character.bookmarksCount = Math.max(0, character.bookmarksCount + (nextBookmarked ? 1 : -1))
    character.updatedAt = new Date()
    characters.value.set(character.id, character)
    await charactersRepo.upsert(character)

    if (!hasDaemonCardMetadata()) {
      return
    }
    await enqueueDaemonMetadata(id, async () => {
      try {
        const liked = character.likes?.some(item => item.userId === auth.userId) ?? false
        const metadata = await setDaemonCardMetadata(id, { liked, bookmarked: nextBookmarked })
        applyDaemonMetadata(character, metadata, auth.userId)
        await charactersRepo.upsert(character)
      }
      catch (err) {
        // Daemon write failed: restore the pre-toggle optimistic state so the
        // local row matches what the daemon still believes.
        character.bookmarks = bookmarks
        character.bookmarksCount = Math.max(0, character.bookmarksCount + (nextBookmarked ? -1 : 1))
        character.updatedAt = new Date()
        characters.value.set(character.id, character)
        await charactersRepo.upsert(character)
        const message = err instanceof Error ? err.message : String(err)
        error.value = message
        console.error('[CharacterStore] Failed to persist bookmark state for', id, err)
        toast.error(message)
      }
    })
  }

  function getCharacter(id: string) {
    return characters.value.get(id)
  }

  /**
   * Hydrate local flags from the daemon-owned metadata. Called after the
   * character list loads so a restart still shows the right liked/bookmarked
   * state; the daemon is the durable source of truth, the local row is the
   * optimistic mirror.
   */
  async function loadDaemonMetadata(ids?: string[], userId?: string) {
    if (!hasDaemonCardMetadata()) {
      return
    }
    const actingUserId = userId ?? auth.userId
    const targets = ids ?? Array.from(characters.value.keys())
    const bulk = ids === undefined
    const pending = targets.map(async (id) => {
      const character = characters.value.get(id)
      if (!character) {
        return
      }
      await enqueueDaemonMetadata(id, async () => {
        try {
          const metadata = await fetchDaemonCardMetadata(id)
          applyDaemonMetadata(character, metadata, actingUserId)
          characters.value.set(character.id, character)
          await charactersRepo.upsert(character)
        }
        catch (err) {
          // Daemon absent: keep whatever the local cache holds. Bulk hydration
          // runs in the background, so one unavailable daemon must not produce
          // a toast per card or overwrite a more relevant action's error.
          if (bulk) {
            return
          }
          const message = err instanceof Error ? err.message : String(err)
          error.value = message
          console.error('[CharacterStore] Failed to load daemon card metadata for', id, err)
          toast.error(message)
        }
      })
    })
    if (bulk) {
      // Do not block fetchList: each RPC may open a WebSocket and time out.
      void Promise.all(pending)
      return
    }
    await Promise.all(pending)
  }

  return {
    characters,
    error,
    fetchList,
    fetchById,
    create,
    update,
    remove,
    like,
    bookmark,
    getCharacter,
    loadDaemonMetadata,
  }
})
