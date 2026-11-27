import assert from 'node:assert/strict'
import path from 'node:path'
// eslint-disable-next-line test/no-import-node-test -- this is a node test file
import test from 'node:test'

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

import { verifyStateSnapshot } from '../lib/state-verifier.mjs'
import { auditSnapshot, buildAuditSnapshot } from '../sm.mjs'
import { auditSnapshot as packetAuditSnapshot, snapshotFromPacket, validateAuditPacket } from './audit-packet.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(__dirname, '..', '..')
const baseline = buildAuditSnapshot()

/** Exactly ten distinct mutations of the valid live snapshot. */
const mutations = [
  ['unresolved unknowns', (s) => {
    s.bindings.unknowns.push('airi-bdry')
    s.events[0].unknowns.push('airi-bdry')
  }, 3],
  ['guard pin drift', (s) => {
    const first = Object.keys(s.observedGuardBlobs).sort()[0]
    s.observedGuardBlobs[first] = '0'.repeat(40)
  }, 4],
  ['lease collision', (s) => {
    s.leaseCollisions.push('state/events.ndjson:L0+S2')
  }, 6],
  ['hash chain break', (s) => {
    s.events[1].prev_hash = 'f'.repeat(64)
  }, 5],
  ['genesis projection drift', (s) => {
    s.events[0].wave = 'r18'
  }, 5],
  ['effective HEAD drift', (s) => {
    s.effectiveHead = 'f'.repeat(40)
  }, 5],
  ['replay mismatch', (s) => {
    s.replayMismatches.push('events.ndjson:bytes')
  }, 5],
  ['bindings schema field', (s) => {
    s.bindings._generated_at = 'now'
  }, 2],
  ['genesis seq tampering', (s) => {
    s.events[0].seq = 99
  }, 2],
  ['placeholder token', (s) => {
    s.schemaIssues.push('PLACEHOLDER_TOKEN:$.base_sha')
  }, 2],
]

test('valid live snapshot is green on all three paths', () => {
  const core = verifyStateSnapshot(baseline)
  const sm = auditSnapshot(structuredClone(baseline), { logger: () => {} })
  const packet = packetAuditSnapshot(structuredClone(baseline), { logger: () => {} })
  assert.deepEqual(core, { code: 0, diagnostic: 'OK' })
  assert.deepEqual(sm, core)
  assert.deepEqual(packet, core)
})

test('ten mutants fail closed with byte-identical code and diagnostic on every path', () => {
  assert.equal(mutations.length, 10)
  const diagnostics = new Set(['OK'])
  for (const [name, mutate, expectedCode] of mutations) {
    const snapshot = structuredClone(baseline)
    mutate(snapshot)
    const core = verifyStateSnapshot(snapshot)
    const sm = auditSnapshot(structuredClone(snapshot), { logger: () => {} })
    const packet = packetAuditSnapshot(structuredClone(snapshot), { logger: () => {} })

    // Byte-for-byte parity: identical code AND diagnostic on all three paths.
    assert.deepEqual(sm, core, `${name}: sm diverged`)
    assert.deepEqual(packet, core, `${name}: packet diverged`)
    assert.equal(core.code, expectedCode, `${name}: ${core.diagnostic}`)
    assert.notEqual(core.code, 0, `${name}: mutant passed`)
    assert.ok(!diagnostics.has(core.diagnostic), `${name}: duplicate diagnostic ${core.diagnostic}`)
    diagnostics.add(core.diagnostic)
  }
  assert.equal(diagnostics.size, 11)
})

test('no mutant may pass on one path and fail on another', () => {
  for (const [name, mutate] of mutations) {
    const snapshot = structuredClone(baseline)
    mutate(snapshot)
    const codes = [
      verifyStateSnapshot(snapshot).code,
      auditSnapshot(snapshot, { logger: () => {} }).code,
      packetAuditSnapshot(snapshot, { logger: () => {} }).code,
    ]
    assert.equal(new Set(codes).size, 1, `${name}: fail-open on one path: ${codes.join(',')}`)
    assert.notEqual(codes[0], 0, `${name}: fail-open`)
  }
})

test('strict packet boundary checks fail closed (five reviewer findings)', () => {
  const valid = JSON.parse(requireFixture('valid.json'))
  const cases = [
    ['schema version v0', (p) => { p.schema = 'airi-audit-packet/v0' }, 2, /SCHEMA_VERSION/],
    ['chain_intact string', (p) => { p.chain_intact = 'false' }, 2, /SCHEMA_FLAG:chain_intact/],
    ['chain_issues string', (p) => { p.chain_issues = 'prev_hash:2' }, 2, /SCHEMA_ARRAY:chain_issues/],
    ['head_matches string', (p) => { p.head_matches = 'false' }, 2, /SCHEMA_FLAG:head_matches/],
    ['wrong-but-equal guard blobs', (p) => {
      const wrong = Object.fromEntries(Object.keys(p.pinned_guard_blobs).map(key => [key, '1'.repeat(40)]))
      p.pinned_guard_blobs = wrong
      p.observed_guard_blobs = structuredClone(wrong)
    }, 4, /GUARD_DRIFT/],
  ]
  assert.equal(cases.length, 5)
  for (const [name, mutate, expectedCode, pattern] of cases) {
    const packet = structuredClone(valid)
    mutate(packet)
    const viaValidator = validateAuditPacket(packet)
    const viaCore = verifyStateSnapshot(snapshotFromPacket(packet))
    assert.deepEqual(viaValidator, viaCore, `${name}: adapter/core diverged`)
    assert.equal(viaCore.code, expectedCode, `${name}: ${viaCore.diagnostic}`)
    assert.match(viaCore.diagnostic, pattern, name)
  }
})

test('r18 packet validates without editing frozen state', (t) => {
  const dir = mkdtempSync(path.join('/tmp/opencode', 'verify-parity-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const valid = JSON.parse(requireFixture('valid.json'))
  const r18 = { ...valid, wave: 'r18' }
  assert.deepEqual(validateAuditPacket(r18), { code: 0, diagnostic: 'OK' })
  assert.deepEqual(verifyStateSnapshot(snapshotFromPacket(r18)), { code: 0, diagnostic: 'OK' })

  const packetPath = path.join(dir, 'r18.json')
  writeFileSync(packetPath, `${JSON.stringify(r18, null, 2)}\n`)
  const cli = spawnSync(process.execPath, [path.join(repoRoot, 'scripts', 'tests', 'audit-packet.mjs'), '--packet', packetPath], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(cli.status, 0, cli.stderr)
  assert.match(cli.stderr, /\[PACKET\] exit 0 OK/)
})

function requireFixture(name) {
  return readFileSync(path.join(__dirname, 'fixtures', 'audit-packet', name), 'utf8')
}
