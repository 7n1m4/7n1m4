#!/usr/bin/env node
// Mutation harness for the two Flutter thin-client boundary guards.
// Every case is materialized into a fresh detached temp root, both guards are
// invoked as real child processes, and the temp root is removed in `finally`.
import process from 'node:process'

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(SCRIPT_DIR, '../..')
const FIXTURES_DIR = join(SCRIPT_DIR, 'fixtures/mutations')
const MANIFEST = join(FIXTURES_DIR, 'manifest.json')
const GUARD_GRAPH = join(SCRIPT_DIR, 'flutter_boundary_graph.mjs')
const GUARD_BOUNDARY = join(SCRIPT_DIR, 'flutter-boundary.test.mjs')
const RESOLUTION = join(SCRIPT_DIR, '../../.wave0/lane-airi-4iag/senior-dev-resolution.md')

const GUARD_GRAPH_REL = 'flutter_boundary_graph.mjs'
const GUARD_BOUNDARY_REL = 'flutter-boundary.test.mjs'
const GUARD_GRAPH_BLOB_PATH = 'scripts/tests/flutter_boundary_graph.mjs'
const GUARD_BOUNDARY_BLOB_PATH = 'scripts/tests/flutter-boundary.test.mjs'
const ADVISOR_SHA256_PREFIX = '3593b349'

// NOTICE: 9b2e61c6 and 10d151e8 (coordinator brief) are the COMMIT SHAs that
// introduced each guard, not git-blob SHAs. Both guards were amended after
// those commits (L1's graph-guard fix changed its blob again). Pin the real
// in-tree blobs: the runtime re-hash uses git-blob SHA-1 and can only ever
// match these values.
const PINNED_GUARD_BLOBS = Object.freeze({
  [GUARD_GRAPH_BLOB_PATH]: 'f87d8b2f0b3f95462b0fac26abd765b28b01d567',
  [GUARD_BOUNDARY_BLOB_PATH]: '935ca73c9aef67da4d11bd5df60392a23fd400ea',
})

const PRIOR_TIER = 'WIRED_NOT_MUTATION_PROVEN'
const PRIOR_STATUS = 'PENDING_L3_HARNESS'
const DETACHED_ROOT = '<DETACHED_ROOT>'
const TMP_BASE = existsSync('/tmp/opencode') ? '/tmp/opencode' : tmpdir()
const VIRTUAL_FILE_RE = /^\s*\/\/ === VIRTUAL_FILE: (\S+) ===\s*$/
const FINDINGS_MARKER = 'MUTATE_GUARD_FINDINGS:'

// The round-14 guard registers 25 node:test cases on import; in a plain child
// process those cases also print TAP to stdout. The findings line is written
// synchronously before the deferred tests run, so it is always the first line
// and is located by its unique marker.
const BOUNDARY_PROBE = [
  `import { scanFlutterLib } from ${JSON.stringify(pathToFileURL(GUARD_BOUNDARY).href)}`,
  'const findings = scanFlutterLib(process.argv[1])',
  `process.stdout.write(${JSON.stringify(FINDINGS_MARKER)} + JSON.stringify(findings) + '\\n')`,
  'process.exitCode = findings.length > 0 ? 1 : 0',
  '',
].join('\n')

// --- canonical, deterministic serialization ---

// Object keys are sorted; arrays stay in their declared order (cases by id,
// guards by guard name). No timestamps, no absolute paths, LF endings only.
export function canonicalize(value) {
  if (value === null || typeof value !== 'object')
    return JSON.stringify(value)
  if (Array.isArray(value))
    return `[${value.map(canonicalize).join(',')}]`
  return `{${Object.keys(value).sort().map(key => `${JSON.stringify(key)}:${canonicalize(value[key])}`).join(',')}}`
}

export function deepFreeze(value) {
  if (value && typeof value === 'object' && !Object.isFrozen(value)) {
    for (const child of Object.values(value))
      deepFreeze(child)
    Object.freeze(value)
  }
  return value
}

export function gitBlobHash(content) {
  const bytes = Buffer.isBuffer(content) ? content : Buffer.from(content, 'utf8')
  return createHash('sha1').update(Buffer.from(`blob ${bytes.length}\0`, 'utf8')).update(bytes).digest('hex')
}

