import assert from 'node:assert/strict'
// eslint-disable-next-line test/no-import-node-test -- this is a node test file
import test from 'node:test'

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, lstatSync, readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import { gitBlobHash, reportDigest } from './mutate-guard.mjs'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = resolve(SCRIPT_DIR, '../..')
const HARNESS = join(SCRIPT_DIR, 'mutate-guard.mjs')
const GRAPH_GUARD = join(REPO_ROOT, 'scripts/tests/flutter_boundary_graph.mjs')
const BOUNDARY_GUARD = join(REPO_ROOT, 'scripts/tests/flutter-boundary.test.mjs')
const LIB_ROOT = join(REPO_ROOT, 'apps/flutter/lib')
const RESOLUTION = join(REPO_ROOT, '.wave0/lane-airi-4iag/senior-dev-resolution.md')

const GRAPH_BLOB = 'f87d8b2f0b3f95462b0fac26abd765b28b01d567'
const BOUNDARY_BLOB = '935ca73c9aef67da4d11bd5df60392a23fd400ea'
const GRAPH_BLOB_PATH = 'scripts/tests/flutter_boundary_graph.mjs'
const BOUNDARY_BLOB_PATH = 'scripts/tests/flutter-boundary.test.mjs'

function runHarness(args = []) {
  return spawnSync(process.execPath, [HARNESS, ...args], { encoding: 'utf8' })
}

