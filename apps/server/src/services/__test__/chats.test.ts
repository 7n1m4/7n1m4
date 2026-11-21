import { eq } from 'drizzle-orm'
import { beforeAll, describe, expect, it } from 'vitest'

import { mockDB } from '../../libs/mock-db'
import { createChatService } from '../chats'

import * as schema from '../../schemas'

describe('chatService', () => {
  let db: any
  let service: ReturnType<typeof createChatService>

  beforeAll(async () => {
    db = await mockDB(schema)
    service = createChatService(db)
  })

  it('syncChat dedupes repeated message ids before the bulk upsert', async () => {
    const result = await service.syncChat('user-1', {
      chat: { id: 'chat-dedupe', type: 'group' },
      messages: [
        { id: 'msg-dup', role: 'user', content: 'first write' },
        { id: 'msg-dup', role: 'user', content: 'retry wins' },
      ],
    })

    expect(result.chatId).toBe('chat-dedupe')

    const rows = await db.select().from(schema.messages).where(eq(schema.messages.chatId, 'chat-dedupe'))
    expect(rows).toHaveLength(1)
    expect(rows[0].content).toBe('retry wins')
  })
})