export function reportDigest(report) {
  const { mutation_proof, ...rest } = report
  const { report_sha256, ...proof } = mutation_proof
  return createHash('sha256').update(canonicalize({ ...rest, mutation_proof: proof }), 'utf8').digest('hex')
}

// --- fixture materialization ---

function validateVirtualPath(rel) {
  if (rel.includes('..') || rel.includes('\\') || posix.isAbsolute(rel))
    throw new Error(`unsafe virtual path: ${rel}`)
  return rel
}

export function materializeFixture(source) {
  const virtualFiles = new Map()
  let current = null
  const lines = []
  for (const line of source.split(/\r?\n/)) {
    const marker = line.match(VIRTUAL_FILE_RE)
    if (marker) {
      if (current)
        virtualFiles.set(current, lines.join('\n'))
      current = validateVirtualPath(marker[1])
      lines.length = 0
      continue
    }
    if (!current)
      continue
    const stripped = line.replace(/^\s*\/\/\s?/, '')
    if (stripped === line && line.trim() !== '')
      continue
    lines.push(stripped)
  }
  if (current)
    virtualFiles.set(current, lines.join('\n'))
  return virtualFiles
}

function locateTarget(content, needle) {
  const index = content.indexOf(needle)
  if (index === -1)
    throw new Error(`target needle not found in materialized file: ${needle}`)
  const prefix = content.slice(0, index)
  const lastNewline = prefix.lastIndexOf('\n')
  return { line: prefix.split('\n').length, col: index - lastNewline }
}

