import type { Database } from './db'
import type { Env } from './env'

import process from 'node:process'

import { betterAuth } from 'better-auth'
import { drizzleAdapter } from 'better-auth/adapters/drizzle'
import { bearer } from 'better-auth/plugins'

import { deployedOrigin } from '../utils/origin'

import * as authSchema from '../schemas/accounts'

export function cookieAttributesFor(apiServerUrl: string) {
  return {
    // Lax covers the same-site API/webview traffic. Secure must follow the
    // configured scheme: browsers drop a Secure cookie set over plain HTTP.
    sameSite: 'Lax' as const,
    secure: apiServerUrl.startsWith('https://'),
  }
}

export function createAuth(db: Database, env: Env) {
  return betterAuth({
    database: drizzleAdapter(db, {
      provider: 'pg',
      schema: {
        ...authSchema,
      },
    }),

    plugins: [
      bearer(),
    ],

    session: {
      // Cache the session in the signed cookie for 5 minutes so /api/* does not
      // hit Postgres on every request; revocation latency is bounded by maxAge.
      cookieCache: {
        enabled: true,
        maxAge: 5 * 60,
      },
    },

    emailAndPassword: {
      enabled: true,
    },

    baseURL: env.API_SERVER_URL,
    // Same allowlist as the CORS middleware (utils/origin.ts). Localhost is dev-only.
    trustedOrigins: process.env.NODE_ENV !== 'production'
      ? [deployedOrigin, 'http://localhost:*']
      : [deployedOrigin],

    advanced: {
      // To skip state-mismatch errors
      // https://github.com/better-auth/better-auth/issues/4969#issuecomment-3397804378
      defaultCookieAttributes: cookieAttributesFor(env.API_SERVER_URL),
    },

    socialProviders: {
      ...(env.AUTH_GOOGLE_CLIENT_ID && env.AUTH_GOOGLE_CLIENT_SECRET
        ? {
            google: {
              clientId: env.AUTH_GOOGLE_CLIENT_ID,
              clientSecret: env.AUTH_GOOGLE_CLIENT_SECRET,
              scope: ['openid', 'profile', 'email', 'https://www.googleapis.com/auth/drive.appdata'],
            },
          }
        : {}),
      ...(env.AUTH_GITHUB_CLIENT_ID && env.AUTH_GITHUB_CLIENT_SECRET
        ? {
            github: {
              clientId: env.AUTH_GITHUB_CLIENT_ID,
              clientSecret: env.AUTH_GITHUB_CLIENT_SECRET,
            },
          }
        : {}),
    },
  })
}
