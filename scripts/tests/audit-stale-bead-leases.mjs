#!/usr/bin/env node

/**
 * AIRI stale in_progress Beads lease reporter.
 *
 * Reads the in_progress Beads list (or a JSON fixture) and reports leases whose
 * `lease_expires_at` has passed. This is a reporter, NOT a gate: stale leases
 * are printed with a non-zero-looking warning marker but still exit 0. Only an
 * unreadable data source (bd spawn failure, non-zero bd exit, bad JSON, or a
 * non-array top-level value) exits 1.
 *
 * The heartbeat timestamp is display context only; it never decides staleness.
 *
 * Usage:
 *   node scripts/tests/audit-stale-bead-leases.mjs
 *   node scripts/tests/audit-stale-bead-leases.mjs --fixture path/to/beads.json
 *   AIRI_BEAD_LEASE_FIXTURE=path/to/beads.json node scripts/tests/audit-stale-bead-leases.mjs
 *   node scripts/tests/audit-stale-bead-leases.mjs --self-test
 */

import assert from 'node:assert/strict'
import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '..', '..')
const BD_ARGS = ['--sandbox', 'list', '--status', 'in_progress', '--json']
const FIXTURE_ENV = 'AIRI_BEAD_LEASE_FIXTURE'

/** Parse an ISO-ish timestamp into a finite epoch ms value, or null. */
function parseTimestamp(value) {
  if (typeof value !== 'string' || value.trim() === '')
    return null
  const ms = Date.parse(value)
  return Number.isFinite(ms) ? ms : null
}

/** Pure stale-lease detector: only in_progress beads with an expired lease qualify. */
function findStaleLeases(beads, now) {
  if (!Array.isArray(beads))
    return []
  const nowMs = now.getTime()
  const findings = []
  for (const bead of beads) {
    if (!bead || typeof bead !== 'object' || bead.status !== 'in_progress')
      continue
    const expiresMs = parseTimestamp(bead.lease_expires_at)
    if (expiresMs === null || expiresMs > nowMs)
      continue
    findings.push({
      id: bead.id,
      title: bead.title,
      owner: bead.assignee ?? bead.owner ?? null,
      lease_expires_at: bead.lease_expires_at,
      heartbeat_at: bead.heartbeat_at ?? null,
    })
  }
  return findings
}

/** Informational lines for in_progress beads whose lease cannot be evaluated. */
function collectLeaseWarnings(beads) {
  const warnings = []
  if (!Array.isArray(beads))
    return warnings
  for (const bead of beads) {
    if (!bead || typeof bead !== 'object' || bead.status !== 'in_progress')
      continue
    const raw = bead.lease_expires_at
    if (parseTimestamp(raw) !== null)
      continue
    const id = bead.id ?? '<unknown id>'
    const detail = raw == null || raw === '' ? 'missing' : `unparseable (${JSON.stringify(raw)})`
    warnings.push(`⚠️ ${id}: in_progress lease ${detail}; not counted as stale`)
  }
  return warnings
}

/** Pure report builder: no process spawn, no filesystem access, no console output. */
function buildReport(beads, now) {
  if (!Array.isArray(beads)) {
    return {
      exitCode: 1,
      findings: [],
      warnings: [],
      lines: ['❌ Unable to audit Beads leases: expected a top-level JSON array.'],
    }
  }

  const findings = findStaleLeases(beads, now)
  const warnings = collectLeaseWarnings(beads)
  const lines = [...warnings]
  if (findings.length === 0) {
    lines.push('✅ No stale in_progress leases.')
  }
  else {
    lines.push(`⚠️ Stale in_progress Beads lease(s): ${findings.length}`)
    for (const finding of findings) {
      lines.push(`   - ${finding.id}: "${finding.title}" — lease ${finding.lease_expires_at} (owner: ${finding.owner ?? 'unassigned'}, heartbeat: ${finding.heartbeat_at ?? 'unknown'})`)
    }
  }
  lines.push(`📊 Audited ${beads.length} in_progress bead(s): ${findings.length} stale, ${warnings.length} skipped.`)
  return { exitCode: 0, findings, warnings, lines }
}

const SELF_TEST_NOW = new Date('2026-11-26T00:00:00Z')
const SELF_TEST_BEADS = [
  {
    id: 'airi-self-expired',
    title: 'Expired in_progress lease',
    status: 'in_progress',
    assignee: 'bee-self',
    owner: 'owner-self',
    lease_expires_at: '2026-11-25T11:15:18Z',
    heartbeat_at: '2026-11-25T11:10:18Z',
    labels: ['bug'],
  },
  {
    id: 'airi-self-fresh',
    title: 'Fresh in_progress lease',
    status: 'in_progress',
    assignee: 'bee-other',
    owner: 'owner-other',
    lease_expires_at: '2026-12-01T00:00:00Z',
    heartbeat_at: '2026-11-26T00:00:00Z',
    labels: [],
  },
  {
    id: 'airi-self-nolease',
    title: 'In_progress lease with no expiry',
    status: 'in_progress',
    assignee: 'bee-none',
    owner: null,
    heartbeat_at: '2026-11-25T11:00:00Z',
    labels: [],
  },
  {
    id: 'airi-self-invalid',
    title: 'In_progress lease with invalid expiry',
    status: 'in_progress',
    assignee: null,
    owner: 'owner-invalid',
    lease_expires_at: 'not-a-timestamp',
    heartbeat_at: '2026-11-25T11:00:00Z',
    labels: [],
  },
  {
    id: 'airi-self-closed',
    title: 'Closed bead with an old lease',
    status: 'closed',
    assignee: 'bee-closed',
    owner: 'owner-closed',
    lease_expires_at: '2026-01-01T00:00:00Z',
    heartbeat_at: '2026-01-01T00:00:00Z',
    labels: [],
  },
]

