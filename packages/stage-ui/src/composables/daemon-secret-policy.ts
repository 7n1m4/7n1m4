// SPDX-License-Identifier: GPL-3.0-or-later
/**
 * Secret-key exclusion policy for unencrypted backup/sync.
 *
 * The daemon is the source of truth: `vault.secret_key_policy` is an ungated,
 * read-only verb that publishes matching patterns plus synthetic example
 * checks. It never reports stored keys, values or config blobs. Stage-web has
 * no daemon, so it keeps a minimal shape-based fallback instead of the old
 * hand-maintained key list. Both paths are fail-closed: a failed daemon call
 * leaves the fallback in place.
 */
import { daemonRequest, hasDaemon } from './daemon-rpc'

export interface SecretKeyPolicy {
  substrings: string[]
  suffixes: string[]
  storage_substrings?: string[]
  storage_prefixes?: string[]
  rule?: string
  examples?: Array<{ key: string, is_secret: boolean }>
}

/**
 * Minimal stage-web fallback: generic credential shapes, not a catalogue of
 * stored keys. Mirrors the daemon's published patterns; a renamed credential
 * is still caught because every row is a shape rather than a literal key.
 */
export const FALLBACK_SECRET_KEY_POLICY: SecretKeyPolicy = {
  substrings: ['apikey', 'authheader', 'authorization', 'secret', 'password', 'credential', 'bearer'],
  suffixes: ['token', 'key'],
  storage_substrings: ['accountid', 'freehub', 'keyid', 'keypair', 'mcpconfig', 'oauth', 'tlsconfig', 'verifier'],
  storage_prefixes: ['local:peers/device-keypair', 'local:providers', 'settings/credentials/', 'settings/free-hub/', 'settings/mcp/config'],
  examples: [
    { key: 'apiKey', is_secret: true },
    { key: 'X-New-Token', is_secret: true },
    { key: 'settings/<provider>/oauth-token', is_secret: true },
    { key: 'settings/<provider>/<id>-key-id', is_secret: true },
    { key: 'settings/<provider>/account-id', is_secret: true },
    { key: 'local:peers/device-keypair', is_secret: true },
    { key: 'local:providers', is_secret: true },
    { key: 'settings/mcp/config', is_secret: true },
    { key: 'settings/credentials/<provider>', is_secret: true },
    { key: 'cf_<flow>_verifier', is_secret: true },
    { key: 'settings/free-hub/<provider>/key', is_secret: true },
    { key: 'settings/<provider>/tls-config', is_secret: true },
    { key: 'endpoint', is_secret: false },
    { key: 'model', is_secret: false },
    { key: 'settings/providers/added', is_secret: false },
    { key: 'local:peers/roster', is_secret: false },
  ],
}

let currentPolicy: SecretKeyPolicy = FALLBACK_SECRET_KEY_POLICY
let policyLoad: Promise<void> | undefined

/** Normalize like the Rust policy: keep ASCII alphanumerics, lowercase. */
function normalizeKey(key: string): string {
  return key.toLowerCase().replace(/[^a-z0-9]/g, '')
}

/** Classify a key against an arbitrary published policy (pure, for tests). */
export function isSecretKeyUnderPolicy(key: string, policy: SecretKeyPolicy): boolean {
  const normalized = normalizeKey(key)
  const lowercase = key.toLowerCase()
  return policy.substrings.some(s => normalized.includes(s))
    || policy.suffixes.some(s => normalized.endsWith(s))
    || (policy.storage_substrings ?? []).some(s => normalized.includes(s))
    || (policy.storage_prefixes ?? []).some(p => lowercase.startsWith(p))
}

/** Synchronous classifier used by every backup/sync interceptor. */
export function isSecretStorageKey(key: string): boolean {
  return isSecretKeyUnderPolicy(key, currentPolicy)
}

/** A reply is adoptable only when every pattern family is present and non-empty. */
export function isCompleteSecretKeyPolicy(
  policy: SecretKeyPolicy | null | undefined,
): policy is SecretKeyPolicy {
  return !!policy
    && [policy.substrings, policy.suffixes, policy.storage_substrings, policy.storage_prefixes]
      .every(patterns => Array.isArray(patterns) && patterns.length > 0)
}

/**
 * Fetch the daemon policy once; concurrent callers share a single request.
 * Invalid replies and transport failures are ignored so the fail-closed
 * fallback stays authoritative. No-op on stage-web.
 */
export async function loadSecretKeyPolicy(): Promise<SecretKeyPolicy> {
  if (!hasDaemon())
    return currentPolicy
  if (!policyLoad) {
    policyLoad = daemonRequest<SecretKeyPolicy>('vault.secret_key_policy')
      .then((policy) => {
        // An older/incomplete reply must never drop the storage half of the
        // policy: without those patterns unencrypted sync could leak keys.
        if (isCompleteSecretKeyPolicy(policy)) {
          currentPolicy = policy
        }
        else {
          console.warn('[SecretPolicy] daemon returned an incomplete policy; keeping fallback')
          policyLoad = undefined
        }
      })
      .catch((error) => {
        console.warn('[SecretPolicy] daemon policy unavailable; keeping fallback', error)
        // Allow a later call to retry (e.g. once the auth token is mirrored).
        policyLoad = undefined
      })
  }
  await policyLoad
  return currentPolicy
}

// Warm up on import so the first storage write on a daemon-backed stage already
// sees the daemon policy. Stage-web returns the fallback without a request.
if (hasDaemon())
  void loadSecretKeyPolicy()
