#!/usr/bin/env node

/**
 * AIRI round-17 state machine.
 *
 * Authority boundaries:
 *   - guard pins: `state/pinned-guards.sha` compared to the GIT INDEX
 *     (`git ls-files -s`), never to working-tree bytes or a writable constant;
 *   - receipts: the five pinned wave-0 files, each anchored by its sha256 in
 *     the genesis event and hash-chained event log;
 *   - lanes: normalized absolute paths with alias detection.
 *
 * Usage:
 *   node scripts/sm.mjs recover
 *   node scripts/sm.mjs audit
 *   node scripts/sm.mjs head:advance --sha <new-head>
 *   node scripts/sm.mjs --help
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { Buffer } from 'node:buffer'
import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { fileURLToPath, pathToFileURL } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
export const REPO_ROOT = path.resolve(__dirname, '..')
export const STATE_DIR = path.join(REPO_ROOT, 'state')
export const WAVE0_DIR = path.join(REPO_ROOT, '.wave0')

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

/** The 14 paths this lane owns. No other lane may lease any of them. */
export const L0_OWNED = [
  'scripts/bootstrap-state.mjs',
  'scripts/sm.mjs',
  'scripts/tests/audit-packet.mjs',
  'scripts/tests/audit-packet.test.mjs',
  'scripts/tests/fixtures/audit-packet/valid.json',
  'scripts/tests/fixtures/audit-packet/invalid-missing-invariant.json',
  'scripts/tests/fixtures/audit-packet/invalid-placeholder.json',
  'state/events.ndjson',
  'state/bindings.json',
  'state/index.json',
  'state/SUMMARY.md',
  'state/current_wave.json',
  'state/pinned-guards.sha',
  'docs/coordinator-boot.md',
]

/** Corrected r17 leases from the cartographer audit: S2 and S3 only, no S4. */
export const LANE_LEASES = {
  L0: {
    owner: 'L0',
    role: 'state-system bootstrap',
    paths: [...L0_OWNED],
  },
  S2: {
    owner: 'S2',
    role: 'chat stream cursor',
    paths: [
      'apps/flutter/lib/features/chat/state/stream_cursor.dart',
      'apps/flutter/lib/features/chat/state/chat_transport.dart',
      'apps/flutter/test/chat_stream_cursor_test.dart',
    ],
  },
  S3: {
    owner: 'S3',
    role: 'peer predicates',
    paths: [
      'apps/flutter/lib/features/peers/peer_predicates.dart',
      'apps/flutter/test/peer_predicates_test.dart',
    ],
  },
}

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

/**
 * RED evidence captured before any file was written, at base 38613b6e.
 * The checkout root is replaced by the `<repo>` token so no emitted artifact
 * contains a machine-specific absolute path; everything else is verbatim.
 */
export const RED_EVIDENCE = {
  captured_at: 'pre-implementation, base 38613b6e',
  path_token: '<repo>',
  commands: [
    {
      command: 'node scripts/sm.mjs recover',
      exit_code: 1,
      stdout: '',
      code: 'MODULE_NOT_FOUND',
      stderr: [
        'node:internal/modules/cjs/loader:1607',
        '  throw err;',
        '  ^',
        '',
        'Error: Cannot find module \'<repo>/scripts/sm.mjs\'',
        '    at Module._resolveFilename (node:internal/modules/cjs/loader:1603:15)',
        '    at wrapResolveFilename (node:internal/modules/cjs/loader:1145:27)',
        '    at defaultResolveImplForCJSLoading (node:internal/modules/cjs/loader:1169:10)',
        '    at resolveForCJSWithHooks (node:internal/modules/cjs/loader:1196:12)',
        '    at Module._load (node:internal/modules/cjs/loader:1370:5)',
        '    at wrapModuleLoad (node:internal/modules/cjs/loader:261:19)',
        '    at Module.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:171:5)',
        '    at node:internal/main/run_main_module:33:47 {',
        '  code: \'MODULE_NOT_FOUND\',',
        '  requireStack: []',
        '}',
        '',
        'Node.js v26.13.1',
        '',
      ].join('\n'),
    },
    {
      command: 'node scripts/tests/audit-packet.mjs',
      exit_code: 1,
      stdout: '',
      code: 'MODULE_NOT_FOUND',
      stderr: [
        'node:internal/modules/cjs/loader:1607',
        '  throw err;',
        '  ^',
        '',
        'Error: Cannot find module \'<repo>/scripts/tests/audit-packet.mjs\'',
        '    at Module._resolveFilename (node:internal/modules/cjs/loader:1603:15)',
        '    at wrapResolveFilename (node:internal/modules/cjs/loader:1145:27)',
        '    at defaultResolveImplForCJSLoading (node:internal/modules/cjs/loader:1169:10)',
        '    at resolveForCJSWithHooks (node:internal/modules/cjs/loader:1196:12)',
        '    at Module._load (node:internal/modules/cjs/loader:1370:5)',
        '    at wrapModuleLoad (node:internal/modules/cjs/loader:261:19)',
        '    at Module.executeUserEntryPoint [as runMain] (node:internal/modules/run_main:171:5)',
        '    at node:internal/main/run_main_module:33:47 {',
        '  code: \'MODULE_NOT_FOUND\',',
        '  requireStack: []',
        '}',
        '',
        'Node.js v26.13.1',
        '',
      ].join('\n'),
    },
  ],
}