function normalizeText(text, root) {
  return String(text ?? '')
    .split(root).join(DETACHED_ROOT)
    .replace(/\/tmp\/[^\s'"\n]+/g, '<TMP_PATH>')
    .replace(/\/home\/[^\s'"\n]+/g, '<HOME_PATH>')
    .replace(/\r/g, '')
    .split('\n').map(line => line.trimEnd()).join('\n')
    .replace(/^\n+|\n+$/g, '')
}

function loadManifest() {
  const manifest = JSON.parse(readFileSync(MANIFEST, 'utf8'))
  if (manifest.schema_version !== 1 || !Array.isArray(manifest.cases) || manifest.cases.length !== 6)
    throw new Error('mutation manifest schema drift')
  return manifest
}

// --- real guard invocation ---

function runGuards(root) {
  const graph = spawnSync(process.execPath, [GUARD_GRAPH, '--root', root], { encoding: 'utf8' })
  const boundary = spawnSync(
    process.execPath,
    ['--input-type=module', '-e', BOUNDARY_PROBE, join(root, 'apps/flutter/lib')],
    { encoding: 'utf8' },
  )
  const findingsLine = String(boundary.stdout ?? '').split('\n').find(line => line.startsWith(FINDINGS_MARKER))
  let findings = []
  if (findingsLine) {
    try {
      findings = JSON.parse(findingsLine.slice(FINDINGS_MARKER.length))
    }
    catch {
      findings = []
    }
  }
  return new Map([
    [GUARD_BOUNDARY_REL, { exit_code: boundary.status ?? -1, findings, stderr: boundary.stderr ?? '', stdout: boundary.stdout ?? '' }],
    [GUARD_GRAPH_REL, { exit_code: graph.status ?? -1, findings: [], stderr: graph.stderr ?? '', stdout: graph.stdout ?? '' }],
  ])
}

function stubRunner() {
  return new Map([
    [GUARD_BOUNDARY_REL, { exit_code: 0, findings: [], stderr: '', stdout: '' }],
    [GUARD_GRAPH_REL, { exit_code: 0, findings: [], stderr: '', stdout: '' }],
  ])
}

// Exported so the gate test can exercise the survivor branch with a stub
// runner returning zero kills, without disabling any real guard.
export function evaluateCase(spec, virtualFiles, runner = runGuards) {
  const root = mkdtempSync(join(TMP_BASE, 'mutate-guard-'))
  try {
    for (const rel of [...virtualFiles.keys()].sort()) {
      validateVirtualPath(rel)
      const abs = join(root, ...rel.split('/'))
      mkdirSync(dirname(abs), { recursive: true })
      writeFileSync(abs, virtualFiles.get(rel), 'utf8')
    }
    const body = virtualFiles.get(spec.target.file)
    if (body === undefined)
      throw new Error(`manifest target file missing: ${spec.target.file}`)
    const computed = locateTarget(body, spec.target.needle)
    if (computed.line !== spec.target.line || computed.col !== spec.target.col) {
      throw new Error(
        `target drift in ${spec.id}: declared ${spec.target.line}:${spec.target.col}, computed ${computed.line}:${computed.col}`,
      )
    }

    const raw = runner(root)
    const mismatches = []
    const guards = spec.guards.map((expected) => {
      const actual = raw.get(expected.guard) ?? { exit_code: -1, findings: [], stderr: '', stdout: '' }
      const snippet = expected.guard === GUARD_BOUNDARY_REL
        ? actual.findings.length
          ? actual.findings.slice(0, 3).map(f => `[${f.rule}] ${f.detail}`).join(' | ')
          : '<no findings>'
        : normalizeText(actual.stderr, root) || '<no findings>'
      const exitOk = actual.exit_code === expected.expected_exit_code
      const substringOk = expected.expected_stderr_substring === null
        || snippet.includes(expected.expected_stderr_substring)
        || normalizeText(actual.stdout, root).includes(expected.expected_stderr_substring)
      if (!exitOk || !substringOk) {
        mismatches.push(
          `[GUARD_EXPECTATION_DRIFT] ${spec.id}/${expected.guard}: expected exit ${expected.expected_exit_code}, got ${actual.exit_code}; expected substring ${JSON.stringify(expected.expected_stderr_substring)}`,
        )
      }
      const killed = exitOk && substringOk && expected.should_kill && actual.exit_code > 0
      return deepFreeze({ guard: expected.guard, exit_code: actual.exit_code, stderr_snippet: snippet, killed })
    })

    const result = {
      mutant_id: spec.id,
      id: spec.id,
      control: spec.control,
      fault_class: spec.fault_class,
      operator: spec.operator,
      target: computed,
      killed: guards.filter(guard => guard.killed).length,
      guards,
    }
    Object.defineProperty(result, 'mismatches', { value: mismatches, enumerable: false })
    return deepFreeze(result)
  }
  finally {
    rmSync(root, { recursive: true, force: true })
  }
}

// --- maturity state machine ---

export function survivorLine(id) {
  return `[MUTATION_SURVIVED] ${id} killed 0/2 — green blocked`
}

function buildReport(cases, hashes, shaReasons) {
  const mutants = cases.filter(testCase => !testCase.control)
  const control = cases.find(testCase => testCase.control)
  const mutantsKilled = mutants.filter(testCase => testCase.killed >= 1).length
  const nonZeroExitKills = cases.reduce(
    (count, testCase) => count + testCase.guards.filter(guard => guard.killed && guard.exit_code > 0).length,
    0,
  )
  const falsePositives = control ? control.guards.filter(guard => guard.killed || guard.exit_code > 0).length : -1
  const distinctFaultClasses = new Set(mutants.map(testCase => testCase.fault_class)).size

  const reasons = [...shaReasons]
  for (const testCase of mutants) {
    if (testCase.killed === 0)
      reasons.push(survivorLine(testCase.id))
  }
  for (const testCase of cases) {
    for (const mismatch of testCase.mismatches ?? [])
      reasons.push(mismatch)
  }
  if (!control)
    reasons.push('[MUTATION_REASON] control case missing')
  if (falsePositives > 0)
    reasons.push(`[MUTATION_REASON] control produced ${falsePositives} false positives`)
  if (mutantsKilled !== 5)
    reasons.push(`[MUTATION_REASON] mutants killed ${mutantsKilled}/5`)
  if (nonZeroExitKills < 5)
    reasons.push(`[MUTATION_REASON] non-zero exit kills ${nonZeroExitKills}/5`)
  if (distinctFaultClasses !== 5)
    reasons.push(`[MUTATION_REASON] distinct fault classes ${distinctFaultClasses}/5`)
  if (cases.length !== 6 || mutants.length !== 5)
    reasons.push(`[MUTATION_REASON] case count ${cases.length}, mutants ${mutants.length}`)
  if (!/^[0-9a-f]{40}$/.test(hashes.harnessSha))
    reasons.push('[MUTATION_REASON] harness SHA not bound')

  const green = reasons.length === 0
  const proof = {
    status: green ? 'GREEN' : 'FAILED',
    prior_tier: PRIOR_TIER,
    prior_status: PRIOR_STATUS,
    prior_harness_sha: null,
    harness_sha: hashes.harnessSha,
    guard_blobs: Object.freeze({ ...hashes.guardBlobs }),
    advisor_resolution_sha256: hashes.advisorSha,
    mutants_total: 5,
    mutants_killed: mutantsKilled,
    non_zero_exit_kills: nonZeroExitKills,
    false_positives: falsePositives,
    distinct_fault_classes: distinctFaultClasses,
    report_sha256: '',
  }
  const draft = { schema_version: 1, proof_tier: green ? 'MUTATION_PROVEN' : PRIOR_TIER, mutation_proof: proof, cases }
  proof.report_sha256 = reportDigest(draft)
  const report = { ...draft, mutation_proof: proof }
  if (!green)
    report.reason = reasons.join(' | ')
  return { report: deepFreeze(report), reasons, green }
}

function selfTestSurvivor() {
  const spec = loadManifest().cases.find(testCase => !testCase.control)
  const virtualFiles = materializeFixture(readFileSync(join(FIXTURES_DIR, spec.fixture), 'utf8'))
  const result = evaluateCase(spec, virtualFiles, stubRunner)
  const line = survivorLine(spec.id)
  if (result.killed !== 0) {
    process.stderr.write('[SELF_TEST_SURVIVOR_FAIL] stub runner was expected to return 0 kills\n')
    return 1
  }
  process.stderr.write(`${line}\n`)
  process.stderr.write('[SELF_TEST_SURVIVOR_OK] stub runner returned 0 kills\n')
  return 1
}

function main(argv) {
  if (argv.includes('--self-test-survivor'))
    return selfTestSurvivor()

  const reportArg = argv.find(arg => arg.startsWith('--report='))
  const shaReasons = []
  const harnessSha = gitBlobHash(readFileSync(fileURLToPath(import.meta.url)))
  const guardBlobs = {}
  for (const [rel, pinned] of Object.entries(PINNED_GUARD_BLOBS)) {
    const actual = gitBlobHash(readFileSync(join(REPO_ROOT, rel)))
    guardBlobs[rel] = actual
    if (actual !== pinned) {
      process.stderr.write(`[SHA_DRIFT] ${rel} expected ${pinned} got ${actual}\n`)
      shaReasons.push(`[SHA_DRIFT] ${rel} expected ${pinned} got ${actual}`)
    }
  }
  const advisorSha = createHash('sha256').update(readFileSync(RESOLUTION)).digest('hex')
  if (!advisorSha.startsWith(ADVISOR_SHA256_PREFIX)) {
    const line = `[SHA_DRIFT] advisor_resolution_sha256 expected prefix ${ADVISOR_SHA256_PREFIX} got ${advisorSha}`
    process.stderr.write(`${line}\n`)
    shaReasons.push(line)
  }

  const manifest = loadManifest()
  const cases = manifest.cases
    .map((spec) => {
      const virtualFiles = materializeFixture(readFileSync(join(FIXTURES_DIR, spec.fixture), 'utf8'))
      return evaluateCase(spec, virtualFiles, runGuards)
    })
    .sort((a, b) => (a.id < b.id ? -1 : a.id > b.id ? 1 : 0))

  const { report, reasons, green } = buildReport(cases, { harnessSha, guardBlobs, advisorSha }, shaReasons)
  const output = `${canonicalize(report)}\n`
  process.stdout.write(output)
  if (reportArg)
    writeFileSync(reportArg.slice('--report='.length), output, 'utf8')
  for (const reason of reasons)
    process.stderr.write(`${reason}\n`)
  return green ? 0 : 1
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  process.exitCode = main(process.argv.slice(2))
