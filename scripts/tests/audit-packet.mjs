#!/usr/bin/env node

/**
 * Round-17 audit-packet validator.
 *
 * A packet carries both pinned expectations and observed state so the same
 * pure validator can check committed fixtures offline and live state on disk.
 * Self-tests always run before live validation; a broken fixture stops the
 * run before any live check is attempted. Guard SHAs are observed from the
 * git index and compared to `state/pinned-guards.sha`, never to file bytes.
 *
 * Exit codes:
 *   0 pass, 2 schema/fixture, 3 unknowns, 4 guard drift,
 *   5 chain/replay mismatch, 6 scope/lease collision (1 = unexpected error).
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { fileURLToPath, pathToFileURL } from 'node:url'

import {
  BINDINGS_KEYS,
  buildAllState,
  checkClosedSchema,
  deriveHead,
  detectLeaseCollision,
  GENESIS_KEYS,
  guardPinsFromIndex,
  ingestReceipts,
  INVARIANTS,
  loadGuardPins,
  readBindings,
  readEvents,
  RECEIPT_MANIFEST,
  resolveEffectiveHeadSha,
  resolveHeadSha,
  scanWave0Receipts,
  SCHEMA_PACKET,
  verifyEventChain,
  verifyEventProjection,
  verifyReplay,
  WAVE,
} from '../sm.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const FIXTURE_DIR = path.join(__dirname, 'fixtures', 'audit-packet')

const REQUIRED_KEYS = [
  'schema',
  'wave',
  'base_sha',
  'beads_mode',
  'schema_issues',
  'unknowns',
  'unknowns_from_genesis',
  'unknowns_from_bindings',
  'invariants',
  'genesis_count',
  'genesis_seq',
  'chain_intact',
  'chain_issues',
  'projection_issues',
  'receipts_present',
  'receipts',
  'pinned_guard_blobs',
  'observed_guard_blobs',
  'replay_identical',
  'replay_mismatches',
  'lease_collision',
  'lease_collisions',
  'unanchored_receipts',
  'head_matches',
]

const PLACEHOLDERS = ['TODO', 'TBD', 'FIXME', 'PLACEHOLDER', 'CHANGEME', 'XXX', '??']

function isSha(value, length = 40) {
  return typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value)
}

function placeholderAt(value, trail = '$') {
  if (typeof value === 'string') {
    return PLACEHOLDERS.some(token => value.includes(token)) ? trail : null
  }
  if (Array.isArray(value)) {
    for (let index = 0; index < value.length; index++) {
      const hit = placeholderAt(value[index], `${trail}[${index}]`)
      if (hit)
        return hit
    }
    return null
  }
  if (value && typeof value === 'object') {
    for (const [key, child] of Object.entries(value)) {
      const hit = placeholderAt(child, `${trail}.${key}`)
      if (hit)
        return hit
    }
  }
  return null
}

function result(code, diagnostic) {
  return { code, diagnostic }
}

/** Pure validation: never reads disk, never uses a clock. */
export function validateAuditPacket(packet, { pinnedGuards = loadGuardPins() } = {}) {
  if (!packet || typeof packet !== 'object' || Array.isArray(packet))
    return result(2, 'SCHEMA_NOT_OBJECT')
  for (const key of REQUIRED_KEYS) {
    if (!(key in packet))
      return result(2, `SCHEMA_MISSING_${key}`)
  }
  const extras = Object.keys(packet).filter(key => !REQUIRED_KEYS.includes(key)).sort()
  if (extras.length > 0)
    return result(2, `SCHEMA_EXTRA_FIELDS:${extras.join(',')}`)

  // Diagnose placeholders by name before shape checks so a stub such as
  // `PLACEHOLDER` is not mislabelled as a generic malformed SHA.
  const placeholder = placeholderAt(packet)
  if (placeholder)
    return result(2, `PLACEHOLDER_TOKEN:${placeholder}`)
  if (packet.schema_issues.length > 0)
    return result(2, `SCHEMA_LIVE_FIELDS:${packet.schema_issues.join(',')}`)

  if (packet.schema !== SCHEMA_PACKET)
    return result(2, 'SCHEMA_VERSION')
  if (packet.wave !== WAVE)
    return result(2, 'SCHEMA_WAVE')
  if (!isSha(packet.base_sha))
    return result(2, 'SCHEMA_BASE_SHA')
  if (packet.beads_mode !== 'PAUSED')
    return result(2, 'SCHEMA_BEADS_MODE')
  for (const key of ['unknowns', 'unknowns_from_genesis', 'unknowns_from_bindings', 'chain_issues', 'projection_issues', 'replay_mismatches', 'lease_collisions', 'unanchored_receipts']) {
    if (!Array.isArray(packet[key]))
      return result(2, `SCHEMA_ARRAY:${key}`)
  }
  if (!Array.isArray(packet.invariants) || !INVARIANTS.every(i => packet.invariants.includes(i)))
    return result(2, 'SCHEMA_INVARIANTS')
  if (packet.genesis_count !== 1 || packet.genesis_seq !== 1)
    return result(2, `SCHEMA_GENESIS:${packet.genesis_count}:${packet.genesis_seq}`)
  if (packet.receipts_present !== true)
    return result(2, 'SCHEMA_RECEIPTS_ABSENT')
  if (!Array.isArray(packet.receipts) || packet.receipts.length !== RECEIPT_MANIFEST.length)
    return result(2, 'SCHEMA_RECEIPT_COUNT')

  for (const receipt of packet.receipts) {
    if (!receipt || typeof receipt !== 'object')
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

  for (const key of ['pinned_guard_blobs', 'observed_guard_blobs']) {
    const blobs = packet[key]
    if (!blobs || typeof blobs !== 'object' || Array.isArray(blobs))
      return result(2, `SCHEMA_${key.toUpperCase()}`)
    for (const [relPath, sha] of Object.entries(blobs)) {
      if (!isSha(sha))
        return result(2, `SCHEMA_GUARD_SHA:${relPath}`)
    }
  }
  for (const key of ['chain_intact', 'replay_identical', 'lease_collision', 'head_matches']) {
    if (typeof packet[key] !== 'boolean')
      return result(2, `SCHEMA_FLAG:${key}`)
  }

  const allUnknowns = [
    ...packet.unknowns_from_genesis,
    ...packet.unknowns_from_bindings,
    ...packet.unknowns,
  ]
  if (allUnknowns.length > 0)
    return result(3, `UNKNOWNS_UNRESOLVED:${allUnknowns.join(',')}`)

  if (JSON.stringify(packet.pinned_guard_blobs) !== JSON.stringify(pinnedGuards)
    || JSON.stringify(packet.observed_guard_blobs) !== JSON.stringify(pinnedGuards)) {
    return result(4, `GUARD_DRIFT:${JSON.stringify(pinnedGuards)}`)
  }

  const chainIssues = [
    ...packet.chain_issues,
    ...(packet.chain_intact ? [] : ['chain_intact_false']),
    ...(packet.head_matches ? [] : ['head_mismatch']),
  ]
  if (chainIssues.length > 0)
    return result(5, `HASH_CHAIN:${chainIssues.join(',')}`)
  if (packet.projection_issues.length > 0)
    return result(5, `GENESIS_PROJECTION:${packet.projection_issues.join(',')}`)

  const leaseIssues = [
    ...packet.lease_collisions,
    ...(packet.lease_collision ? ['lease_collision_flag'] : []),
  ]
  if (leaseIssues.length > 0)
    return result(6, `LEASE_COLLISION:${leaseIssues.join(',')}`)

  if (!packet.replay_identical || packet.replay_mismatches.length > 0)
    return result(5, `REPLAY_MISMATCH:${packet.replay_mismatches.join(',') || 'flag'}`)

  return result(0, 'OK')
}

function readFixture(name) {
  const file = path.join(FIXTURE_DIR, name)
  if (!fs.existsSync(file))
    throw new Error(`missing audit-packet fixture: ${name}`)
  return JSON.parse(fs.readFileSync(file, 'utf8'))
}

function mutate(base, changes) {
  return { ...structuredClone(base), ...changes }
}

function selfTestCases() {
  const valid = readFixture('valid.json')
  const guardBlobs = { ...valid.observed_guard_blobs }
  const firstGuard = Object.keys(guardBlobs).sort()[0]
  guardBlobs[firstGuard] = '0'.repeat(40)
  return [
    { name: 'valid.json', packet: valid, expect: 0 },
    { name: 'invalid-missing-invariant.json', packet: readFixture('invalid-missing-invariant.json'), expect: 2 },
    { name: 'invalid-placeholder.json', packet: readFixture('invalid-placeholder.json'), expect: 2 },
    { name: 'invalid-unresolved-unknowns', packet: mutate(valid, { unknowns_from_genesis: ['airi-bdry'], unknowns: ['airi-bdry'] }), expect: 3 },
    { name: 'invalid-guard-drift', packet: mutate(valid, { observed_guard_blobs: guardBlobs }), expect: 4 },
    { name: 'invalid-hash-chain', packet: mutate(valid, { chain_intact: false, chain_issues: ['prev_hash:2'] }), expect: 5 },
    { name: 'invalid-replay-mismatch', packet: mutate(valid, { replay_identical: false, replay_mismatches: ['index.json:bytes'] }), expect: 5 },
    { name: 'invalid-lease-collision', packet: mutate(valid, { lease_collision: true, lease_collisions: ['state/events.ndjson:L0+S2'] }), expect: 6 },
  ]
}

/** Self-test first. Every case must match its expected code exactly. */
export function runSelfTest({ logger = () => {} } = {}) {
  let cases
  try {
    cases = selfTestCases()
  }
  catch (error) {
    const diagnostic = `FIXTURE_UNREADABLE:${error.message}`
    logger(`[SELF_TEST] fixtures -> exit 2 ${diagnostic}`)
    return [{ name: 'fixtures', expect: 2, code: 2, diagnostic, ok: false }]
  }
  return cases.map(({ name, packet, expect }) => {
    const observed = validateAuditPacket(packet)
    const ok = observed.code === expect
    logger(`[SELF_TEST] ${name} -> exit ${observed.code} ${observed.diagnostic}${ok ? '' : ` (EXPECTED ${expect})`}`)
    return { name, expect, ...observed, ok }
  })
}

/** Assemble the live packet from live state, the receipts and the git index. */
export function buildLivePacket() {
  const bindings = readBindings()
  const events = readEvents()
  const genesis = events.find(event => event?.type === 'genesis') ?? {}
  const receipts = ingestReceipts()
  const unanchored = scanWave0Receipts().unanchored
  const guardPins = loadGuardPins()
  const indexPins = guardPinsFromIndex().pins
  const head = deriveHead(events)
  let headMatches = false
  try {
    // Exact match first: offline repos can have a raw HEAD with no commit object.
    headMatches = resolveHeadSha() === head || resolveEffectiveHeadSha() === head
  }
  catch {
    headMatches = false
  }
  const chain = verifyEventChain(events)
  const files = buildAllState({ bindings, events, receipts, unanchored, guardPins, headSha: head })
  const replayMismatches = verifyReplay(files)
  const collisions = detectLeaseCollision(bindings.lane_leases, Object.keys(guardPins))
  return {
    schema: SCHEMA_PACKET,
    wave: WAVE,
    base_sha: bindings.base_sha,
    beads_mode: bindings.beads_mode,
    unknowns: [
      ...(Array.isArray(genesis.unknowns) ? genesis.unknowns : ['malformed']),
      ...(Array.isArray(bindings.unknowns) ? bindings.unknowns : ['malformed']),
    ],
    unknowns_from_genesis: Array.isArray(genesis.unknowns) ? [...genesis.unknowns] : ['malformed'],
    unknowns_from_bindings: Array.isArray(bindings.unknowns) ? [...bindings.unknowns] : ['malformed'],
    invariants: [...INVARIANTS],
    genesis_count: events.filter(event => event?.type === 'genesis').length,
    genesis_seq: genesis.seq,
    schema_issues: [
      ...checkClosedSchema(bindings, BINDINGS_KEYS, 'bindings'),
      ...checkClosedSchema(genesis, GENESIS_KEYS, 'genesis'),
    ],
    chain_intact: chain.length === 0,
    chain_issues: chain,
    projection_issues: verifyEventProjection(events, { receipts, unanchored, guardPins }),
    receipts_present: receipts.length === RECEIPT_MANIFEST.length,
    receipts: receipts.map(receipt => ({ ...receipt })),
    pinned_guard_blobs: { ...guardPins },
    observed_guard_blobs: { ...indexPins },
    replay_identical: replayMismatches.length === 0,
    replay_mismatches: replayMismatches,
    lease_collision: collisions.length > 0,
    lease_collisions: collisions,
    unanchored_receipts: unanchored.map(entry => ({ ...entry })),
    head_matches: headMatches,
  }
}

function main() {
  const cases = runSelfTest({ logger: message => console.error(message) })
  const broken = cases.filter(testCase => !testCase.ok)
  if (broken.length > 0)
    return 2

  const live = validateAuditPacket(buildLivePacket())
  console.error(`[LIVE] exit ${live.code} ${live.diagnostic}`)
  // Propagate the live code verbatim: never turn a failing live audit into 0.
  return live.code
}

const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false

if (isMain) {
  try {
    process.exit(main())
  }
  catch (error) {
    console.error(`[AUDIT_PACKET_ERROR] ${error.message}`)
    process.exit(1)
  }
}
