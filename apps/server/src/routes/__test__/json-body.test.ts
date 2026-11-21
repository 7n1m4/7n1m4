import type { HonoEnv } from '../../types/hono'

import { Hono } from 'hono'
import { beforeAll, describe, expect, it } from 'vitest'

import { ApiError } from '../../utils/error'
import { createCharacterRoutes } from '../characters'
import { createChatRoutes } from '../chats'
import { createGoogleDriveRoutes } from '../gdrive'
import { createProviderRoutes } from '../providers'

describe('malformed JSON bodies', () => {
  let app: Hono<HonoEnv>

  beforeAll(() => {
    // Parsing fails before any service method is reached, so a stub suffices.
    const stub = {} as any
    app = new Hono<HonoEnv>()
    app.onError((err, c) => {
      if (err instanceof ApiError)
        return c.json({ error: err.errorCode, message: err.message }, err.statusCode)
      return c.json({ error: 'Internal Server Error', message: err.message }, 500)
    })
    app.use('*', async (c, next) => {
      c.set('user', { id: 'user-1' } as any)
      await next()
    })
    app.route('/characters', createCharacterRoutes(stub))
    app.route('/providers', createProviderRoutes(stub))
    app.route('/chats', createChatRoutes(stub))
    app.route('/gdrive', createGoogleDriveRoutes(stub))
  })

  it.each([
    ['POST', '/characters'],
    ['PATCH', '/characters/c1'],
    ['POST', '/providers'],
    ['PATCH', '/providers/p1'],
    ['POST', '/chats/sync'],
    ['POST', '/gdrive/manifest'],
  ])('%s %s returns 400, not 500', async (method, path) => {
    const res = await app.fetch(new Request(`http://localhost${path}`, {
      method,
      body: '{not json',
      headers: { 'Content-Type': 'application/json' },
    }))

    expect(res.status).toBe(400)
    expect((await res.json() as any).error).toBe('INVALID_JSON')
  })
})