export function canonical(value) {
  return `${JSON.stringify(value, null, 2)}\n`
}

export function sha256Text(text) {
  return createHash('sha256').update(Buffer.from(text, 'utf8')).digest('hex')
}

function sha256Bytes(bytes) {
  return createHash('sha256').update(bytes).digest('hex')
}

/** Hash of an event's exact NDJSON line — the hash-chain link. */
export function hashEvent(event) {
  return sha256Text(JSON.stringify(event))
}

function fail(message) {
  throw new Error(`sm: ${message}`)
}

function isSha(value, length = 40) {
  return typeof value === 'string' && new RegExp(`^[0-9a-f]{${length}}$`).test(value)
}

export function readJson(relPath) {
  const abs = path.join(REPO_ROOT, relPath)
  if (!fs.existsSync(abs))
    fail(`missing input file: ${relPath}`)
  try {
    return JSON.parse(fs.readFileSync(abs, 'utf8'))
  }
  catch (error) {
    fail(`invalid JSON in ${relPath}: ${error.message}`)
  }
}

export function readEvents() {
  const abs = path.join(STATE_DIR, 'events.ndjson')
  if (!fs.existsSync(abs))
    return []
  const lines = fs.readFileSync(abs, 'utf8').split('\n').filter(line => line.trim() !== '')
  return lines.map((line, index) => {
    try {
      return JSON.parse(line)
    }
    catch (error) {
      return fail(`invalid event at line ${index + 1}: ${error.message}`)
    }
  })
}

export function readBindings() {
  return readJson('state/bindings.json')
}

/** Pins come only from state/pinned-guards.sha — no hardcoded source of truth. */
export function loadGuardPins() {
  const abs = path.join(STATE_DIR, 'pinned-guards.sha')
  let text
  try {
    text = fs.readFileSync(abs, 'utf8')
  }
  catch {
    fail('state/pinned-guards.sha is missing or unreadable')
  }
  const lines = text.split('\n').filter(Boolean)
  if (lines.length !== 4)
    fail('state/pinned-guards.sha must contain exactly four lines')
  const pins = {}
  for (const line of lines) {
    const [sha, relPath, ...extra] = line.split(' ')
    if (!isSha(sha) || !relPath || extra.length > 0
      || relPath.startsWith('/') || relPath.includes('..')
      || !relPath.startsWith('scripts/tests/') || !relPath.endsWith('.mjs')) {
      fail(`malformed guard pin line: ${line}`)
    }
    pins[relPath] = sha
  }
  if (Object.keys(pins).length !== 4)
    fail('state/pinned-guards.sha does not pin exactly four distinct guards')
  return pins
}

/**
 * Equivalent of:
 *   LC_ALL=C git ls-files -s -- <4 guards> | awk '{print $2" "$4}' \
 *     | LC_ALL=C sort -k2,2 | diff -u state/pinned-guards.sha -
 * Only the git INDEX supplies the SHAs; working-tree bytes are never read.
 */
export function guardPinsFromIndex() {
  const paths = Object.keys(loadGuardPins()).sort()
  const result = spawnSync('git', ['ls-files', '-s', '--', ...paths], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
    env: { ...process.env, LC_ALL: 'C' },
  })
  if (result.status !== 0)
    fail(`git ls-files failed: ${result.stderr?.trim() ?? 'unknown error'}`)
  const rows = result.stdout.split('\n').filter(Boolean).map((line) => {
    const tab = line.indexOf('\t')
    if (tab === -1)
      fail(`malformed git ls-files line: ${line}`)
    const fields = line.slice(0, tab).trim().split(/\s+/)
    return { sha: fields[1], relPath: line.slice(tab + 1) }
  })
  rows.sort((a, b) => Buffer.compare(Buffer.from(a.relPath), Buffer.from(b.relPath)))
  return {
    text: rows.map(row => `${row.sha} ${row.relPath}\n`).join(''),
    pins: Object.fromEntries(rows.map(row => [row.relPath, row.sha])),
  }
}

