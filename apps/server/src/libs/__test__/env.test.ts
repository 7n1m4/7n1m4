import { describe, expect, it } from 'vitest'

import { parseEnv } from '../env'

describe('parseEnv', () => {
  it('requires DATABASE_URL', () => {
    expect(() => parseEnv({})).toThrow()
  })

  it('applies OTEL defaults', () => {
    const env = parseEnv({ DATABASE_URL: 'postgres://localhost/airi' })
    expect(env.OTEL_SERVICE_NAME).toBeDefined()
  })
})