function runSelfTest() {
  try {
    const findings = findStaleLeases(SELF_TEST_BEADS, SELF_TEST_NOW)
    assert.equal(findings.length, 1, 'expected exactly one stale in_progress lease (the expired one) — stale detection is missing or broken')
    assert.equal(findings[0].id, 'airi-self-expired', 'the expired in_progress lease must be the one flagged')
    assert.equal(findings[0].title, 'Expired in_progress lease', 'finding must carry the bead title')
    assert.equal(findings[0].owner, 'bee-self', 'owner label must prefer assignee over owner')
    assert.equal(findings[0].lease_expires_at, '2026-11-25T11:15:18Z', 'finding must carry lease_expires_at')
    assert.equal(findings[0].heartbeat_at, '2026-11-25T11:10:18Z', 'finding must carry heartbeat_at as display context')

    const expiredMovedToFuture = SELF_TEST_BEADS.map(bead => bead.id === 'airi-self-expired'
      ? { ...bead, lease_expires_at: '2027-01-01T00:00:00Z' }
      : bead)
    assert.equal(findStaleLeases(expiredMovedToFuture, SELF_TEST_NOW).length, 0, 'flipping the expired lease into the future must remove the finding')

    const freshMovedToPast = SELF_TEST_BEADS.map(bead => bead.id === 'airi-self-fresh'
      ? { ...bead, lease_expires_at: '2026-11-20T00:00:00Z' }
      : bead)
    assert.deepEqual(findStaleLeases(freshMovedToPast, SELF_TEST_NOW).map(f => f.id).sort(), ['airi-self-expired', 'airi-self-fresh'], 'flipping the fresh lease into the past must add a finding')

    assert.equal(collectLeaseWarnings(SELF_TEST_BEADS).length, 2, 'missing and unparseable leases must produce informational warnings')

    const report = buildReport(SELF_TEST_BEADS, SELF_TEST_NOW)
    assert.equal(report.exitCode, 0, 'stale findings must be reported with exitCode 0')
    assert.ok(report.lines.some(line => line.includes('Stale in_progress Beads lease(s): 1')), 'report must print a stale summary line')
    assert.ok(report.lines.some(line => line.trimStart().startsWith('- airi-self-expired')), 'report must print one indented line per finding')
    assert.equal(buildReport(null, SELF_TEST_NOW).exitCode, 1, 'unreadable input must return exitCode 1')
  }
  catch (error) {
    console.error(`❌ Self-test failed: ${error.message}`)
    process.exit(1)
  }
  console.info('✅ Self-test passed: stale in_progress lease detection is present and non-vacuous.')
}

function fixtureFlag(args) {
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--fixture' && args[i + 1])
      return args[i + 1]
  }
  return null
}

function readBdFallbackPath() {
  const candidates = [
    process.env.BD_BIN,
    path.join(process.env.HOME || '', '.local/bin/bd'),
    '/usr/local/bin/bd',
    '/usr/bin/bd',
  ].filter(Boolean)
  return candidates.find(candidate => fs.existsSync(candidate)) || null
}

function readFromBd() {
  let result = spawnSync('bd', BD_ARGS, { cwd: REPO_ROOT, encoding: 'utf-8' })
  // Only reach for an absolute path when `bd` is genuinely not on PATH.
  if (result.error?.code === 'ENOENT') {
    const fallback = readBdFallbackPath()
    if (fallback)
      result = spawnSync(fallback, BD_ARGS, { cwd: REPO_ROOT, encoding: 'utf-8' })
  }
  if (result.error)
    return { error: `bd invocation failed: ${result.error.message}` }
  if (result.status !== 0) {
    return { error: `bd exited with status ${result.status}: ${(result.stderr || '').trim()}` }
  }
  try {
    return { beads: JSON.parse(result.stdout) }
  }
  catch (error) {
    return { error: `bd JSON parse failed: ${error.message}` }
  }
}

function main() {
  const args = process.argv.slice(2)
  if (args.includes('--self-test')) {
    runSelfTest()
    return
  }

  const fixture = fixtureFlag(args) || process.env[FIXTURE_ENV]
  let source
  if (fixture) {
    try {
      source = { beads: JSON.parse(fs.readFileSync(path.resolve(process.cwd(), fixture), 'utf8')) }
    }
    catch (error) {
      source = { error: `unable to read fixture ${fixture}: ${error.message}` }
    }
  }
  else {
    source = readFromBd()
  }

  const report = source.error
    ? { exitCode: 1, findings: [], warnings: [], lines: [`❌ ${source.error}`] }
    : buildReport(source.beads, new Date())

  for (const line of report.lines)
    console.info(line)
  process.exitCode = report.exitCode
}

main()