export function verifyGuardPins() {
  const drift = []
  let index
  try {
    index = guardPinsFromIndex()
  }
  catch (error) {
    return [`index:${error.message}`]
  }
  const abs = path.join(STATE_DIR, 'pinned-guards.sha')
  let onDisk
  try {
    onDisk = fs.readFileSync(abs, 'utf8')
  }
  catch {
    return ['pinned_file:unreadable']
  }
  if (onDisk !== index.text)
    drift.push('pinned_file_vs_git_index')
  for (const relPath of Object.keys(index.pins).sort()) {
    const expected = index.pins[relPath]
    if (!isSha(expected)) {
      drift.push(`${relPath}:missing_from_index`)
      continue
    }
    const pinnedLine = onDisk.split('\n').find(line => line.endsWith(` ${relPath}`))
    if (!pinnedLine || pinnedLine.slice(0, 40) !== expected)
      drift.push(`${relPath}:index_sha_mismatch`)
  }
  return [...new Set(drift)].sort()
}

/** Walk the real .wave0 tree; never trust only the hardcoded manifest. */
export function scanWave0Receipts() {
  if (!fs.existsSync(WAVE0_DIR))
    return { known: [], unanchored: [] }
  const found = []
  function walk(dir) {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const abs = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        walk(abs)
      }
      else if (entry.isFile() && entry.name === 'receipt.json') {
        found.push(path.relative(REPO_ROOT, abs).replace(/\\/g, '/'))
      }
    }
  }
  walk(WAVE0_DIR)
  found.sort((a, b) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
  const knownPaths = new Set(RECEIPT_MANIFEST.map(receipt => receipt.path))
  const unanchored = found
    .filter(relPath => !knownPaths.has(relPath))
    .map(relPath => ({
      path: relPath,
      sha256: sha256Bytes(fs.readFileSync(path.join(REPO_ROOT, relPath))),
      anchor_status: 'UNCOMMITTED_OR_ORPHAN',
      commit_sha: null,
    }))
  return { known: found.filter(relPath => knownPaths.has(relPath)), unanchored }
}

/** Read and verify the five receipts, including their byte-anchored sha256. */
export function ingestReceipts() {
  return RECEIPT_MANIFEST.map((manifest) => {
    const abs = path.join(REPO_ROOT, manifest.path)
    if (!fs.existsSync(abs))
      fail(`missing receipt: ${manifest.path}`)
    const bytes = fs.readFileSync(abs)
    const sha256 = sha256Bytes(bytes)
    if (sha256 !== manifest.sha256)
      fail(`${manifest.path}: sha256 drift (expected ${manifest.sha256}, got ${sha256})`)
    let parsed
    try {
      parsed = JSON.parse(bytes.toString('utf8'))
    }
    catch (error) {
      fail(`${manifest.path}: invalid JSON: ${error.message}`)
    }
    const observed = {
      base_sha: parsed.base_sha,
      head_sha: parsed.head_sha,
      diff_hash: parsed.diff_hash,
    }
    for (const key of ['base_sha', 'head_sha']) {
      if (!isSha(observed[key]) || observed[key] !== manifest[key])
        fail(`${manifest.path}: ${key} drift`)
    }
    if (manifest.diff_hash === null) {
      if (observed.diff_hash !== undefined && observed.diff_hash !== null)
        fail(`${manifest.path}: unexpected diff_hash`)
      observed.diff_hash = null
    }
    else if (!isSha(observed.diff_hash, 64) || observed.diff_hash !== manifest.diff_hash) {
      fail(`${manifest.path}: diff_hash drift`)
    }
    return { id: manifest.id, path: manifest.path, ...observed, sha256 }
  })
}

export function buildBindings(receipts, unanchored, guardPins) {
  return {
    schema: SCHEMA_BINDINGS,
    wave: WAVE,
    base_sha: BASE_SHA,
    beads_mode: 'PAUSED',
    unknowns: [],
    receipts,
    pinned_guard_blobs: { ...guardPins },
    lane_leases: structuredClone(LANE_LEASES),
    unanchored_receipts: unanchored.map(entry => ({ ...entry })),
  }
}

