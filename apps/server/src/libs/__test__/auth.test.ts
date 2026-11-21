import { describe, expect, it } from 'vitest'

import { cookieAttributesFor } from '../auth'

describe('cookieAttributesFor', () => {
  it('does not set Secure on a plain HTTP deployment', () => {
    expect(cookieAttributesFor('http://192.168.1.10:3000')).toEqual({
      sameSite: 'Lax',
      secure: false,
    })
  })

  it('sets Secure and keeps Lax for an HTTPS deployment', () => {
    expect(cookieAttributesFor('https://chat.example.com')).toEqual({
      sameSite: 'Lax',
      secure: true,
    })
  })
})
