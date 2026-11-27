import assert from 'node:assert/strict'
import path from 'node:path'
// eslint-disable-next-line test/no-import-node-test -- this is a node test file
import test from 'node:test'

import { spawnSync } from 'node:child_process'
import { cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

import { BASE_SHA, deriveHead, loadGuardPins } from '../sm.mjs'
import { runSelfTest, validateAuditPacket } from './audit-packet.mjs'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(__dirname, '..', '..')
const TEMP_BASE = '/tmp/opencode'
const fixtureDir = path.join(__dirname, 'fixtures', 'audit-packet')
const pins = loadGuardPins()

function fixture(name) {
  const packet = JSON.parse(readFileSync(path.join(fixtureDir, name), 'utf8'))
  // Keep the snapshot's guard blobs tied to the authoritative pin file; the
  // code4() mutation below still injects a mismatch to prove fail-closed.
  return {
    ...packet,
    pinned_guard_blobs: { ...pins },
    observed_guard_blobs: { ...pins },
  }
}

function runCli(dir) {
  return spawnSync(process.execPath, [path.join(dir, 'scripts', 'tests', 'audit-packet.mjs')], { cwd: dir, encoding: 'utf8' })
}

function runNode(dir, script, args = []) {
  return spawnSync(process.execPath, [script, ...args], { cwd: dir, encoding: 'utf8' })
}

/**
 * Throwaway repo with a real git index holding the four pinned guard blobs.
 * HEAD follows the copied event log unless a test rebuilds it from scratch.
 */
function makeRepo(t, { headSha } = {}) {
  mkdirSync(TEMP_BASE, { recursive: true })
  const dir = mkdtempSync(path.join(TEMP_BASE, 'r17-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const rel of ['scripts', 'state', '.wave0'])
    cpSync(path.join(repoRoot, rel), path.join(dir, rel), { recursive: true })

  const copiedEvents = readFileSync(path.join(dir, 'state', 'events.ndjson'), 'utf8')
    .split('\n')
    .filter(Boolean)
    .map(line => JSON.parse(line))
  const effectiveHead = headSha ?? deriveHead(copiedEvents)
  const gitDir = path.join(dir, '.git')
  mkdirSync(path.join(gitDir, 'objects'), { recursive: true })
  mkdirSync(path.join(gitDir, 'refs', 'heads'), { recursive: true })
  writeFileSync(path.join(gitDir, 'HEAD'), `${effectiveHead}\n`)
  writeFileSync(path.join(gitDir, 'config'), '[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n')
  for (const sha of Object.values(pins)) {
    const rel = path.join('.git', 'objects', sha.slice(0, 2), sha.slice(2))
    mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true })
    cpSync(path.join(repoRoot, rel), path.join(dir, rel))
  }
  const git = args => spawnSync('git', args, {
    cwd: dir,
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
  })
  for (const [relPath, sha] of Object.entries(pins)) {
    assert.equal(git(['update-index', '--add', '--cacheinfo', `100644,${sha},${relPath}`]).status, 0)
  }
  return { dir, git, effectiveHead }
}

/**
 * Real git repo with an actual commit ancestry, unlike makeRepo's raw HEAD
 * pointer: genesis -> feature commit -> head:advance -> state-only commit.
 */
function makeGitRepo(t) {
  mkdirSync(TEMP_BASE, { recursive: true })
  const dir = mkdtempSync(path.join(TEMP_BASE, 'r17-head-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))
  for (const rel of ['scripts', 'state', '.wave0'])
    cpSync(path.join(repoRoot, rel), path.join(dir, rel), { recursive: true })

  const git = args => spawnSync('git', args, {
    cwd: dir,
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C', GIT_AUTHOR_NAME: 'SM Test', GIT_AUTHOR_EMAIL: 'sm@example.invalid', GIT_COMMITTER_NAME: 'SM Test', GIT_COMMITTER_EMAIL: 'sm@example.invalid' },
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

  const advanced = runNode(dir, path.join(dir, 'scripts', 'sm.mjs'), ['head:advance', '--sha', featureSha])
  assert.equal(advanced.status, 0, advanced.stderr)
  ok(['add', 'state'])
  ok(['commit', '-q', '-m', 'state'])
  const stateSha = ok(['rev-parse', 'HEAD'])
  assert.notEqual(stateSha, featureSha)
  return { dir, git, ok, featureSha, stateSha }
}

function mutateJson(file, mutate) {
  const value = JSON.parse(readFileSync(file, 'utf8'))
  mutate(value)
  writeFileSync(file, `${JSON.stringify(value, null, 2)}\n`)
}

function mutateEvent(dir, index, mutate) {
  const file = path.join(dir, 'state', 'events.ndjson')
  const lines = readFileSync(file, 'utf8').split('\n').filter(Boolean)
  const event = JSON.parse(lines[index])
  mutate(event)
  lines[index] = JSON.stringify(event)
  writeFileSync(file, `${lines.join('\n')}\n`)
}

test('self-test covers all six exit codes and every case matches its expectation', () => {
  const cases = runSelfTest({ logger: () => {} })
  assert.deepEqual([...new Set(cases.map(testCase => testCase.expect))].sort(), [0, 2, 3, 4, 5, 6])
  assert.ok(cases.every(testCase => testCase.ok), JSON.stringify(cases.filter(testCase => !testCase.ok)))
  assert.equal(cases.length, 8)
})

test('known-good fixture passes', () => {
  assert.deepEqual(validateAuditPacket(fixture('valid.json')), { code: 0, diagnostic: 'OK' })
})

test('missing-invariant fixture fails closed with exit 2', () => {
  const result = validateAuditPacket(fixture('invalid-missing-invariant.json'))
  assert.equal(result.code, 2)
  assert.match(result.diagnostic, /SCHEMA_MISSING_genesis_count/)
})

test('placeholder fixture fails closed with exit 2', () => {
  const result = validateAuditPacket(fixture('invalid-placeholder.json'))
  assert.equal(result.code, 2)
  assert.match(result.diagnostic, /PLACEHOLDER_TOKEN:(?:\$\.)?base_sha/)
})

test('each failure class has its own exit code and distinct diagnostic', () => {
  const valid = fixture('valid.json')
  const expectations = [
    [code3(valid), 3, /UNKNOWNS_UNRESOLVED/],
    [code4(valid), 4, /GUARD_DRIFT/],
    [code5(valid), 5, /REPLAY_MISMATCH/],
    [code6(valid), 6, /LEASE_COLLISION/],
  ]
  const diagnostics = new Set()
  for (const [packet, expectedCode, pattern] of expectations) {
    const result = validateAuditPacket(packet)
    assert.equal(result.code, expectedCode, result.diagnostic)
    assert.match(result.diagnostic, pattern)
    assert.ok(!diagnostics.has(result.diagnostic), `duplicate diagnostic: ${result.diagnostic}`)
    diagnostics.add(result.diagnostic)
  }
  assert.equal(diagnostics.size, 4)
})

test('live packet is valid and self-test markers precede the live marker', (t) => {
  // The real checkout may be mid-integration; use a repo whose HEAD matches
  // its event log so this test checks the CLI, not unrelated head drift.
  const { dir } = makeRepo(t)
  const first = runCli(dir)
  assert.equal(first.status, 0, first.stderr)
  const lines = first.stderr.split('\n')
  const selfIndexes = lines.flatMap((line, index) => line.startsWith('[SELF_TEST]') ? [index] : [])
  const liveIndexes = lines.flatMap((line, index) => line.startsWith('[LIVE]') ? [index] : [])
  assert.equal(selfIndexes.length, 8)
  assert.equal(liveIndexes.length, 1)
  assert.ok(Math.max(...selfIndexes) < liveIndexes[0], 'self-test must run before live validation')

  const second = runCli(dir)
  assert.equal(second.status, 0, second.stderr)
  assert.equal(second.stderr, first.stderr, 'CLI output must be deterministic')
})

test('corrupted live state changes the CLI exit code (adversarial kills)', (t) => {
  const scenarios = [
    ['self-test order: unreadable fixture stops before live', (dir) => {
      rmSync(path.join(dir, 'scripts', 'tests', 'fixtures', 'audit-packet', 'valid.json'))
      return 2
    }, true],
    ['genesis unknowns -> exit 3', (dir) => {
      mutateEvent(dir, 0, (genesis) => {
        genesis.unknowns = ['airi-bdry']
      })
      return 3
    }, false],
    ['genesis seq tampering -> exit 2', (dir) => {
      mutateEvent(dir, 0, (genesis) => {
        genesis.seq = 99
      })
      return 2
    }, false],
    ['prev_hash break -> exit 5', (dir) => {
      const file = path.join(dir, 'state', 'events.ndjson')
      const lines = readFileSync(file, 'utf8').split('\n').filter(Boolean)
      lines.push(JSON.stringify({ seq: 2, type: 'head_advanced', prev_hash: 'f'.repeat(64), sha: BASE_SHA }))
      writeFileSync(file, `${lines.join('\n')}\n`)
      return 5
    }, false],
    ['lease alias -> exit 6', (dir) => {
      mutateJson(path.join(dir, 'state', 'bindings.json'), (bindings) => {
        bindings.lane_leases.S2.paths[0] = `./${bindings.lane_leases.S2.paths[0]}`
      })
      return 6
    }, false],
    ['extra schema field -> exit 2', (dir) => {
      mutateJson(path.join(dir, 'state', 'bindings.json'), (bindings) => {
        bindings._generated_at = 'now'
      })
      return 2
    }, false],
    ['git-index guard drift -> exit 4', (dir, git) => {
      assert.equal(git(['update-index', '--add', '--cacheinfo', `100644,${'1'.repeat(40)},scripts/tests/mutate-guard.mjs`]).status, 0)
      return 4
    }, false],
  ]

  for (const [name, mutate, noLive] of scenarios) {
    t.test(name, (st) => {
      const { dir, git } = makeRepo(st)
      const expected = mutate(dir, git)
      const result = runCli(dir)
      assert.equal(result.status, expected, `${name}: ${result.stderr}`)
      if (noLive)
        assert.ok(!result.stderr.includes('[LIVE]'), 'live validation ran after a broken self-test')
    })
  }
})

test('escaping symlink lease is rejected by both validators', (t) => {
  const { dir } = makeRepo(t)
  const outside = path.join(TEMP_BASE, 'outside-targets', path.basename(dir))
  mkdirSync(outside, { recursive: true })
  const parent = path.join(dir, 'scripts', 'tools')
  mkdirSync(parent, { recursive: true })
  symlinkSync(outside, path.join(parent, 'escape'))
  mutateJson(path.join(dir, 'state', 'bindings.json'), (bindings) => {
    bindings.lane_leases.S2.paths[0] = 'scripts/tools/escape'
  })

  const audit = runNode(dir, path.join(dir, 'scripts', 'sm.mjs'), ['audit'])
  assert.equal(audit.status, 6, audit.stderr)
  assert.match(audit.stderr, /outside_repo_realpath/)
  const packet = runCli(dir)
  assert.equal(packet.status, 6, packet.stderr)
  assert.match(packet.stderr, /LEASE_COLLISION/)
})

test('mid-wave unanchored receipt fails both validators consistently', (t) => {
  const { dir } = makeRepo(t)
  const extra = path.join(dir, '.wave0', 'lane-airi-new')
  mkdirSync(extra, { recursive: true })
  writeFileSync(path.join(extra, 'receipt.json'), `${JSON.stringify({ lane: 'airi-new' }, null, 2)}\n`)
  const sm = path.join(dir, 'scripts', 'sm.mjs')

  // recover surfaces the new receipt without regenerating the genesis.
  const recover = runNode(dir, sm, ['recover'])
  assert.equal(recover.status, 0, recover.stderr)
  const index = JSON.parse(readFileSync(path.join(dir, 'state', 'index.json'), 'utf8'))
  assert.equal(index.unanchored_receipts.length, 1)

  const audit = runNode(dir, sm, ['audit'])
  assert.equal(audit.status, 5, audit.stderr)
  assert.match(audit.stderr, /GENESIS_CONTENT_DRIFT/)
  const packet = runCli(dir)
  assert.equal(packet.status, 5, packet.stderr)
  assert.match(packet.stderr, /GENESIS_PROJECTION:GENESIS_CONTENT_DRIFT/)
})

test('head:advance appends a chained event and keeps every gate green', (t) => {
  const { dir } = makeRepo(t)
  const sm = path.join(dir, 'scripts', 'sm.mjs')
  const boot = path.join(dir, 'scripts', 'bootstrap-state.mjs')
  const before = readFileSync(path.join(dir, 'state', 'events.ndjson'), 'utf8').split('\n').filter(Boolean)
  const nextHead = 'a'.repeat(40)
  writeFileSync(path.join(dir, '.git', 'HEAD'), `${nextHead}\n`)
  const advanced = runNode(dir, sm, ['head:advance', '--sha', nextHead])
  assert.equal(advanced.status, 0, advanced.stderr)

  for (const [script, args] of [[sm, ['recover']], [sm, ['audit']], [boot, ['--dry-run']]]) {
    const result = runNode(dir, script, args)
    assert.equal(result.status, 0, `${script} ${args.join(' ')}: ${result.stderr}`)
  }
  assert.equal(runCli(dir).status, 0)

  const lines = readFileSync(path.join(dir, 'state', 'events.ndjson'), 'utf8').split('\n').filter(Boolean)
  assert.equal(lines.length, before.length + 1)
  assert.equal(JSON.parse(lines[0]).base_sha, BASE_SHA)
  const advancedEvent = JSON.parse(lines[lines.length - 1])
  assert.equal(advancedEvent.seq, before.length + 1)
  assert.equal(advancedEvent.type, 'head_advanced')
  assert.equal(JSON.parse(readFileSync(path.join(dir, 'state', 'current_wave.json'), 'utf8')).head_sha, nextHead)
})

test('both validators accept a state-only head and reject later code drift', (t) => {
  const { dir, ok, featureSha, stateSha } = makeGitRepo(t)
  const sm = path.join(dir, 'scripts', 'sm.mjs')

  const stateOnly = runNode(dir, sm, ['audit'])
  assert.equal(stateOnly.status, 0, `HEAD ${stateSha} (feature ${featureSha}): ${stateOnly.stderr}`)
  const stateOnlyPacket = runCli(dir)
  assert.equal(stateOnlyPacket.status, 0, stateOnlyPacket.stderr)

  // No changed paths is not state bookkeeping; an empty commit must fail too.
  ok(['commit', '-q', '--allow-empty', '-m', 'empty after state'])
  const emptyCommit = runNode(dir, sm, ['audit'])
  assert.equal(emptyCommit.status, 5, emptyCommit.stderr)
  assert.match(emptyCommit.stderr, /HEAD_DRIFT/)
  const emptyPacket = runCli(dir)
  assert.equal(emptyPacket.status, 5, emptyPacket.stderr)
  assert.match(emptyPacket.stderr, /head_mismatch/)

  writeFileSync(path.join(dir, 'code.js'), 'export {}\n')
  ok(['add', 'code.js'])
  ok(['commit', '-q', '-m', 'code after state'])
  const drifted = runNode(dir, sm, ['audit'])
  assert.equal(drifted.status, 5, drifted.stderr)
  assert.match(drifted.stderr, /HEAD_DRIFT/)
  const driftedPacket = runCli(dir)
  assert.equal(driftedPacket.status, 5, driftedPacket.stderr)
  assert.match(driftedPacket.stderr, /head_mismatch/)
})

test('unanchored wave0 receipts are ingested and surfaced, not dropped', (t) => {
  // The event log is rebuilt here, so its derived head goes back to BASE_SHA.
  const { dir } = makeRepo(t, { headSha: BASE_SHA })
  const extra = path.join(dir, '.wave0', 'lane-airi-extra')
  mkdirSync(extra, { recursive: true })
  writeFileSync(path.join(extra, 'receipt.json'), `${JSON.stringify({ lane: 'airi-extra' }, null, 2)}\n`)
  for (const name of ['events.ndjson', 'bindings.json', 'index.json', 'SUMMARY.md', 'current_wave.json']) {
    rmSync(path.join(dir, 'state', name), { force: true })
  }

  const boot = runNode(dir, path.join(dir, 'scripts', 'bootstrap-state.mjs'))
  assert.equal(boot.status, 0, boot.stderr)
  const index = JSON.parse(readFileSync(path.join(dir, 'state', 'index.json'), 'utf8'))
  assert.equal(index.unanchored_receipts.length, 1)
  assert.equal(index.unanchored_receipts[0].anchor_status, 'UNCOMMITTED_OR_ORPHAN')
  assert.equal(index.unanchored_receipts[0].commit_sha, null)
  assert.match(readFileSync(path.join(dir, 'state', 'SUMMARY.md'), 'utf8'), /NEEDS_RECONCILIATION/)
  assert.equal(runCli(dir).status, 0)
})

function code3(valid) {
  return { ...structuredClone(valid), unknowns: ['airi-bdry'], unknowns_from_genesis: ['airi-bdry'] }
}

function code4(valid) {
  const observed = { ...valid.observed_guard_blobs }
  observed[Object.keys(observed).sort()[0]] = '0'.repeat(40)
  return { ...structuredClone(valid), observed_guard_blobs: observed }
}

function code5(valid) {
  return { ...structuredClone(valid), replay_identical: false, replay_mismatches: ['events.ndjson:bytes'] }
}

function code6(valid) {
  return { ...structuredClone(valid), lease_collision: true, lease_collisions: ['state/events.ndjson:L0+S2'] }
}
