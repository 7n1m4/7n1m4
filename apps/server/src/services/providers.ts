import type { Database } from '../libs/db'

import { and, eq, isNull, sql } from 'drizzle-orm'

import * as schema from '../schemas/providers'

// Credential-shaped config keys must never be readable from pooled system rows
// nor writable through the public PATCH endpoint. Match normalized names so real
// secrets (apiKey, authHeader, secretAccessKey, ...) are covered without also
// dropping legitimate settings such as maxTokens or tokenizer.
const SECRET_KEY_SUBSTRINGS = ['apikey', 'authheader', 'authorization', 'secret', 'password', 'credential', 'bearer']
const SECRET_KEY_SUFFIXES = ['token', 'key']

export function isSecretConfigKey(key: string): boolean {
  const normalized = key.toLowerCase().replace(/[^a-z0-9]/g, '')
  return SECRET_KEY_SUBSTRINGS.some(part => normalized.includes(part))
    || SECRET_KEY_SUFFIXES.some(suffix => normalized.endsWith(suffix))
}

export function stripCredentialKeys(value: unknown): unknown {
  if (Array.isArray(value))
    return value.map(stripCredentialKeys)
  if (value && typeof value === 'object') {
    const out: Record<string, unknown> = {}
    for (const [key, val] of Object.entries(value as Record<string, unknown>)) {
      if (isSecretConfigKey(key))
        continue
      out[key] = stripCredentialKeys(val)
    }
    return out
  }
  return value
}

/**
 * Merge a client-supplied config with the stored one, keeping the stored value
 * of every credential-shaped key. A PATCH may rotate a non-secret setting, but
 * must not be able to overwrite a managed secret by echoing its key.
 */
export function mergeConfigPreservingSecrets(
  existing: Record<string, unknown> | null | undefined,
  incoming: Record<string, unknown> | null | undefined,
): Record<string, unknown> {
  const protectedEntries = Object.entries(existing ?? {}).filter(([key]) => isSecretConfigKey(key))
  return { ...(incoming ?? {}), ...Object.fromEntries(protectedEntries) }
}

const toSafeSystemRow = (row: any) => ({ ...row, config: stripCredentialKeys(row.config) as any })

export function createProviderService(db: Database) {
  return {
    async findAll(ownerId: string) {
      const userConfigs = db
        .select({
          id: schema.userProviderConfigs.id,
          definitionId: schema.userProviderConfigs.definitionId,
          name: schema.userProviderConfigs.name,
          config: schema.userProviderConfigs.config,
          validated: schema.userProviderConfigs.validated,
          validationBypassed: schema.userProviderConfigs.validationBypassed,
          createdAt: schema.userProviderConfigs.createdAt,
          updatedAt: schema.userProviderConfigs.updatedAt,
          isSystem: sql<boolean>`false`.as('is_system'),
        })
        .from(schema.userProviderConfigs)
        .where(
          and(
            eq(schema.userProviderConfigs.ownerId, ownerId),
            isNull(schema.userProviderConfigs.deletedAt),
          ),
        )

      const systemConfigs = db
        .select({
          id: schema.systemProviderConfigs.id,
          definitionId: schema.systemProviderConfigs.definitionId,
          name: schema.systemProviderConfigs.name,
          config: schema.systemProviderConfigs.config,
          validated: schema.systemProviderConfigs.validated,
          validationBypassed: schema.systemProviderConfigs.validationBypassed,
          createdAt: schema.systemProviderConfigs.createdAt,
          updatedAt: schema.systemProviderConfigs.updatedAt,
          isSystem: sql<boolean>`true`.as('is_system'),
        })
        .from(schema.systemProviderConfigs)
        .where(isNull(schema.systemProviderConfigs.deletedAt))

      const rows = await userConfigs.unionAll(systemConfigs)
      // System rows are pooled for every signed-up user: never hand out their secrets.
      return rows.map((row: any) => (row.isSystem === true || row.is_system === true ? toSafeSystemRow(row) : row))
    },

    async findUserConfigsByOwnerId(ownerId: string) {
      return await db.query.userProviderConfigs.findMany({
        where: and(
          eq(schema.userProviderConfigs.ownerId, ownerId),
          isNull(schema.userProviderConfigs.deletedAt),
        ),
      })
    },

    async findUserConfigById(id: string) {
      return await db.query.userProviderConfigs.findFirst({
        where: and(
          eq(schema.userProviderConfigs.id, id),
          isNull(schema.userProviderConfigs.deletedAt),
        ),
      })
    },

    async createUserConfig(data: schema.NewUserProviderConfig) {
      const [inserted] = await db.insert(schema.userProviderConfigs).values(data).returning()
      return inserted
    },

    async updateUserConfig(id: string, data: Partial<schema.NewUserProviderConfig>) {
      // Never let a PATCH body reassign identity or row ownership.
      const { id: _id, ownerId: _owner, ...safe } = data as any
      const [updated] = await db.update(schema.userProviderConfigs)
        .set({ ...safe, updatedAt: new Date() })
        .where(and(
          eq(schema.userProviderConfigs.id, id),
          isNull(schema.userProviderConfigs.deletedAt),
        ))
        .returning()
      return updated
    },

    async deleteUserConfig(id: string) {
      return await db.update(schema.userProviderConfigs)
        .set({ deletedAt: new Date() })
        .where(and(
          eq(schema.userProviderConfigs.id, id),
          isNull(schema.userProviderConfigs.deletedAt),
        ))
        .returning()
    },
  }
}

export type ProviderService = ReturnType<typeof createProviderService>
