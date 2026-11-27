#!/usr/bin/env node

/**
 * Pure state verifier — the single decision point for the r1x audit taxonomy.
 *
 * Everything here is in-memory: no fs, no git, no clock. Callers observe the
 * world (disk, git index, HEAD) and hand the result in as a plain snapshot;
 * this module only decides the exit code and the diagnostic. Both `sm audit`
 * and the audit-packet validator call `verifyStateSnapshot`, so they cannot
 * disagree about a snapshot.
 */

import { Buffer } from 'node:buffer'
import { createHash } from 'node:crypto'

export const WAVE = 'r17'
export const BASE_SHA = '38613b6ebc36ec59dd4687b5b5895dc469b84dc5'
export const ZERO_HASH = '0'.repeat(64)
export const SCHEMA_BINDINGS = 'airi-state-bindings/v1'
export const SCHEMA_PACKET = 'airi-audit-packet/v1'

/** Each receipt is pinned by base/head/diff hash AND the sha256 of its bytes. */
export const RECEIPT_MANIFEST = [
  {
    id: 'airi-n90x',
    path: '.wave0/lane-airi-n90x/receipt.json',
    base_sha: '31295343c20dad066b38265837e8ff58391ca680',
    head_sha: '31295343c20dad066b38265837e8ff58391ca680',
    diff_hash: 'fccb761403a45cf6344e8376d4e127a4cfb7040667cc0c8a304fb746060e164b',
    sha256: 'a312cf55d41972af1ce2eecf003ce75c56a87de11c260dfa56bbfbaab2e0f414',
  },
  {
    id: 'airi-3jea',
    path: '.wave0/lane-airi-3jea/receipt.json',
    base_sha: '31295343c20dad066b38265837e8ff58391ca680',
    head_sha: '31295343c20dad066b38265837e8ff58391ca680',
    diff_hash: '2ff730d25f8d31bcf719d6c0b8955d0f9253f734e2e8750c06ef2ac67950cb3c',
    sha256: '9cc4d6786c5d32d7c7b36e60a07008e113c9b537f35b0d1c5e88218fc6f639a5',
  },
  {
    id: 'airi-4boj',
    path: '.wave0/lane-airi-4boj/receipt.json',
    base_sha: '85b9237e41ad584ce41e37de9776634c89ace0f2',
    head_sha: '85b9237e41ad584ce41e37de9776634c89ace0f2',
    diff_hash: null,
    sha256: '66cf28f6897170715f4800dc5a3bf46fae8f269aee354eba0f9360161c660c06',
  },
  {
    id: 'airi-3c7w',
    path: '.wave0/lane-airi-3c7w/receipt.json',
    base_sha: '31295343c20dad066b38265837e8ff58391ca680',
    head_sha: '31295343c20dad066b38265837e8ff58391ca680',
    diff_hash: '3c2ee6cec44a6a253f088441a53531bf71317e80dc76b666982d6a97eef5ff68',
    sha256: '90544aae3de2fb4a72e61a60279de37d9fcf787087d8036fb49be2895feb3d60',
  },
  {
    id: 'airi-tan6',
    path: '.wave0/lane-airi-tan6/receipt.json',
    base_sha: '31295343c20dad066b38265837e8ff58391ca680',
    head_sha: '31295343c20dad066b38265837e8ff58391ca680',
    diff_hash: 'c94fe786d7a6ff0961db2dd59e527e9166b10baa22d37eedf8f748270ede55be',
    sha256: '702fa0a5bdd05be722d0e2361b0cb52d866fdae9831a8bf10295f2d5de905cb6',
  },
]

export const INVARIANTS = [
  'single_genesis',
  'beads_paused',
  'unknowns_empty',
  'receipts_present',
  'guards_pinned',
  'leases_disjoint',
  'hash_chain_intact',
  'replay_identical',
]

export const BINDINGS_KEYS = [
  'schema',
  'wave',
  'base_sha',
  'beads_mode',
  'unknowns',
  'receipts',
  'pinned_guard_blobs',
  'lane_leases',
  'unanchored_receipts',
]
export const GENESIS_KEYS = [
  'seq',
  'type',
  'prev_hash',
  'wave',
  'base_sha',
  'beads_mode',
  'unknowns',
  'receipts',
  'pinned_guard_blobs',
  'lane_leases',
  'unanchored_receipts',
  'red_evidence',
]