export function buildGenesis(receipts, unanchored, guardPins) {
  return {
    seq: 1,
    type: 'genesis',
    prev_hash: ZERO_HASH,
    wave: WAVE,
    base_sha: BASE_SHA,
    beads_mode: 'PAUSED',
    unknowns: [],
    receipts: receipts.map(receipt => ({ ...receipt })),
    pinned_guard_blobs: { ...guardPins },
    lane_leases: structuredClone(LANE_LEASES),
    unanchored_receipts: unanchored.map(entry => ({ ...entry })),
    red_evidence: structuredClone(RED_EVIDENCE),
  }
}

/** One event per unanchored receipt, hash-chained after genesis. */
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

export function checkClosedSchema(value, allowed, label) {
  return checkClosed(value, allowed, label)
}

function checkClosed(value, allowed, label) {
  if (!value || typeof value !== 'object' || Array.isArray(value))
    return [`${label}:not_object`]
  const extras = Object.keys(value).filter(key => !allowed.includes(key)).sort()
  const missing = allowed.filter(key => !(key in value)).sort()
  return [
    ...extras.map(key => `${label}:extra_field:${key}`),
    ...missing.map(key => `${label}:missing_field:${key}`),
  ]
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

function normalizeLease(value, guardRelPaths) {
  if (typeof value !== 'string' || value.length === 0)
    return { error: 'not_a_string' }
  const abs = path.resolve(REPO_ROOT, value)
  const rel = path.relative(REPO_ROOT, abs).replace(/\\/g, '/')
  if (rel === '..' || rel.startsWith(`..${path.sep}`) || path.isAbsolute(rel))
    return { error: 'outside_repo' }
  let normalized = rel
  try {
    const realRoot = fs.realpathSync(REPO_ROOT)
    const real = fs.realpathSync(abs)
    const realRel = path.relative(realRoot, real).replace(/\\/g, '/')
    if (realRel === '..' || realRel.startsWith(`..${path.sep}`) || path.isAbsolute(realRel))
      return { error: 'outside_repo_realpath', normalized }
    normalized = realRel
  }
  catch {
    // Path does not exist yet; the lexical normalization still applies.
  }
  if (value.replace(/\\/g, '/') !== normalized)
    return { normalized, alias: true }
  if (guardRelPaths.includes(normalized))
    return { normalized, guard: true }
  return { normalized, alias: false, guard: false }
}

export function detectLeaseCollision(leases, guardRelPaths = []) {
  if (!leases || typeof leases !== 'object' || Array.isArray(leases))
    return ['malformed_leases']
  const collisions = []
  const claims = new Map()
  const allowedLanes = ['L0', 'S2', 'S3']
  for (const [lane, spec] of Object.entries(leases)) {
    if (lane.trim().toUpperCase() === 'S4')
      collisions.push('unexpected_S4_lease')
    if (!allowedLanes.includes(lane))
      collisions.push(`unexpected_lane_key:${lane}`)
    if (!spec || !Array.isArray(spec.paths))
      return [...new Set([...collisions, 'malformed_leases'])].sort()
    for (const value of spec.paths) {
      const result = normalizeLease(value, guardRelPaths)
      if (result.error) {
        collisions.push(`${lane}:${value}:${result.error}`)
        continue
      }
      if (result.alias)
        collisions.push(`${lane}:lease_alias:${value}->${result.normalized}`)
      if (result.guard)
        collisions.push(`${lane}:guard_lease:${result.normalized}`)
      if (claims.has(result.normalized))
        collisions.push(`${result.normalized}:${claims.get(result.normalized)}+${lane}`)
      else
        claims.set(result.normalized, lane)
    }
  }
  const owned = L0_OWNED.map(value => normalizeLease(value, guardRelPaths).normalized).sort()
  const l0Claims = [...claims.entries()]
    .filter(([, lane]) => lane === 'L0')
    .map(([relPath]) => relPath)
    .sort()
  if (JSON.stringify(owned) !== JSON.stringify(l0Claims))
    collisions.push('L0_owned_set_mismatch')
  return [...new Set(collisions)].sort()
}

export function deriveHead(events) {
  let head = BASE_SHA
  for (const event of events) {
    if (event?.type === 'head_advanced')
      head = event.sha
  }
  return head
}

/**
 * Shared projection check: the committed genesis and its unanchored-receipt
 * events must match a fresh build from the pinned receipts, live .wave0 scan
 * and pinned guards. Both `sm audit` and the audit-packet validator use it so
 * neither can pass while the other fails closed.
 */
export function verifyEventProjection(events, { receipts, unanchored, guardPins }) {
  const issues = []
  const genesis = events.find(event => event?.type === 'genesis')
  if (!genesis)
    return ['genesis_missing']
  const expectedGenesis = buildGenesis(receipts, unanchored, guardPins)
  if (JSON.stringify(genesis) !== JSON.stringify(expectedGenesis))
    issues.push('GENESIS_CONTENT_DRIFT')
  const expectedUnanchored = buildUnanchoredEvents(unanchored, hashEvent(expectedGenesis))
  const actualUnanchored = events.filter(event => event?.type === 'WAVE0_RECEIPT_INGESTED')
  if (JSON.stringify(actualUnanchored) !== JSON.stringify(expectedUnanchored))
    issues.push('UNANCHORED_EVENT_DRIFT')
  return issues
}

function buildSummary({ bindings, receipts, guardPins, unanchored, headSha }) {
  const guardLines = Object.entries(guardPins)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([p, sha]) => `| \`${p}\` | \`${sha}\` |`)
  const receiptLines = receipts.map(r =>
    `| \`${r.id}\` | \`${r.base_sha}\` | \`${r.head_sha}\` | ${r.diff_hash === null ? 'n/a' : `\`${r.diff_hash}\``} | \`${r.sha256}\` |`)
  const redLines = RED_EVIDENCE.commands.map(c =>
    `| \`${c.command}\` | ${c.exit_code} | \`${c.code}\` |`)
  const redExcerpt = RED_EVIDENCE.commands[0].stderr
    .split('\n')
    .filter(line => line.includes('Cannot find module') || line.includes('code:') || line.includes('requireStack') || line.startsWith('Node.js'))
    .map(line => `  ${line}`)
    .join('\n')
  const unanchoredLines = unanchored.length === 0
    ? ['(none)']
    : unanchored.map(entry => `| \`${entry.path}\` | \`${entry.sha256}\` | \`${entry.anchor_status}\` | \`null\` |`)

  return [
    '# Round 17 coordinator state summary',
    '',
    'Generated by `scripts/bootstrap-state.mjs` and rebuilt byte-for-byte by `node scripts/sm.mjs recover`. Do not hand-edit.',
    '',
    `wave: \`${WAVE}\``,
    '',
    `base_sha: \`${bindings.base_sha}\` (immutable genesis anchor)`,
    '',
    `head_sha: \`${headSha}\``,
    '',
    'beads_mode: `PAUSED` (no Beads reads or writes during this wave)',
    '',
    'unknowns: `[]` (fail closed; genesis and bindings are both checked)',
    '',
    '## RED evidence (captured before implementation)',
    '',
    '| Command | Exit | Code |',
    '| --- | --- | --- |',
    ...redLines,
    '',
    'Verbatim diagnostic (checkout root replaced by `<repo>`):',
    '',
    '```text',
    redExcerpt,
    '```',
    '',
    '## GREEN acceptance',
    '',
    '```text',
    'node scripts/bootstrap-state.mjs --dry-run',
    'node scripts/sm.mjs recover',
    'node scripts/sm.mjs audit',
    'node scripts/tests/audit-packet.mjs',
    'node --test scripts/tests/audit-packet.test.mjs',
    '```',
    '',
    'Head moves are explicit: `node scripts/sm.mjs head:advance --sha <new>`.',
    '',
    '## Invariants',
    '',
    ...INVARIANTS.map(i => `- \`${i}\``),
    '',
    '## Ingested receipts (sha256 anchored in the genesis hash chain)',
    '',
    '| Lane | base | head | diff hash | sha256 |',
    '| --- | --- | --- | --- | --- |',
    ...receiptLines,
    '',
    '## Pinned guards (state/pinned-guards.sha versus git index blobs)',
    '',
    '| Path | Index blob |',
    '| --- | --- |',
    ...guardLines,
    '',
    '## NEEDS_RECONCILIATION — unanchored receipts',
    '',
    '| Path | sha256 | anchor_status | commit_sha |',
    '| --- | --- | --- | --- |',
    ...unanchoredLines,
    '',
    '## Lane leases',
    '',
    'Three lanes only: `L0` (state-system bootstrap), `S2` (chat stream cursor), `S3` (peer predicates). There is no `S4` this wave; the audit-packet validator was absorbed into `L0`.',
    '',
    '## Exit codes',
    '',
    '| Code | Meaning |',
    '| --- | --- |',
    '| 0 | pass |',
    '| 1 | unexpected harness error (the pre-implementation RED state) |',
    '| 2 | schema, closed-field or fixture error |',
    '| 3 | unresolved unknowns |',
    '| 4 | guard pin drift against the git index |',
    '| 5 | hash-chain, genesis-content or replay mismatch |',
    '| 6 | scope or lease collision |',
    '',
  ].join('\n')
}

