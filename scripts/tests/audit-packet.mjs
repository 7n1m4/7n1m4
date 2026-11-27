#!/usr/bin/env node

/**
 * Round-17 audit-packet validator.
 *
 * A packet carries both pinned expectations and observed state so the same
 * pure core can check committed fixtures offline and live state on disk.
 * Self-tests always run before live validation; a broken fixture stops the
 * run before any live check is attempted. Guard SHAs are observed from the
 * git index and compared to `state/pinned-guards.sha`, never to file bytes.
 *
 * Exit codes:
 *   0 pass, 2 schema/fixture, 3 unknowns, 4 guard drift,
 *   5 chain/replay mismatch, 6 scope/lease collision (1 = unexpected error).
 *
 * Usage:
 *   node scripts/tests/audit-packet.mjs
 *   node scripts/tests/audit-packet.mjs --packet <path.json> [--offline]
 *
 * `--packet` is checked against a fresh live audit unless `--offline` is given:
 * self-certified packet flags must never outrank current HEAD or guard state.
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { fileURLToPath, pathToFileURL } from 'node:url'

import { SCHEMA_PACKET, verifyStateSnapshot } from '../lib/state-verifier.mjs'
import { buildAuditSnapshot, loadGuardPins } from '../sm.mjs'

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

/** Packet fields that must be real arrays — never coerced from a scalar. */
const ARRAY_KEYS = [
  'schema_issues',
  'unknowns',
  'unknowns_from_genesis',
  'unknowns_from_bindings',
  'invariants',
  'chain_issues',
  'projection_issues',
  'receipts',
  'replay_mismatches',
  'lease_collisions',
  'unanchored_receipts',
]

/** Packet flags that must be real booleans — never read by truthiness. */
const BOOLEAN_KEYS = ['chain_intact', 'replay_identical', 'lease_collision', 'head_matches']

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

function asArray(value) {
  return Array.isArray(value) ? [...value] : []
}

/**
 * Adapt a packet to the shared snapshot. Wave is a family (`r\d+`), so an
 * r18 packet validates here without editing this file or frozen state.
 * Boundary shapes are checked strictly here (the core stays pure).
 */
export function snapshotFromPacket(packet, { pinnedGuards } = {}) {
  if (!packet || typeof packet !== 'object' || Array.isArray(packet))
    return { schemaIssues: ['SCHEMA_NOT_OBJECT'] }

  const missing = REQUIRED_KEYS.filter(key => !(key in packet)).map(key => `SCHEMA_MISSING_${key}`)
  const extras = Object.keys(packet).filter(key => !REQUIRED_KEYS.includes(key)).sort()
  const placeholder = placeholderAt(packet)
  const schemaIssues = [
    ...missing,
    ...(extras.length > 0 ? [`SCHEMA_EXTRA_FIELDS:${extras.join(',')}`] : []),
    ...(placeholder ? [`PLACEHOLDER_TOKEN:${placeholder}`] : []),
    ...(packet.schema === SCHEMA_PACKET ? [] : ['SCHEMA_VERSION']),
    ...ARRAY_KEYS.filter(key => !Array.isArray(packet[key])).map(key => `SCHEMA_ARRAY:${key}`),
    ...BOOLEAN_KEYS.filter(key => typeof packet[key] !== 'boolean').map(key => `SCHEMA_FLAG:${key}`),
    ...asArray(packet.schema_issues),
  ]

  // Old validator required BOTH blobs to match the real pin set. Collapse that
  // third-value constraint onto the core's two-way guard comparison: pin the
  // expected side to the real pins and feed back whichever packet blob drifts.
  // Compare by key count and per-key value, not by JSON key order.
  const realPins = pinnedGuards ?? loadGuardPins()
  const matchesPins = (blobs) => {
    if (!blobs || typeof blobs !== 'object' || Array.isArray(blobs))
      return false
    const keys = Object.keys(blobs)
    return keys.length === Object.keys(realPins).length
      && keys.every(key => Object.hasOwn(realPins, key) && blobs[key] === realPins[key])
  }
  const pinnedMatches = matchesPins(packet.pinned_guard_blobs)
  const observedMatches = matchesPins(packet.observed_guard_blobs)
  const guardPins = realPins
  const observedGuardBlobs = pinnedMatches && observedMatches
    ? realPins
    : pinnedMatches ? packet.observed_guard_blobs : packet.pinned_guard_blobs

  return {
    wave: packet.wave,
    expectedWave: packet.wave,
    baseSha: packet.base_sha,
    beadsMode: packet.beads_mode,
    bindings: null,
    events: null,
    receipts: asArray(packet.receipts),
    receiptsPresent: packet.receipts_present,
    guardPins,
    observedGuardBlobs,
    wave0Scan: { known: [], unanchored: asArray(packet.unanchored_receipts) },
    effectiveHead: null,
    headMatches: packet.head_matches,
    schemaIssues,
    chainIssues: [
      ...asArray(packet.chain_issues),
      ...(packet.chain_intact === true ? [] : ['chain_intact_false']),
    ],
    projectionIssues: asArray(packet.projection_issues),
    leaseCollisions: [
      ...asArray(packet.lease_collisions),
      ...(packet.lease_collision === true ? ['lease_collision_flag'] : []),
    ],
    replayMismatches: [
      ...asArray(packet.replay_mismatches),
      ...(packet.replay_identical === true ? [] : ['flag']),
    ],
    genesisCount: packet.genesis_count,
    genesisSeq: packet.genesis_seq,
    invariants: asArray(packet.invariants),
    unknowns: [
      ...asArray(packet.unknowns_from_genesis),
      ...asArray(packet.unknowns_from_bindings),
      ...asArray(packet.unknowns),
    ],
  }
}

