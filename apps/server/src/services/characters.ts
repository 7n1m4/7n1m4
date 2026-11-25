import type { Database } from '../libs/db'

import { and, eq, isNull, sql } from 'drizzle-orm'

import { createNotFoundError } from '../utils/error'

import * as schema from '../schemas/characters'
import * as userCharacterSchema from '../schemas/user-character'

export function createCharacterService(db: Database) {
  return {
    async findById(id: string) {
      return await db.query.character.findFirst({
        where: and(
          eq(schema.character.id, id),
          isNull(schema.character.deletedAt),
        ),
        with: {
          capabilities: true,
          avatarModels: true,
          i18n: true,
          prompts: true,
          likes: true,
          bookmarks: true,
          cover: true,
        },
      })
    },

    async like(userId: string, characterId: string) {
      return await db.transaction(async (tx: any) => {
        const target = await tx.query.character.findFirst({
          where: and(
            eq(schema.character.id, characterId),
            isNull(schema.character.deletedAt),
          ),
        })
        if (!target)
          throw createNotFoundError('Character not found')

        const existing = await tx.query.characterLikes.findFirst({
          where: and(
            eq(userCharacterSchema.characterLikes.userId, userId),
            eq(userCharacterSchema.characterLikes.characterId, characterId),
          ),
        })

        if (existing) {
          await tx.delete(userCharacterSchema.characterLikes)
            .where(and(
              eq(userCharacterSchema.characterLikes.userId, userId),
              eq(userCharacterSchema.characterLikes.characterId, characterId),
            ))

          await tx.update(schema.character)
            .set({
              likesCount: sql`GREATEST(0, ${schema.character.likesCount} - 1)`,
            })
            .where(eq(schema.character.id, characterId))

          return { liked: false }
        }
        else {
          // Lost a concurrent first-like race: keep {liked:true}, don't double-count.
          const inserted = await tx.insert(userCharacterSchema.characterLikes).values({ userId, characterId }).onConflictDoNothing().returning({ userId: userCharacterSchema.characterLikes.userId })
          if (inserted.length === 0)
            return { liked: true }

          await tx.update(schema.character)
            .set({
              likesCount: sql`${schema.character.likesCount} + 1`,
            })
            .where(eq(schema.character.id, characterId))

          return { liked: true }
        }
      })
    },

    async bookmark(userId: string, characterId: string) {
      return await db.transaction(async (tx: any) => {
        const target = await tx.query.character.findFirst({
          where: and(
            eq(schema.character.id, characterId),
            isNull(schema.character.deletedAt),
          ),
        })
        if (!target)
          throw createNotFoundError('Character not found')

        const existing = await tx.query.characterBookmarks.findFirst({
          where: and(
            eq(userCharacterSchema.characterBookmarks.userId, userId),
            eq(userCharacterSchema.characterBookmarks.characterId, characterId),
          ),
        })

        if (existing) {
          await tx.delete(userCharacterSchema.characterBookmarks)
            .where(and(
              eq(userCharacterSchema.characterBookmarks.userId, userId),
              eq(userCharacterSchema.characterBookmarks.characterId, characterId),
            ))

          await tx.update(schema.character)
            .set({
              bookmarksCount: sql`GREATEST(0, ${schema.character.bookmarksCount} - 1)`,
            })
            .where(eq(schema.character.id, characterId))

          return { bookmarked: false }
        }
        else {
          const inserted = await tx.insert(userCharacterSchema.characterBookmarks).values({ userId, characterId }).onConflictDoNothing().returning({ userId: userCharacterSchema.characterBookmarks.userId })
          if (inserted.length === 0)
            return { bookmarked: true }

          await tx.update(schema.character)
            .set({
              bookmarksCount: sql`${schema.character.bookmarksCount} + 1`,
            })
            .where(eq(schema.character.id, characterId))

          return { bookmarked: true }
        }
      })
    },
  }
}

export type CharacterService = ReturnType<typeof createCharacterService>