/** Compute every state/* artifact. Pure: no clock, no randomness, no writes. */
export function buildAllState({ bindings, events, receipts, unanchored, guardPins, headSha }) {
  const files = new Map()
  files.set('events.ndjson', `${events.map(event => JSON.stringify(event)).join('\n')}\n`)
  files.set('bindings.json', canonical(bindings))
  files.set('current_wave.json', canonical({
    schema: 'airi-current-wave/v1',
    wave: WAVE,
    base_sha: bindings.base_sha,
    head_sha: headSha,
    beads_mode: bindings.beads_mode,
    lane_count: 3,
    lanes: Object.entries(bindings.lane_leases).map(([id, spec]) => ({
      id,
      owner: spec.owner,
      role: spec.role,
      owned_paths: [...spec.paths],
    })),
    no_s4: !Object.keys(bindings.lane_leases).some(key => key.trim().toUpperCase() === 'S4'),
    unanchored_receipts: unanchored.map(entry => ({ ...entry })),
    needs_reconciliation: unanchored.length > 0,
  }))
  files.set('pinned-guards.sha', Object.entries(guardPins)
    .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map(([p, sha]) => `${sha} ${p}\n`)
    .join(''))
  files.set('SUMMARY.md', buildSummary({ bindings, receipts, guardPins, unanchored, headSha }))
  files.set('index.json', canonical({
    schema: 'airi-state-index/v1',
    wave: WAVE,
    base_sha: bindings.base_sha,
    head_sha: headSha,
    artifacts: [
      'state/SUMMARY.md',
      'state/bindings.json',
      'state/current_wave.json',
      'state/events.ndjson',
      'state/pinned-guards.sha',
    ].map(relPath => ({
      path: relPath,
      sha256: sha256Text(files.get(path.basename(relPath))),
    })),
    unanchored_receipts: unanchored.map(entry => ({ ...entry })),
    needs_reconciliation: unanchored.length > 0,
  }))
  return files
}

