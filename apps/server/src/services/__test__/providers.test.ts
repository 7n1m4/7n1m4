import { beforeAll, describe, expect, it } from 'vitest'

import { mockDB } from '../../libs/mock-db'
import { createProviderService, stripCredentialKeys } from '../providers'

import * as schema from '../../schemas'

describe('providerService', () => {
  let db: any
  let service: ReturnType<typeof createProviderService>
  let testUser: any

  beforeAll(async () => {
    db = await mockDB(schema)
    service = createProviderService(db)

    // Create a test user for foreign key constraints
    const [user] = await db.insert(schema.user).values({
      id: 'user-1',
      name: 'Test User',
      email: 'test@example.com',
    }).returning()
    testUser = user
  })

  it('createUserConfig should handle provider config creation', async () => {
    const providerData = {
      id: 'prov-1',
      ownerId: testUser.id,
      definitionId: 'openai',
      name: 'My OpenAI',
      config: { apiKey: 'sk-123' },
      validated: true,
      validationBypassed: false,
    }

    const result = await service.createUserConfig(providerData)
    expect(result.id).toBe('prov-1')
    expect(result.name).toBe('My OpenAI')

    const found = await service.findUserConfigById('prov-1')
    expect(found).toBeDefined()
    expect(found!.definitionId).toBe('openai')
    expect((found!.config as Record<string, string>).apiKey).toBe('sk-123')
  })

  it('findUserConfigsByOwnerId should return providers for the user', async () => {
    const result = await service.findUserConfigsByOwnerId(testUser.id)
    expect(result.length).toBe(1)
    expect(result[0].ownerId).toBe(testUser.id)
  })

  it('findAll should return both user and system configs', async () => {
    // Create a system config
    await db.insert(schema.systemProviderConfigs).values({
      id: 'sys-1',
      definitionId: 'anthropic',
      name: 'System Anthropic',
      config: { apiKey: 'sys-sk' },
    })

    const result = await service.findAll(testUser.id)
    expect(result.length).toBe(2)

    const userConfig = result.find(r => r.id === 'prov-1')
    const systemConfig = result.find(r => r.id === 'sys-1')

    expect(userConfig?.isSystem).toBe(false)
    expect(systemConfig?.isSystem).toBe(true)
    expect(systemConfig?.name).toBe('System Anthropic')
  })

  it('updateUserConfig should update provider fields', async () => {
    await service.updateUserConfig('prov-1', { name: 'Updated OpenAI' })
    const prov = await service.findUserConfigById('prov-1')
    expect(prov?.name).toBe('Updated OpenAI')
  })

  it('deleteUserConfig should soft delete provider', async () => {
    await service.deleteUserConfig('prov-1')
    const prov = await service.findUserConfigById('prov-1')
    expect(prov).toBeUndefined()
  })

  it('stripCredentialKeys strips every secret but keeps maxTokens and tokenizer', () => {
    const stripped = stripCredentialKeys({
      apiKey: 'sk-1',
      authHeader: 'Bearer 1',
      accessToken: 't-1',
      secretAccessKey: 'aws-1',
      maxTokens: '4096',
      tokenizer: 'cl100k',
      baseUrl: 'https://example.com',
    })
    expect(stripped).toEqual({ maxTokens: '4096', tokenizer: 'cl100k', baseUrl: 'https://example.com' })
  })
})
