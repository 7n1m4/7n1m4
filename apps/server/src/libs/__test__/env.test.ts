import { describe, expect, it } from 'vitest'

import { parseEnv } from '../env'

const baseEnv = {
  DATABASE_URL: 'postgres://localhost/airi',
  BETTER_AUTH_SECRET: 'x'.repeat(32),
}

describe('parseEnv', () => {
  it('accepts an email/password-only instance with no OAuth keys', () => {
    const env = parseEnv(baseEnv)

    expect(env.AUTH_GOOGLE_CLIENT_ID).toBeUndefined()
    expect(env.AUTH_GOOGLE_CLIENT_SECRET).toBeUndefined()
    expect(env.AUTH_GITHUB_CLIENT_ID).toBeUndefined()
    expect(env.AUTH_GITHUB_CLIENT_SECRET).toBeUndefined()
  })

  it('accepts a half-configured provider pair (registration is gated in createAuth)', () => {
    const env = parseEnv({ ...baseEnv, AUTH_GITHUB_CLIENT_ID: 'github-id' })

    expect(env.AUTH_GITHUB_CLIENT_ID).toBe('github-id')
    expect(env.AUTH_GITHUB_CLIENT_SECRET).toBeUndefined()
  })
})