export function writeAllState(files) {
  fs.mkdirSync(STATE_DIR, { recursive: true })
  for (const [name, content] of files) {
    fs.writeFileSync(path.join(STATE_DIR, name), Buffer.from(content, 'utf8'))
  }
}

export function verifyReplay(files) {
  const mismatches = []
  for (const [name, content] of files) {
    const abs = path.join(STATE_DIR, name)
    const expected = Buffer.from(content, 'utf8')
    if (!fs.existsSync(abs)) {
      mismatches.push(`${name}:missing`)
      continue
    }
    if (!fs.readFileSync(abs).equals(expected))
      mismatches.push(`${name}:bytes`)
  }
  return mismatches.sort()
}

function finish(logger, code, diagnostic) {
  logger(`[SM_AUDIT] exit ${code} ${diagnostic}`)
  return code
}

/** Full audit. Returns 0 or the r17 taxonomy code; never throws on bad input. */
export function verifyState({ logger = () => {} } = {}) {
  let receipts, bindings, events, scan, guardPins, unanchored
  try {
    receipts = ingestReceipts()
  }
  catch (error) {
    return finish(logger, 2, `RECEIPT_INGEST:${error.message}`)
  }
  try {
    bindings = readBindings()
    events = readEvents()
  }
  catch (error) {
    return finish(logger, 2, `SCHEMA_INPUT:${error.message}`)
  }
  const bindingIssues = checkClosed(bindings, BINDINGS_KEYS, 'bindings')
  if (bindingIssues.length > 0)
    return finish(logger, 2, `SCHEMA_BINDINGS:${bindingIssues.join(',')}`)

  const genesisEvents = events.filter(event => event?.type === 'genesis')
  if (genesisEvents.length !== 1)
    return finish(logger, 2, `SCHEMA_GENESIS_COUNT_${genesisEvents.length}`)
  const genesis = genesisEvents[0]
  const genesisIssues = checkClosed(genesis, GENESIS_KEYS, 'genesis')
  if (genesisIssues.length > 0)
    return finish(logger, 2, `SCHEMA_GENESIS:${genesisIssues.join(',')}`)
  if (genesis.seq !== 1)
    return finish(logger, 2, `SCHEMA_GENESIS_SEQ_${genesis.seq}`)

  const unknowns = [
    ...(Array.isArray(genesis.unknowns) ? genesis.unknowns : ['malformed']),
    ...(Array.isArray(bindings.unknowns) ? bindings.unknowns : ['malformed']),
  ]
  if (unknowns.length > 0)
    return finish(logger, 3, `UNKNOWNS_UNRESOLVED:${unknowns.join(',')}`)
  if (genesis.beads_mode !== 'PAUSED' || bindings.beads_mode !== 'PAUSED')
    return finish(logger, 2, 'SCHEMA_BEADS_MODE')
  if (genesis.base_sha !== BASE_SHA || bindings.base_sha !== BASE_SHA || bindings.wave !== WAVE || genesis.wave !== WAVE)
    return finish(logger, 2, 'SCHEMA_ANCHORS')

  try {
    scan = scanWave0Receipts()
    unanchored = scan.unanchored
    guardPins = loadGuardPins()
  }
  catch (error) {
    return finish(logger, 2, `SCHEMA_SCAN:${error.message}`)
  }

  const drift = verifyGuardPins()
  if (drift.length > 0)
    return finish(logger, 4, `GUARD_DRIFT:${drift.join(',')}`)

  const collisions = detectLeaseCollision(bindings.lane_leases, Object.keys(guardPins))
  if (collisions.length > 0)
    return finish(logger, 6, `LEASE_COLLISION:${collisions.join(',')}`)

  const chain = verifyEventChain(events)
  if (chain.length > 0)
    return finish(logger, 5, `HASH_CHAIN:${chain.join(',')}`)

  const projection = verifyEventProjection(events, { receipts, unanchored, guardPins })
  if (projection.length > 0)
    return finish(logger, 5, projection.join(','))

  let headSha
  try {
    headSha = deriveHead(events)
    const gitHead = resolveHeadSha()
    const effectiveHead = gitHead === headSha ? gitHead : resolveEffectiveHeadSha()
    if (effectiveHead !== headSha)
      return finish(logger, 5, `HEAD_DRIFT:${gitHead}`)
  }
  catch (error) {
    return finish(logger, 5, `HEAD_DRIFT:${error.message}`)
  }
  const files = buildAllState({ bindings, events, receipts, unanchored, guardPins, headSha })
  const replay = verifyReplay(files)
  if (replay.length > 0)
    return finish(logger, 5, `REPLAY_MISMATCH:${replay.join(',')}`)

  return finish(logger, 0, 'OK')
}