function git(args) {
  const result = spawnSync('git', args, { cwd: REPO_ROOT, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trim()
}

function snapshotLib() {
  const entries = []
  function walk(dir) {
    for (const name of readdirSync(dir).sort()) {
      const abs = join(dir, name)
      const stat = lstatSync(abs)
      const rel = relative(LIB_ROOT, abs).split('\\').join('/')
      entries.push(`${rel}:${stat.isDirectory() ? 'dir' : stat.size}:${stat.mtimeMs}`)
      if (stat.isDirectory())
        walk(abs)
    }
  }
  walk(LIB_ROOT)
  return entries
}

const guardBlobsBefore = {
  [GRAPH_BLOB_PATH]: gitBlobHash(readFileSync(GRAPH_GUARD)),
  [BOUNDARY_BLOB_PATH]: gitBlobHash(readFileSync(BOUNDARY_GUARD)),
}
const libBefore = snapshotLib()

test('two runs: byte-identical JSON, one line, stderr empty, canonical digest verifies and a tamper breaks it', () => {
  const first = runHarness()
  const second = runHarness()
  assert.equal(first.status, 0, first.stderr)
  assert.equal(second.status, 0, second.stderr)
  assert.equal(first.stderr, '')
  assert.equal(second.stderr, '')
  assert.equal(first.stdout, second.stdout)
  assert.ok(first.stdout.endsWith('\n'))
  assert.equal(first.stdout.split('\n').length, 2, 'stdout must be exactly one JSON line')

  const report = JSON.parse(first.stdout)
  assert.equal(reportDigest(report), report.mutation_proof.report_sha256)
  const tampered = JSON.parse(first.stdout)
  tampered.cases[0].fault_class = `${tampered.cases[0].fault_class}-tampered`
  assert.notEqual(reportDigest(tampered), report.mutation_proof.report_sha256)
})

test('5/5 mutants killed by real non-zero exits, 0 false positives, 5 fault classes, green control', () => {
  const result = runHarness()
  assert.equal(result.status, 0, result.stderr)
  const report = JSON.parse(result.stdout)
  const proof = report.mutation_proof
  const mutants = report.cases.filter(testCase => !testCase.control)
  const control = report.cases.find(testCase => testCase.control)

  assert.equal(proof.mutants_total, 5)
  assert.equal(proof.mutants_killed, 5)
  assert.ok(proof.non_zero_exit_kills >= 5)
  assert.equal(proof.false_positives, 0)
  assert.equal(proof.distinct_fault_classes, 5)
  assert.equal(new Set(mutants.map(testCase => testCase.fault_class)).size, 5)
  assert.equal(control.killed, 0)
  assert.ok(control.guards.every(guard => guard.exit_code === 0 && guard.killed === false))
  assert.ok(mutants.every(testCase => testCase.killed >= 1))
  for (const testCase of report.cases) {
    for (const guard of testCase.guards) {
      if (guard.killed)
        assert.ok(guard.exit_code > 0, `${testCase.id}/${guard.guard} killed without a non-zero exit`)
      assert.ok(guard.stderr_snippet.length > 0, `${testCase.id}/${guard.guard} empty stderr_snippet`)
      assert.ok(!guard.stderr_snippet.includes('/tmp/'), guard.stderr_snippet)
      assert.ok(!guard.stderr_snippet.includes('/home/vi/'), guard.stderr_snippet)
    }
  }
  assert.deepEqual(report.cases.map(testCase => testCase.id), [...report.cases.map(testCase => testCase.id)].sort())
  assert.equal(report.proof_tier, 'MUTATION_PROVEN')
  assert.equal(proof.status, 'GREEN')
  assert.equal(proof.prior_tier, 'WIRED_NOT_MUTATION_PROVEN')
  assert.equal(proof.prior_status, 'PENDING_L3_HARNESS')
  assert.equal(proof.prior_harness_sha, null)
})

test('SHA binds harness, real guard blobs, introducing commit anchors and advisor resolution', () => {
  const result = runHarness()
  assert.equal(result.status, 0, result.stderr)
  const proof = JSON.parse(result.stdout).mutation_proof

  assert.equal(proof.harness_sha, gitBlobHash(readFileSync(HARNESS)))
  assert.deepEqual(proof.guard_blobs, guardBlobsBefore)

  // NOTICE: the brief's 9b2e61c6 / 10d151e8 prefixes are the introducing
  // COMMIT ids, not git-blob ids. Bind the actual blobs and verify the commit
  // anchors separately: this is stricter than asserting the wrong blob prefix.
  const graphCommit = git(['rev-parse', '9b2e61c6^{commit}'])
  const boundaryCommit = git(['rev-parse', '10d151e8^{commit}'])
  assert.match(graphCommit, /^9b2e61c6/)
  assert.match(boundaryCommit, /^10d151e8/)
  // Both guards were amended after introduction; bind the working-tree blobs.
  assert.notEqual(git(['rev-parse', `${graphCommit}:${GRAPH_BLOB_PATH}`]), GRAPH_BLOB)
  assert.equal(git(['hash-object', GRAPH_BLOB_PATH]), GRAPH_BLOB)
  assert.equal(git(['rev-parse', `HEAD:${BOUNDARY_BLOB_PATH}`]), BOUNDARY_BLOB)
  assert.equal(git(['hash-object', BOUNDARY_BLOB_PATH]), BOUNDARY_BLOB)
  assert.equal(proof.guard_blobs[GRAPH_BLOB_PATH], GRAPH_BLOB)
  assert.equal(proof.guard_blobs[BOUNDARY_BLOB_PATH], BOUNDARY_BLOB)

  const advisorSha = createHash('sha256').update(readFileSync(RESOLUTION)).digest('hex')
  assert.match(proof.advisor_resolution_sha256, /^3593b349/)
  assert.equal(proof.advisor_resolution_sha256, advisorSha)
})

test('survivor self-test emits the exact failure line and exits 1 without claiming MUTATION_PROVEN', () => {
  const result = runHarness(['--self-test-survivor'])
  assert.equal(result.status, 1)
  assert.equal(result.stdout, '')
  assert.match(
    result.stderr,
    /^\[MUTATION_SURVIVED\] conditional-dart-library-io killed 0\/2 — green blocked$/m,
  )
  assert.ok(!result.stderr.includes('MUTATION_PROVEN'))
})

test('guards and the live Flutter lib tree are untouched', () => {
  assert.ok(existsSync(LIB_ROOT))
  assert.deepEqual(guardBlobsBefore, {
    [GRAPH_BLOB_PATH]: gitBlobHash(readFileSync(GRAPH_GUARD)),
    [BOUNDARY_BLOB_PATH]: gitBlobHash(readFileSync(BOUNDARY_GUARD)),
  })
  assert.deepEqual(snapshotLib(), libBefore)
})
