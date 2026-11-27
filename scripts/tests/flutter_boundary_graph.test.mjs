import assert from 'node:assert/strict'

import { spawnSync } from 'node:child_process'
import {
  accessSync,
  chmodSync,
  copyFileSync,
  existsSync,
  constants as fsConstants,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
// eslint-disable-next-line test/no-import-node-test -- this guard suite runs under `node --test`
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { parse } from 'yaml'

const HERE = dirname(fileURLToPath(import.meta.url))
const GUARD = join(HERE, 'flutter_boundary_graph.mjs')
const REPO_ROOT = join(HERE, '../..')
const ZONE_PREFIX = 'apps/flutter/lib/features/chat'

const EXPECTED_LINE = `[BOUNDARY_GRAPH_VIOLATION] zone=ui capability=dart:io chain=${ZONE_PREFIX}/ui/chat_screen.dart -> ${ZONE_PREFIX}/state/chat_barrel.dart -> ${ZONE_PREFIX}/data/storage_barrel.dart -> dart:io`
const SYMLINK_LINE = `[BOUNDARY_GRAPH_VIOLATION] zone=ui capability=dart:io chain=${ZONE_PREFIX}/ui/escape_link.dart -> dart:io`
const DIRLINK_LINE = `[BOUNDARY_GRAPH_VIOLATION] zone=ui capability=dart:io chain=${ZONE_PREFIX}/ui/chat_screen.dart -> ${ZONE_PREFIX}/state/barrel.dart -> ${ZONE_PREFIX}/data/leak.dart -> dart:io`
const MISSING_ERROR = `[BOUNDARY_GRAPH_ERROR] --root has no ${ZONE_PREFIX}: `

function runGuard(args, options = {}) {
  return spawnSync(process.execPath, [GUARD, ...args], { encoding: 'utf8', ...options })
}

function makeRoot(t) {
  const root = mkdtempSync(join(tmpdir(), 'boundary-graph-test-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  return root
}

function seedLaunderedChain(root) {
  const chat = join(root, ...ZONE_PREFIX.split('/'))
  for (const zone of ['ui', 'state', 'data'])
    mkdirSync(join(chat, zone), { recursive: true })
  writeFileSync(join(chat, 'ui/chat_screen.dart'), 'import \'../state/chat_barrel.dart\';\n')
  writeFileSync(join(chat, 'state/chat_barrel.dart'), 'export \'../data/storage_barrel.dart\';\n')
  writeFileSync(join(chat, 'data/storage_barrel.dart'), 'export \'dart:io\';\n')
  return chat
}

function resolvedHook() {
  const result = spawnSync('git', ['rev-parse', '--git-path', 'hooks/pre-commit'], { cwd: REPO_ROOT, encoding: 'utf8' })
  assert.equal(result.status, 0, result.stderr)
  return result.stdout.trim()
}

// core.hooksPath is machine-local: a fresh clone has no installed hook.
function availableHook(t) {
  const hook = resolvedHook()
  try {
    accessSync(hook, fsConstants.X_OK)
    return hook
  }
  catch {
    t.skip('resolved pre-commit hook is not installed in this checkout')
    return null
  }
}

function walkFiles(dir) {
  if (!existsSync(dir))
    return []
  const out = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name)
    if (entry.isDirectory())
      out.push(...walkFiles(path))
    else if (entry.isFile())
      out.push(path)
  }
  return out
}

test('--self-test passes with the exact expected line', () => {
  const result = runGuard(['--self-test'])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 0, result.stderr)
  assert.equal(result.stderr, `${EXPECTED_LINE}\n`)
  assert.equal(result.stdout, '')
})

test('explicit --root with no chat tree fails closed with the exact error', () => {
  const result = runGuard(['--root', '/nonexistent'])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.equal(result.stderr, `${MISSING_ERROR}/nonexistent\n`)
  assert.equal(result.stdout, '')
})

test('missing default chat tree also fails closed', (t) => {
  const root = makeRoot(t)
  const scriptDir = join(root, 'scripts/tests')
  mkdirSync(scriptDir, { recursive: true })
  copyFileSync(GUARD, join(scriptDir, 'flutter_boundary_graph.mjs'))
  const result = spawnSync(process.execPath, [join(scriptDir, 'flutter_boundary_graph.mjs')], { encoding: 'utf8' })
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.equal(result.stderr, `${MISSING_ERROR}${root}\n`)
  assert.equal(result.stdout, '')
})

test('real-root laundered chain and in-root symlink laundering both yield violations', (t) => {
  const root = makeRoot(t)
  const chat = seedLaunderedChain(root)

  // A symlink back into the declared root must carry dart:io into zone ui.
  writeFileSync(join(root, 'outside.dart'), 'export \'dart:io\';\n')
  symlinkSync(join(root, 'outside.dart'), join(chat, 'ui/escape_link.dart'))
  // An absolute-URI decoy is ignored but must never make the guard pass.
  writeFileSync(join(chat, 'data/abs_decoy.dart'), 'export \'/etc/passwd\';\n')

  const result = runGuard(['--root', root])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.ok(result.stderr.includes(EXPECTED_LINE), `missing exact chain line: ${result.stderr}`)
  assert.ok(result.stderr.includes(SYMLINK_LINE), `symlink laundering was ignored: ${result.stderr}`)
  assert.ok(!result.stderr.includes('symlink escapes root'), result.stderr)
  assert.equal(result.stdout, '')
})