/** HEAD is an explicit replay input: `git rev-parse HEAD`, no expected value. */
export function resolveHeadSha() {
  const result = spawnSync('git', ['rev-parse', 'HEAD'], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
  if (result.status !== 0)
    fail(`cannot resolve HEAD: ${result.stderr?.trim() ?? 'git failed'}`)
  const head = result.stdout.trim()
  if (!isSha(head))
    fail(`invalid HEAD sha: ${head}`)
  return head
}

/** Paths changed by one commit relative to its parent. */
function commitPaths(sha) {
  const result = spawnSync('git', ['diff-tree', '--no-commit-id', '--name-only', '-r', sha], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
  if (result.status !== 0)
    fail(`cannot inspect commit ${sha}: ${result.stderr?.trim() ?? 'git failed'}`)
  return result.stdout.split('\n').map(rel => rel.trim()).filter(Boolean)
}

/** First parent of a commit, or null at the root. */
function firstParentSha(sha) {
  const result = spawnSync('git', ['rev-parse', `${sha}^`], {
    cwd: REPO_ROOT,
    encoding: 'utf8',
  })
  if (result.status !== 0)
    return null
  const parent = result.stdout.trim()
  if (!isSha(parent))
    fail(`invalid parent sha for ${sha}: ${parent}`)
  return parent
}

/**
 * A commit that only rewrites state/* is ledger bookkeeping, not a new head:
 * `head:advance` followed by committing the rewritten state leaves HEAD past
 * the head recorded in the event log. Walk back over those commits to the
 * first one that touched anything else and compare that to deriveHead(events).
 */
export function resolveEffectiveHeadSha() {
  let current = resolveHeadSha()
  const seen = new Set()
  let done = false
  while (!done) {
    if (seen.has(current))
      fail(`HEAD ancestry cycle at ${current}`)
    seen.add(current)
    const paths = commitPaths(current)
    // An empty (or unexpanded merge) commit changes nothing: never skip it, so
    // code drift hid behind one still fails closed.
    const stateOnly = paths.length > 0 && paths.every(rel => rel.startsWith('state/'))
    if (!stateOnly) {
      done = true
      continue
    }
    const parent = firstParentSha(current)
    if (!parent)
      fail(`state-only history has no non-state commit (root ${current})`)
    current = parent
  }
  return current
}

/** Preflight for `recover`: fail closed on guards, unknowns, leases and chain. */
function preflight() {
  let bindings, events, receipts, guardPins, unanchored
  try {
    receipts = ingestReceipts()
    bindings = readBindings()
    events = readEvents()
    guardPins = loadGuardPins()
    unanchored = scanWave0Receipts().unanchored
  }
  catch (error) {
    fail(`preflight input: ${error.message}`)
  }
  const genesis = events.find(event => event?.type === 'genesis') ?? {}
  const issues = [
    ...checkClosed(bindings, BINDINGS_KEYS, 'bindings'),
    ...checkClosed(genesis, GENESIS_KEYS, 'genesis'),
  ]
  if (issues.length > 0)
    fail(`preflight schema: ${issues.join(',')}`)
  const unknowns = [
    ...(Array.isArray(genesis.unknowns) ? genesis.unknowns : ['malformed']),
    ...(Array.isArray(bindings.unknowns) ? bindings.unknowns : ['malformed']),
  ]
  if (unknowns.length > 0)
    fail(`preflight unknowns: ${unknowns.join(',')}`)
  const drift = verifyGuardPins()
  if (drift.length > 0)
    fail(`preflight guard drift: ${drift.join(',')}`)
  const collisions = detectLeaseCollision(bindings.lane_leases, Object.keys(guardPins))
  if (collisions.length > 0)
    fail(`preflight lease collision: ${collisions.join(',')}`)
  const chain = verifyEventChain(events)
  if (chain.length > 0)
    fail(`preflight hash chain: ${chain.join(',')}`)
  return { receipts, bindings, events, guardPins, unanchored }
}

function recover() {
  const { receipts, bindings, events, guardPins, unanchored } = preflight()
  const headSha = deriveHead(events)
  if (resolveHeadSha() !== headSha)
    fail('HEAD is not the head recorded in the event log; run head:advance first')
  const files = buildAllState({ bindings, events, receipts, unanchored, guardPins, headSha })
  writeAllState(files)
  for (const name of [...files.keys()].sort())
    console.info(`[SM_RECOVER] wrote state/${name} (${Buffer.byteLength(files.get(name), 'utf8')} bytes)`)
  return 0
}

function headAdvance(args) {
  const index = args.indexOf('--sha')
  const sha = index === -1 ? null : args[index + 1]
  if (!isSha(sha))
    fail('head:advance requires --sha <40-hex sha>')
  const events = readEvents()
  const chain = verifyEventChain(events)
  if (chain.length > 0)
    fail(`invalid event chain: ${chain.join(',')}`)
  const current = deriveHead(events)
  const gitHead = resolveHeadSha()
  if (sha !== gitHead)
    fail(`--sha must equal current git HEAD (${gitHead})`)
  if (sha === current)
    fail(`HEAD already advanced to ${sha}`)
  const last = events[events.length - 1]
  events.push({
    seq: last.seq + 1,
    type: 'head_advanced',
    prev_hash: hashEvent(last),
    sha,
  })
  const { receipts, bindings, guardPins, unanchored } = preflight()
  const files = buildAllState({ bindings, events, receipts, unanchored, guardPins, headSha: sha })
  writeAllState(files)
  console.info(`[SM_HEAD_ADVANCE] ${current} -> ${sha}, seq ${last.seq + 1}`)
  return 0
}

function help() {
  console.info([
    'AIRI round-17 state machine',
    '',
    '  node scripts/sm.mjs recover                    rebuild state/* after preflight',
    '  node scripts/sm.mjs audit                      verify all invariants',
    '  node scripts/sm.mjs head:advance --sha <new>   append a chained head event',
    '  node scripts/sm.mjs --help                     this message',
    '',
    'Exit codes: 0 pass, 2 schema/fixture, 3 unknowns, 4 guard drift,',
    '5 chain/replay/HEAD mismatch, 6 lease collision, 1 unexpected error.',
  ].join('\n'))
  return 0
}

function main() {
  const [command, ...rest] = process.argv.slice(2)
  try {
    if (command === 'recover')
      return recover()
    if (command === 'audit')
      return verifyState({ logger: message => console.error(message) })
    if (command === 'head:advance')
      return headAdvance(rest)
    if (command === '--help' || command === '-h' || command === 'help')
      return help()
    console.error('[SM_USAGE] node scripts/sm.mjs <recover|audit|head:advance|--help>')
    return 1
  }
  catch (error) {
    console.error(`[SM_ERROR] ${error.message}`)
    return 1
  }
}

const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false

if (isMain)
  process.exit(main())