export function isSha(value, length = 40) {
  return typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value)
}

export function checkClosed(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    return [`${label}:not_object`]
  const extras = Object.keys(value).filter(key => !allowed.includes(key)).sort()
  const missing = allowed.filter(key => !(key in value)).sort()
  return [
    ...extras.map(key => `${label}:extra_field:${key}`),
    ...missing.map(key => `${label}:missing_field:${key}`),
  ]
}

/** Hash of an event's exact JSON — the hash-chain link. */
export function hashEvent(event) {
  return createHash('sha256').update(Buffer.from(JSON.stringify(event), 'utf8')).digest('hex')
}

/** Deep-stable JSON: object keys sorted at every level, arrays kept in order. */
export function canonicalJson(value) {
  if (Array.isArray(value))
    return `[${value.map(canonicalJson).join(',')}]`
  if (value && typeof value === 'object')
    return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`
  return JSON.stringify(value) ?? 'null'
}

export function deriveHead(events) {
  let head = BASE_SHA
  for (const event of events) {
    if (event?.type === 'head_advanced')
      head = event.sha
  }
  return head
}

export function buildUnanchoredEvents(unanchored, prevHash) {
  let prev = prevHash
  let seq = 2
  return unanchored.map((entry) => {
    const event = {
      seq: seq++,
      type: 'WAVE0_RECEIPT_INGESTED',
      prev_hash: prev,
      path: entry.path,
      sha256: entry.sha256,
      anchor_status: 'UNCOMMITTED_OR_ORPHAN',
      commit_sha: null,
    }
    prev = hashEvent(event)
    return event
  })
}

/**
 * Differential projection against a freshly built full genesis supplied by the
 * observer. Canonical JSON (sorted keys at every level) makes the comparison
 * independent of key order while still covering every field — including
 * `red_evidence`, which a short whitelist would let drift unnoticed.
 */
function verifyGenesisProjection(events, genesis, snapshot, unanchored) {
  if (!genesis)
    return ['genesis_missing']
  const issues = []
  const expectedGenesis = snapshot.expectedGenesis
  if (!expectedGenesis || canonicalJson(genesis) !== canonicalJson(expectedGenesis))
    issues.push('GENESIS_CONTENT_DRIFT')
  // The observer's bindings must agree with genesis even when no full genesis
  // was supplied; this check is deliberately not delegated to the observer.
  if (snapshot.bindings && canonicalJson(genesis.lane_leases) !== canonicalJson(snapshot.bindings.lane_leases))
    issues.push('GENESIS_CONTENT_DRIFT')
  const expectedUnanchored = buildUnanchoredEvents(unanchored, hashEvent(expectedGenesis ?? genesis))
  const actualUnanchored = events.filter(event => event?.type === 'WAVE0_RECEIPT_INGESTED')
  if (canonicalJson(actualUnanchored) !== canonicalJson(expectedUnanchored))
    issues.push('UNANCHORED_EVENT_DRIFT')
  return [...new Set(issues)].sort()
}

export function verifyEventChain(events) {
  if (!Array.isArray(events) || events.length === 0)
    return ['empty_event_log']
  const issues = []
  events.forEach((event, index) => {
    if (event?.seq !== index + 1)
      issues.push(`seq:${index}:${event?.seq}`)
    if (!event || typeof event !== 'object' || Array.isArray(event)) {
      issues.push(`malformed:${index}`)
      return
    }
    if (index === 0) {
      if (event.type !== 'genesis')
        issues.push('genesis_not_first')
      if (event.prev_hash !== ZERO_HASH)
        issues.push('genesis_prev_hash')
      issues.push(...checkClosed(event, GENESIS_KEYS, 'genesis'))
      return
    }
    if (event.prev_hash !== hashEvent(events[index - 1]))
      issues.push(`prev_hash:${index}`)
    const allowed = event.type === 'WAVE0_RECEIPT_INGESTED'
      ? ['seq', 'type', 'prev_hash', 'path', 'sha256', 'anchor_status', 'commit_sha']
      : event.type === 'head_advanced'
        ? ['seq', 'type', 'prev_hash', 'sha']
        : []
    if (allowed.length === 0) {
      issues.push(`type:${index}:${event.type}`)
      return
    }
    issues.push(...checkClosed(event, allowed, `event_${index}`))
    if (event.type === 'head_advanced' && !isSha(event.sha))
      issues.push(`head_sha:${index}`)
  })
  if (events.filter(event => event?.type === 'genesis').length !== 1)
    issues.push('genesis_count')
  return issues
}

function result(code, diagnostic) {
  return { code, diagnostic }
}

function isBlobMap(value) {
  return value && typeof value === 'object' && !Array.isArray(value)
}

/**
 * Decide the exit code for one in-memory snapshot. No I/O, no clock.
 *
 * `schemaIssues`, `chainIssues`, `projectionIssues`, `leaseCollisions`,
 * `replayMismatches` and `headMatches` carry observations that cannot be
 * derived from a snapshot alone (realpath, disk bytes, git ancestry, or a
 * packet's asserted flags). When absent, the pure checks below derive them
 * from `bindings`/`events`/`receipts`/`wave0Scan`/`effectiveHead`.
 */
export function verifyStateSnapshot(snapshot) {
  if (!snapshot || typeof snapshot !== 'object' || Array.isArray(snapshot))
    return result(2, 'SCHEMA_NOT_OBJECT')

  const events = Array.isArray(snapshot.events) ? snapshot.events : null
  const genesis = events ? events.find(event => event?.type === 'genesis') : null
  const schemaIssues = Array.isArray(snapshot.schemaIssues) ? [...snapshot.schemaIssues] : []
  if (isBlobMap(snapshot.bindings))
    schemaIssues.push(...checkClosed(snapshot.bindings, BINDINGS_KEYS, 'bindings'))
  if (genesis)
    schemaIssues.push(...checkClosed(genesis, GENESIS_KEYS, 'genesis'))
  if (schemaIssues.length > 0)
    return result(2, `SCHEMA_LIVE_FIELDS:${schemaIssues.join(',')}`)

  // Wave is checked as a family (`r\d+`) so an r18 packet can be validated
  // without editing this module; live callers pin it via `expectedWave`.
  const expectedWave = snapshot.expectedWave ?? WAVE
  if (typeof snapshot.wave !== 'string' || !/^r\d+$/.test(snapshot.wave) || snapshot.wave !== expectedWave)
    return result(2, `SCHEMA_WAVE:${String(snapshot.wave)}`)
  if (!isSha(snapshot.baseSha) || snapshot.baseSha !== BASE_SHA)
    return result(2, 'SCHEMA_BASE_SHA')
  if (snapshot.beadsMode !== 'PAUSED')
    return result(2, 'SCHEMA_BEADS_MODE')

  const invariants = Array.isArray(snapshot.invariants) ? snapshot.invariants : []
  if (!INVARIANTS.every(invariant => invariants.includes(invariant)))
    return result(2, 'SCHEMA_INVARIANTS')

  const genesisCount = events
    ? events.filter(event => event?.type === 'genesis').length
    : (snapshot.genesisCount ?? 0)
  const genesisSeq = events && genesis ? genesis.seq : snapshot.genesisSeq
  if (genesisCount !== 1 || genesisSeq !== 1)
    return result(2, `SCHEMA_GENESIS:${genesisCount}:${genesisSeq}`)

  const receipts = Array.isArray(snapshot.receipts) ? snapshot.receipts : []
  if (snapshot.receiptsPresent !== true || receipts.length !== RECEIPT_MANIFEST.length)
    return result(2, 'SCHEMA_RECEIPT_COUNT')
  for (const receipt of receipts) {
    if (!isBlobMap(receipt))
      return result(2, 'SCHEMA_RECEIPT_TYPE')
    for (const key of ['id', 'path', 'base_sha', 'head_sha', 'diff_hash', 'sha256']) {
      if (!(key in receipt))
        return result(2, `SCHEMA_RECEIPT_MISSING_${key}`)
    }
    const manifest = RECEIPT_MANIFEST.find(item => item.id === receipt.id)
    if (!manifest || !isSha(receipt.base_sha) || !isSha(receipt.head_sha))
      return result(2, `SCHEMA_RECEIPT_SHA:${receipt.id}`)
    if (receipt.diff_hash !== null && !isSha(receipt.diff_hash, 64))
      return result(2, `SCHEMA_RECEIPT_DIFF_HASH:${receipt.id}`)
    if (!isSha(receipt.sha256, 64))
      return result(2, `SCHEMA_RECEIPT_SHA256:${receipt.id}`)
    if (receipt.base_sha !== manifest.base_sha || receipt.head_sha !== manifest.head_sha
      || receipt.diff_hash !== manifest.diff_hash || receipt.sha256 !== manifest.sha256) {
      return result(2, `RECEIPT_ANCHOR_DRIFT:${receipt.id}`)
    }
  }

  const guardPins = snapshot.guardPins
  const observedGuardBlobs = snapshot.observedGuardBlobs
  if (!isBlobMap(guardPins) || !isBlobMap(observedGuardBlobs))
    return result(2, 'SCHEMA_GUARD_BLOBS')
  for (const blobs of [guardPins, observedGuardBlobs]) {
    for (const [relPath, sha] of Object.entries(blobs)) {
      if (!isSha(sha))
        return result(2, `SCHEMA_GUARD_SHA:${relPath}`)
    }
  }

  const unknowns = Array.isArray(snapshot.unknowns)
    ? [...snapshot.unknowns]
    : genesis && snapshot.bindings
      ? [
          ...(Array.isArray(genesis.unknowns) ? genesis.unknowns : ['malformed']),
          ...(Array.isArray(snapshot.bindings.unknowns) ? snapshot.bindings.unknowns : ['malformed']),
        ]
      : []
  if (unknowns.length > 0)
    return result(3, `UNKNOWNS_UNRESOLVED:${unknowns.join(',')}`)

  if (JSON.stringify(guardPins) !== JSON.stringify(observedGuardBlobs))
    return result(4, `GUARD_DRIFT:${JSON.stringify(observedGuardBlobs)}`)

  const leaseCollisions = Array.isArray(snapshot.leaseCollisions) ? snapshot.leaseCollisions : []
  if (leaseCollisions.length > 0)
    return result(6, `LEASE_COLLISION:${leaseCollisions.join(',')}`)

  // When raw events are present they are authoritative: a stale precomputed
  // issue list must never let a mutated event log fail open.
  const chainIssues = events
    ? verifyEventChain(events)
    : (Array.isArray(snapshot.chainIssues) ? snapshot.chainIssues : [])
  if (chainIssues.length > 0)
    return result(5, `HASH_CHAIN:${chainIssues.join(',')}`)

  const unanchored = snapshot.wave0Scan && Array.isArray(snapshot.wave0Scan.unanchored)
    ? snapshot.wave0Scan.unanchored
    : []
  const projectionIssues = events
    ? verifyGenesisProjection(events, genesis, snapshot, unanchored)
    : (Array.isArray(snapshot.projectionIssues) ? snapshot.projectionIssues : [])
  if (projectionIssues.length > 0)
    return result(5, `GENESIS_PROJECTION:${projectionIssues.join(',')}`)

  const derivedHead = events ? deriveHead(events) : null
  const headMatches = events
    ? snapshot.effectiveHead === derivedHead
    : (snapshot.headMatches === undefined ? false : snapshot.headMatches)
  if (!headMatches)
    return result(5, `HEAD_DRIFT:head_mismatch:${snapshot.effectiveHead ?? 'null'}`)

  const replayMismatches = Array.isArray(snapshot.replayMismatches) ? snapshot.replayMismatches : []
  if (replayMismatches.length > 0)
    return result(5, `REPLAY_MISMATCH:${replayMismatches.join(',')}`)

  return result(0, 'OK')
}