test('symlink escaping the declared root fails closed as a violation', (t) => {
  const root = makeRoot(t)
  const outside = mkdtempSync(join(tmpdir(), 'boundary-graph-outside-'))
  t.after(() => rmSync(outside, { recursive: true, force: true }))
  const chat = join(root, ...ZONE_PREFIX.split('/'))
  mkdirSync(join(chat, 'ui'), { recursive: true })
  writeFileSync(join(outside, 'leak.dart'), 'export \'dart:io\';\n')
  symlinkSync(join(outside, 'leak.dart'), join(chat, 'ui/escape.dart'))

  const result = runGuard(['--root', root])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.match(result.stderr, /^\[BOUNDARY_GRAPH_VIOLATION\] symlink escapes root: apps\/flutter\/lib\/features\/chat\/ui\/escape\.dart -> /m)
  assert.equal(result.stdout, '')
})

test('symlinked directory carries dart:io into the linking zone', (t) => {
  const root = makeRoot(t)
  const chat = join(root, ...ZONE_PREFIX.split('/'))
  mkdirSync(join(chat, 'ui'), { recursive: true })
  mkdirSync(join(chat, 'state'), { recursive: true })
  const external = join(root, 'external')
  mkdirSync(external)
  writeFileSync(join(chat, 'ui/chat_screen.dart'), 'import \'../state/barrel.dart\';\n')
  writeFileSync(join(chat, 'state/barrel.dart'), 'export \'../data/leak.dart\';\n')
  writeFileSync(join(external, 'leak.dart'), 'export \'dart:io\';\n')
  symlinkSync(external, join(chat, 'data'))

  const result = runGuard(['--root', root])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.equal(result.stderr, `${DIRLINK_LINE}\n`)
  assert.equal(result.stdout, '')
})

test('resolved pre-commit hook exists and is executable', (t) => {
  const hook = availableHook(t)
  if (!hook)
    return
  assert.ok(hook.length > 0)
})

test('resolved hook invokes the guard and propagates a non-zero exit', (t) => {
  const hook = availableHook(t)
  if (!hook)
    return
  const dir = makeRoot(t)
  const binDir = join(dir, 'bin')
  mkdirSync(binDir)
  const log = join(dir, 'calls.log')
  const stub = '#!/bin/sh\nprintf \'CALLED:%s\\n\' "$*" >> "$CALL_LOG"\nif [ "$1" = run ] && [ "$2" = guard:boundary-graph ]; then\n  exit 42\nfi\nexit 0\n'
  const stubPath = join(binDir, 'pnpm')
  writeFileSync(stubPath, stub)
  chmodSync(stubPath, 0o755)

  const env = { ...process.env, PATH: `${binDir}:${process.env.PATH}`, CALL_LOG: log }
  delete env.SKIP_SIMPLE_GIT_HOOKS
  delete env.SIMPLE_GIT_HOOKS_RC

  const result = spawnSync(hook, [], { env, encoding: 'utf8' })
  assert.equal(result.error, undefined)
  assert.equal(result.status, 42, result.stderr)
  assert.ok(existsSync(log), 'hook never invoked the stubbed pnpm')
  const calls = readFileSync(log, 'utf8')
  assert.match(calls, /^CALLED:run guard:boundary-graph$/m)
  assert.ok(!calls.includes('nano-staged'), `hook continued past a failed guard: ${calls}`)
})

test('no .husky file wires the guard', () => {
  for (const file of walkFiles(join(REPO_ROOT, '.husky')))
    assert.ok(!readFileSync(file, 'utf8').includes('guard:boundary-graph'), `${file} still wires the dead husky hook`)
})

test('CI lint job installs deps, checks out full history and orders both guards', () => {
  const pkg = JSON.parse(readFileSync(join(REPO_ROOT, 'package.json'), 'utf8'))
  assert.equal(pkg.scripts['test:boundary-graph-wiring'], 'node --test scripts/tests/flutter_boundary_graph.test.mjs')

  const ci = parse(readFileSync(join(REPO_ROOT, '.github/workflows/ci.yml'), 'utf8'))
  const steps = ci.jobs.lint.steps
  const checkout = steps.find(step => step.uses === 'actions/checkout@v6')
  assert.ok(checkout, 'lint job has no checkout step')
  assert.equal(Number(checkout.with?.['fetch-depth']), 0)

  const installIdx = steps.findIndex(step => step.run?.startsWith('pnpm install'))
  assert.ok(installIdx >= 0, 'lint job has no pnpm install step')
  const eslintIdx = steps.findIndex(step => step.id === 'guard-eslint-mjs')
  const boundaryIdx = steps.findIndex(step => step.id === 'guard-boundary-graph')
  assert.ok(eslintIdx >= 0, 'guard-eslint-mjs step missing from jobs.lint.steps')
  assert.ok(boundaryIdx >= 0, 'guard-boundary-graph step missing from jobs.lint.steps')
  assert.ok(installIdx < eslintIdx && installIdx < boundaryIdx, `install at ${installIdx} must precede both guards (${eslintIdx}, ${boundaryIdx})`)
  assert.ok(boundaryIdx > eslintIdx, `expected boundary guard after eslint guard, got ${boundaryIdx} <= ${eslintIdx}`)
  assert.match(steps[boundaryIdx].run, /flutter_boundary_graph\.mjs/)
  assert.match(steps[boundaryIdx].run, /test:boundary-graph-wiring/)
})
