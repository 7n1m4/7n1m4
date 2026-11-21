import { safeParse } from 'valibot'
import { describe, expect, it } from 'vitest'

import { CHAT_SYNC_MAX_MESSAGES, ChatSyncSchema } from '../chats.schema'

function messagesOf(length: number) {
  return Array.from({ length }, (_, i) => ({
    id: `msg-${i}`,
    role: 'user' as const,
    content: 'hi',
  }))
}

describe('chatSyncSchema', () => {
  it('accepts a full-history sync at the message cap', () => {
    const result = safeParse(ChatSyncSchema, {
      chat: { id: 'chat-1' },
      messages: messagesOf(CHAT_SYNC_MAX_MESSAGES),
    })
    expect(result.success).toBe(true)
  })

  it('rejects a messages array longer than the sync cap', () => {
    const result = safeParse(ChatSyncSchema, {
      chat: { id: 'chat-1' },
      messages: messagesOf(CHAT_SYNC_MAX_MESSAGES + 1),
    })
    expect(result.success).toBe(false)
    if (!result.success) {
      expect(result.issues.some(issue => issue.message.includes('length'))).toBe(true)
    }
  })
})
