import type { Next } from 'hono'

import { createMiddleware } from 'hono/factory'

import { createForbiddenError } from '../utils/error'
import { getTrustedOrigin } from '../utils/origin'

const SAFE_METHODS = new Set(['GET', 'HEAD', 'OPTIONS'])

// CSRF belt for credentialed mutating routes: session cookies are SameSite=Lax
// (Secure only over HTTPS), so cross-site requests normally carry no session.
// Origin/Sec-Fetch-Site also reject cross-site *simple* requests (POST with a
// non-preflight content type) that CORS alone would not block. Non-browser
// clients (no Origin header) keep working.
export const requireSameOrigin = createMiddleware(async (c, next: Next) => {
  if (SAFE_METHODS.has(c.req.method))
    return next()

  const fetchSite = c.req.header('Sec-Fetch-Site')
  if (fetchSite === 'cross-site')
    throw createForbiddenError('Cross-site request blocked', 'CSRF_BLOCKED')

  const origin = c.req.header('Origin')
  if (origin && getTrustedOrigin(origin) === '')
    throw createForbiddenError('Cross-site request blocked', 'CSRF_BLOCKED')

  return next()
})
