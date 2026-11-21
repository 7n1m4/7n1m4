import { array, literal, maxLength, number, object, optional, pipe, string, union } from 'valibot'

// A single sync performs one bulk upsert inside a transaction. Keep the cap
// generous enough for a full chat history, while bounding the work a client can
// request in one call (the 1 MB body limit is the transport-level bound).
export const CHAT_SYNC_MAX_MESSAGES = 5000

const ChatTypeSchema = union([
  literal('private'),
  literal('bot'),
  literal('group'),
  literal('channel'),
])

const ChatMemberTypeSchema = union([
  literal('user'),
  literal('character'),
  literal('bot'),
])

const ChatMessageRoleSchema = union([
  literal('system'),
  literal('user'),
  literal('assistant'),
  literal('tool'),
  literal('error'),
])

export const ChatSyncMessageSchema = object({
  id: string(),
  role: ChatMessageRoleSchema,
  content: string(),
  createdAt: optional(number()),
})

export const ChatSyncSchema = object({
  chat: object({
    id: string(),
    type: optional(ChatTypeSchema),
    title: optional(string()),
    createdAt: optional(number()),
    updatedAt: optional(number()),
  }),
  members: optional(pipe(array(object({
    type: ChatMemberTypeSchema,
    userId: optional(string()),
    characterId: optional(string()),
  })), maxLength(64))), // Bound the per-member SELECT storm a full sync can trigger
  messages: pipe(array(ChatSyncMessageSchema), maxLength(CHAT_SYNC_MAX_MESSAGES)),
})