/** Packet-level compatibility entry point; all decisions live in the core. */
export function validateAuditPacket(packet, options = {}) {
  return verifyStateSnapshot(snapshotFromPacket(packet, options))
}

/** Thin CLI wrapper: log in the packet-validator format, decide in the core. */
export function auditSnapshot(snapshot, { logger = () => {} } = {}) {
  const observed = verifyStateSnapshot(snapshot)
  logger(`[LIVE] exit ${observed.code} ${observed.diagnostic}`)
  return observed
}

function readFixture(name) {
  const file = path.join(FIXTURE_DIR, name)
  if (!fs.existsSync(file))
    throw new Error(`missing audit-packet fixture: ${name}`)
  const packet = JSON.parse(fs.readFileSync(file, 'utf8'))
  // Guard blobs are live observations from state/pinned-guards.sha, never
  // fixture assertions that can silently go stale.
  const pins = loadGuardPins()
  return {
    ...packet,
    pinned_guard_blobs: { ...pins },
    observed_guard_blobs: { ...pins },
  }
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

function main(args) {
  const self = runSelfTest({ logger: message => console.error(message) })
  const broken = self.filter(testCase => !testCase.ok)
  if (broken.length > 0)
    return 2

  const packetIndex = args.indexOf('--packet')
  if (packetIndex !== -1) {
    const packetPath = args[packetIndex + 1]
    if (!packetPath) {
      console.error('[PACKET] exit 2 SCHEMA_PACKET_PATH')
      return 2
    }
    let packet
    try {
      packet = JSON.parse(fs.readFileSync(packetPath, 'utf8'))
    }
    catch (error) {
      console.error(`[PACKET] exit 2 FIXTURE_UNREADABLE:${error.message}`)
      return 2
    }
    if (!args.includes('--offline')) {
      const liveSnapshot = buildAuditSnapshot()
      const live = auditSnapshot(liveSnapshot, { logger: message => console.error(message) })
      if (live.code !== 0)
        return live.code
      if (packet?.base_sha !== liveSnapshot.baseSha) {
        console.error(`[PACKET] exit 2 PACKET_BASE_DRIFT:${String(packet?.base_sha)}:${liveSnapshot.baseSha}`)
        return 2
      }
    }
    const observed = verifyStateSnapshot(snapshotFromPacket(packet))
    console.error(`[PACKET] exit ${observed.code} ${observed.diagnostic}`)
    return observed.code
  }

  return auditSnapshot(buildAuditSnapshot(), { logger: message => console.error(message) }).code
}

const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false

if (isMain) {
  try {
    process.exit(main(process.argv.slice(2)))
  }
  catch (error) {
    console.error(`[AUDIT_PACKET_ERROR] ${error.message}`)
    process.exit(1)
  }
}
