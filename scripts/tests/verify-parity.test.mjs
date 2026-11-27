import assert from 'node:assert/strict'
import path from 'node:path'
// eslint-disable-next-line test/no-import-node-test -- this is a node test file
import test from 'node:test'

import { spawnSync } from 'node:child_process'
import { cpSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

import { hashEvent, verifyStateSnapshot } from '../lib/state-verifier.mjs'
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

/** Throwaway repo with a real history whose trailing seal records its parent's head. */
function makeHistoryRepo(t) {
  const dir = mkdtempSync(path.join('/tmp/opencode', 'verify-head-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const rel of ['scripts', 'state', '.wave0'])
    cpSync(path.join(repoRoot, rel), path.join(dir, rel), { recursive: true })

  const git = args => spawnSync('git', args, {
    cwd: dir,
    encoding: 'utf8',
    env: {
      ...process.env,
      LC_ALL: 'C',
      GIT_AUTHOR_NAME: 'Parity Test',
      GIT_AUTHOR_EMAIL: 'parity@example.invalid',
      GIT_COMMITTER_NAME: 'Parity Test',
      GIT_COMMITTER_EMAIL: 'parity@example.invalid',
    },
  })
  const ok = (args) => {
    const result = git(args)
    assert.equal(result.status, 0, `git ${args.join(' ')}: ${result.stderr}`)
    return result.stdout.trim()
  }
  ok(['init', '-q'])
  ok(['config', 'commit.gpgsign', 'false'])
  ok(['config', 'core.hooksPath', '/dev/null'])
  ok(['add', '-A'])
  ok(['commit', '-q', '-m', 'genesis'])

  writeFileSync(path.join(dir, 'feature.txt'), 'feature\n')
  ok(['add', 'feature.txt'])
  ok(['commit', '-q', '-m', 'feature'])
  const featureSha = ok(['rev-parse', 'HEAD'])
  const advanced = spawnSync(process.execPath, [path.join(dir, 'scripts', 'sm.mjs'), 'head:advance', '--sha', featureSha], { cwd: dir, encoding: 'utf8' })
  assert.equal(advanced.status, 0, advanced.stderr)
  ok(['add', '--', 'state/events.ndjson', 'state/index.json', 'state/bindings.json'])
  ok(['commit', '-q', '-m', 'state seal'])
  return { dir, git, ok, featureSha, sealSha: ok(['rev-parse', 'HEAD']) }
}

test('self-certified packet cannot certify a stale live HEAD (F10)', (t) => {
  const { dir, ok } = makeHistoryRepo(t)
  writeFileSync(path.join(dir, 'drift.js'), 'export {}\n')
  ok(['add', 'drift.js'])
  ok(['commit', '-q', '-m', 'code drift'])

  const packetPath = path.join(dir, 'packet.json')
  writeFileSync(packetPath, requireFixture('valid.json'))
  const run = extra => spawnSync(process.execPath, [path.join(dir, 'scripts', 'tests', 'audit-packet.mjs'), '--packet', packetPath, ...extra], { cwd: dir, encoding: 'utf8' })
  const online = run([])
  assert.equal(online.status, 5, online.stderr)
  assert.match(online.stderr, /\[LIVE\] exit 5 HEAD_DRIFT/)
  const offline = run(['--offline'])
  assert.equal(offline.status, 0, offline.stderr)
  assert.doesNotMatch(offline.stderr, /\[LIVE\]/)
})

test('red_evidence drift fails closed even after the chain is rebuilt (F11)', () => {
  const snapshot = structuredClone(baseline)
  snapshot.events[0].red_evidence.commands[0].exit_code = 0
  for (let index = 1; index < snapshot.events.length; index++)
    snapshot.events[index].prev_hash = hashEvent(snapshot.events[index - 1])

  const core = verifyStateSnapshot(snapshot)
  assert.equal(core.code, 5, core.diagnostic)
  assert.match(core.diagnostic, /GENESIS_PROJECTION:GENESIS_CONTENT_DRIFT/)
  assert.deepEqual(auditSnapshot(structuredClone(snapshot), { logger: () => {} }), core)
  assert.deepEqual(packetAuditSnapshot(structuredClone(snapshot), { logger: () => {} }), core)
})

test('packet base SHA is compared with the live base (F10)', (t) => {
  const dir = mkdtempSync(path.join('/tmp/opencode', 'verify-base-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  const packet = { ...JSON.parse(requireFixture('valid.json')), base_sha: 'a'.repeat(40) }
  const packetPath = path.join(dir, 'base-drift.json')
  writeFileSync(packetPath, JSON.stringify(packet))
  const cli = spawnSync(process.execPath, [path.join(repoRoot, 'scripts', 'tests', 'audit-packet.mjs'), '--packet', packetPath], {
    cwd: repoRoot,
    encoding: 'utf8',
  })
  assert.equal(cli.status, 2, cli.stderr)
  assert.match(cli.stderr, /\[PACKET\] exit 2 PACKET_BASE_DRIFT/)
})

test('fixtures follow the guard pins while a blob mismatch still fails closed (F13)', (t) => {
  const dir = mkdtempSync(path.join('/tmp/opencode', 'verify-pins-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const rel of ['scripts', 'state', '.wave0'])
    cpSync(path.join(repoRoot, rel), path.join(dir, rel), { recursive: true })

  const pinFile = path.join(dir, 'state', 'pinned-guards.sha')
  const changedPins = readFileSync(pinFile, 'utf8').trim().split('\n').map(line => `${'1'.repeat(40)} ${line.split(' ')[1]}`).join('\n')
  writeFileSync(pinFile, `${changedPins}\n`)

  const script = `
    import { loadGuardPins } from ${JSON.stringify(path.join(dir, 'scripts', 'sm.mjs'))}
    import { runSelfTest, validateAuditPacket } from ${JSON.stringify(path.join(dir, 'scripts', 'tests', 'audit-packet.mjs'))}
    const pins = loadGuardPins()
    const packet = {
      ...JSON.parse(${JSON.stringify(readFileSync(path.join(dir, 'scripts', 'tests', 'fixtures', 'audit-packet', 'valid.json'), 'utf8'))}),
      pinned_guard_blobs: { ...pins },
      observed_guard_blobs: { ...pins },
    }
    const cases = runSelfTest({ logger: () => {} })
    const drift = structuredClone(packet)
    drift.observed_guard_blobs[Object.keys(drift.observed_guard_blobs).sort()[0]] = '0'.repeat(40)
    console.log(JSON.stringify({ codes: cases.map(item => item.code), drift: validateAuditPacket(drift) }))
  `
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], { cwd: dir, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  const observed = JSON.parse(result.stdout.trim())
  assert.deepEqual(observed.codes, [0, 2, 2, 3, 4, 5, 5, 6], result.stdout)
  assert.equal(observed.drift.code, 4, result.stdout)
  assert.match(observed.drift.diagnostic, /GUARD_DRIFT/)
})

test('a trust-anchor commit is never skipped as state bookkeeping (F14)', (t) => {
  const { dir, git, ok } = makeHistoryRepo(t)
  assert.equal(git(['update-index', '--chmod=+x', 'state/pinned-guards.sha']).status, 0)
  ok(['commit', '-q', '-m', 'touch trust anchor'])
  assert.match(git(['diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD']).stdout, /state\/pinned-guards\.sha/)

  const audit = spawnSync(process.execPath, [path.join(dir, 'scripts', 'sm.mjs'), 'audit'], { cwd: dir, encoding: 'utf8' })
  assert.equal(audit.status, 5, audit.stderr)
  assert.match(audit.stderr, /HEAD_DRIFT/)
})

test('a merge commit at HEAD is never treated as a transparent seal (F14)', (t) => {
  const { dir, ok } = makeHistoryRepo(t)
  ok(['checkout', '-q', '-b', 'side'])
  writeFileSync(path.join(dir, 'side.txt'), 'side\n')
  ok(['add', 'side.txt'])
  ok(['commit', '-q', '-m', 'side'])
  ok(['checkout', '-q', '-'])
  ok(['merge', '--no-ff', '-q', '-m', 'merge side', 'side'])

  const audit = spawnSync(process.execPath, [path.join(dir, 'scripts', 'sm.mjs'), 'audit'], { cwd: dir, encoding: 'utf8' })
  assert.equal(audit.status, 5, audit.stderr)
  assert.match(audit.stderr, /HEAD_DRIFT/)
})

test('AUDIT_TARGET_SHA cannot bless a single-parent code drift', (t) => {
  const { dir, ok, featureSha } = makeHistoryRepo(t)
  writeFileSync(path.join(dir, 'drift.js'), 'export {}\n')
  ok(['add', 'drift.js'])
  ok(['commit', '-q', '-m', 'code drift'])

  const env = { ...process.env, AUDIT_TARGET_SHA: featureSha }
  const run = (script, args) => spawnSync(process.execPath, [path.join(dir, 'scripts', script), ...args], { cwd: dir, encoding: 'utf8', env })
  const sm = run('sm.mjs', ['audit'])
  assert.equal(sm.status, 5, sm.stderr)
  assert.match(sm.stderr, /HEAD_DRIFT/)

  const packetPath = path.join(dir, 'packet.json')
  writeFileSync(packetPath, requireFixture('valid.json'))
  const packet = run('tests/audit-packet.mjs', ['--packet', packetPath])
  assert.equal(packet.status, 5, packet.stderr)
  assert.match(packet.stderr, /\[LIVE\] exit 5 HEAD_DRIFT/)
})

test('AUDIT_TARGET_SHA only applies to a merge whose parent is the PR head', (t) => {
  const valid = makeHistoryRepo(t)
  const stateNames = ['events.ndjson', 'bindings.json', 'index.json', 'SUMMARY.md', 'current_wave.json', 'pinned-guards.sha']
  const stateBytes = stateNames.map(name => [name, readFileSync(path.join(valid.dir, 'state', name))])
  valid.ok(['checkout', '-q', '-b', 'side', valid.featureSha])
  writeFileSync(path.join(valid.dir, 'side.txt'), 'side\n')
  valid.ok(['add', 'side.txt'])
  valid.ok(['commit', '-q', '-m', 'side'])
  valid.ok(['checkout', '-q', valid.featureSha])
  valid.ok(['merge', '--no-ff', '-q', '-m', 'merge side', 'side'])
  for (const [name, bytes] of stateBytes)
    writeFileSync(path.join(valid.dir, 'state', name), bytes)
  assert.ok(valid.ok(['rev-list', '--parents', '-n', '1', 'HEAD']).split(' ').slice(1).includes(valid.featureSha))
  const green = spawnSync(process.execPath, [path.join(valid.dir, 'scripts', 'sm.mjs'), 'audit'], {
    cwd: valid.dir,
    encoding: 'utf8',
    env: { ...process.env, AUDIT_TARGET_SHA: valid.featureSha },
  })
  assert.equal(green.status, 0, green.stderr)

  const invalid = makeHistoryRepo(t)
  invalid.ok(['checkout', '-q', '-b', 'side'])
  writeFileSync(path.join(invalid.dir, 'side.txt'), 'side\n')
  invalid.ok(['add', 'side.txt'])
  invalid.ok(['commit', '-q', '-m', 'side'])
  invalid.ok(['checkout', '-q', '-'])
  invalid.ok(['merge', '--no-ff', '-q', '-m', 'merge side', 'side'])
  assert.ok(!invalid.ok(['rev-list', '--parents', '-n', '1', 'HEAD']).split(' ').slice(1).includes(invalid.featureSha))
  const red = spawnSync(process.execPath, [path.join(invalid.dir, 'scripts', 'sm.mjs'), 'audit'], {
    cwd: invalid.dir,
    encoding: 'utf8',
    env: { ...process.env, AUDIT_TARGET_SHA: invalid.featureSha },
  })
  assert.equal(red.status, 5, red.stderr)
  assert.match(red.stderr, /HEAD_DRIFT/)
})

test('the pure core ignores AUDIT_TARGET_SHA', () => {
  const previous = process.env.AUDIT_TARGET_SHA
  process.env.AUDIT_TARGET_SHA = 'f'.repeat(40)
  try {
    assert.deepEqual(verifyStateSnapshot(structuredClone(baseline)), { code: 0, diagnostic: 'OK' })
  }
  finally {
    if (previous === undefined)
      delete process.env.AUDIT_TARGET_SHA
    else
      process.env.AUDIT_TARGET_SHA = previous
  }
})

function requireFixture(name) {
  return readFileSync(path.join(__dirname, 'fixtures', 'audit-packet', name), 'utf8')
}
