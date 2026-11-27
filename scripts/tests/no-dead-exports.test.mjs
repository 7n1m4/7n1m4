import assert from 'node:assert/strict'

import { spawnSync } from 'node:child_process'
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, resolve, sep } from 'node:path'
// eslint-disable-next-line test/no-import-node-test -- this guard suite runs under `node --test`
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import {
  audit,
  auditSharedRegions,
  extractDirectives,
  lexDart,
  materializeFixture,
  REPO_ROOT,
  validateVirtualPath,
  writeVirtualFiles,
} from './no-dead-exports.mjs'

const HERE = dirname(fileURLToPath(import.meta.url))
const CLI = join(HERE, 'no-dead-exports.mjs')
const FIXTURE = join(HERE, 'fixtures/no-dead-exports-region-lock.dart')
const REGION_PATH = 'apps/flutter/lib/features/chat/chat_screen.dart'
const WITNESS_LINE = '[DEAD_EXPORT] apps/flutter/lib/features/chat/chat_archetype_style.dart has zero production callers outside tests/barrels'
const DEAD_LINE = '[DEAD_EXPORT] apps/flutter/lib/features/chat/dead_archetype.dart has zero production callers outside tests/barrels'

function runCli(args) {
  return spawnSync(process.execPath, [CLI, ...args], { encoding: 'utf8' })
}

function freshRoot(t) {
  const root = mkdtempSync(join(tmpdir(), 'no-dead-exports-test-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  return root
}

function fixtureFiles() {
  return materializeFixture(readFileSync(FIXTURE, 'utf8'))
}

test('WIRED: live-tree audit and CLI both yield exactly the verified witness line', () => {
  assert.deepEqual(audit(REPO_ROOT), [WITNESS_LINE])
  assert.deepEqual(auditSharedRegions(REPO_ROOT), [])

  const result = runCli([])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.equal(result.stderr, `${WITNESS_LINE}\n`)
  assert.equal(result.stdout, '')
})

test('fixture materialization produces exactly the expected DEAD_EXPORT and REGION_LOCK lines', (t) => {
  const root = freshRoot(t)
  const files = fixtureFiles()
  writeVirtualFiles(root, files)

  assert.deepEqual(audit(root), [DEAD_LINE])
  assert.deepEqual(auditSharedRegions(root), [])
  assert.deepEqual([...audit(root), ...auditSharedRegions(root)].sort(), [DEAD_LINE])

  const result = runCli(['--root', root])
  assert.equal(result.error, undefined)
  assert.equal(result.status, 1)
  assert.equal(result.stderr, `${DEAD_LINE}\n`)
  assert.equal(result.stdout, '')

  for (const rel of files.keys()) {
    const safe = validateVirtualPath(rel)
    const abs = join(root, ...safe.split('/'))
    assert.ok(resolve(abs).startsWith(`${resolve(root)}${sep}`), `virtual path escaped root: ${rel}`)
    assert.ok(existsSync(abs), `virtual file missing: ${rel}`)
  }
})

test('a direct production importer suppresses a finding; barrel-only plus test-only does not', (t) => {
  const live = freshRoot(t)
  writeVirtualFiles(live, new Map([
    ['apps/flutter/lib/main.dart', 'import \'live.dart\';\n'],
    ['apps/flutter/lib/live.dart', 'class Live {}\n'],
  ]))
  assert.deepEqual(audit(live), [])

  const dead = freshRoot(t)
  writeVirtualFiles(dead, new Map([
    ['apps/flutter/lib/barrel.dart', 'export \'dead.dart\';\n'],
    ['apps/flutter/test/dead_test.dart', 'import \'package:anima_control/dead.dart\';\n'],
    ['apps/flutter/lib/dead.dart', 'class Dead {}\n'],
  ]))
  assert.deepEqual(audit(dead), [
    '[DEAD_EXPORT] apps/flutter/lib/dead.dart has zero production callers outside tests/barrels',
  ])
})

test('shared-region table: missing symbol anchor and present forbidden anchor each emit REGION_LOCK, passing region emits none', (t) => {
  const root = freshRoot(t)
  writeVirtualFiles(root, fixtureFiles())

  assert.deepEqual(auditSharedRegions(root), [])
  assert.deepEqual(auditSharedRegions(join(root, 'missing')), [
    `[REGION_LOCK] ${REGION_PATH} missing required anchor: MarkdownBody(`,
  ])
  assert.deepEqual(auditSharedRegions(join(root, 'forbidden')), [
    `[REGION_LOCK] ${REGION_PATH} contains forbidden anchor: bubbleDecorationFor(`,
  ])
})

test('region lock catches rewritten forbidden imports and whitespace-split calls', (t) => {
  const passing = fixtureFiles().get(REGION_PATH)
  const cases = [
    ['package: URI', 'import \'package:anima_control/features/chat/chat_archetype_style.dart\';\n', 'import \'chat_archetype_style.dart\''],
    ['double quotes', 'import "chat_archetype_style.dart";\n', 'import \'chat_archetype_style.dart\''],
    ['newline before paren', 'void f() { bubbleDecorationFor\n (); }\n', 'bubbleDecorationFor('],
    ['space before paren', 'void g() { ArchetypeStyledBubble (); }\n', 'ArchetypeStyledBubble('],
  ]
  for (const [label, injected, anchor] of cases) {
    const root = freshRoot(t)
    // Insert after the first import: a real top-level directive position.
    const [firstImport, ...rest] = passing.split('\n')
    writeVirtualFiles(root, new Map([[REGION_PATH, [firstImport, injected.trimEnd(), ...rest].join('\n')]]))
    assert.deepEqual(
      auditSharedRegions(root),
      [`[REGION_LOCK] ${REGION_PATH} contains forbidden anchor: ${anchor}`],
      label,
    )
  }
})

test('declaration keywords are not directives: final export/import do not launder a dead module', (t) => {
  const root = freshRoot(t)
  writeVirtualFiles(root, new Map([
    ['apps/flutter/lib/main.dart', 'import \'features/chat/screen.dart\';\n'],
    ['apps/flutter/lib/features/chat/screen.dart', 'final import = \'dead.dart\';\n'],
    ['apps/flutter/lib/features/chat/dead.dart', 'class Dead {}\nfinal export = \'noop\';\n'],
    ['apps/flutter/test/dead_test.dart', 'import \'package:anima_control/features/chat/dead.dart\';\n'],
  ]))
  assert.deepEqual(audit(root), [
    '[DEAD_EXPORT] apps/flutter/lib/features/chat/dead.dart has zero production callers outside tests/barrels',
  ])
})

test('a map-literal key named import is not a directive', (t) => {
  const root = freshRoot(t)
  writeVirtualFiles(root, new Map([
    ['apps/flutter/lib/main.dart', 'const m = {import: \'dead.dart\'};\n'],
    ['apps/flutter/lib/dead.dart', 'class Dead {}\n'],
  ]))
  assert.deepEqual(audit(root), [
    '[DEAD_EXPORT] apps/flutter/lib/dead.dart has zero production callers outside tests/barrels',
  ])
})

test('table-only mode leaves the shared-region file byte-identical', (t) => {
  const root = freshRoot(t)
  writeVirtualFiles(root, fixtureFiles())

  const fixtureRegion = join(root, ...REGION_PATH.split('/'))
  const fixtureBefore = readFileSync(fixtureRegion)
  auditSharedRegions(root)
  assert.deepEqual(readFileSync(fixtureRegion), fixtureBefore)

  const liveRegion = join(REPO_ROOT, ...REGION_PATH.split('/'))
  const liveBefore = readFileSync(liveRegion)
  auditSharedRegions(REPO_ROOT)
  assert.deepEqual(readFileSync(liveRegion), liveBefore)
})

test('conditional directives capture every URI literal before the semicolon', (t) => {
  const files = fixtureFiles()
  const barrel = files.get('apps/flutter/lib/features/chat/conditional_barrel.dart')
  const { noComments, code } = lexDart(barrel)
  assert.deepEqual(
    extractDirectives(noComments, code).filter(d => d.kind === 'export').map(d => d.uri),
    ['stub.dart', 'dead_archetype.dart'],
  )

  // The conditional import's second URI is the only production caller of its
  // target; if it were dropped, that target would surface as a second finding.
  const root = freshRoot(t)
  writeVirtualFiles(root, files)
  assert.deepEqual(audit(root), [DEAD_LINE])
})

test('missing and empty --root fail closed with [NO_DEAD_EXPORTS_ERROR]', (t) => {
  const base = freshRoot(t)
  const missing = runCli(['--root', join(base, 'does-not-exist')])
  assert.notEqual(missing.status, 0)
  assert.match(missing.stderr, /^\[NO_DEAD_EXPORTS_ERROR\]/)
  assert.equal(missing.stdout, '')

  const empty = freshRoot(t)
  mkdirSync(join(empty, ...'apps/flutter/lib'.split('/')), { recursive: true })
  const emptyResult = runCli(['--root', empty])
  assert.notEqual(emptyResult.status, 0)
  assert.match(emptyResult.stderr, /^\[NO_DEAD_EXPORTS_ERROR\]/)
  assert.equal(emptyResult.stdout, '')

  const noArg = runCli(['--root'])
  assert.notEqual(noArg.status, 0)
  assert.match(noArg.stderr, /^\[NO_DEAD_EXPORTS_ERROR\]/)
})

test('symlinked Dart entries inside the root are audited; escaped targets are rejected', (t) => {
  const root = freshRoot(t)
  const outside = freshRoot(t)
  writeVirtualFiles(outside, new Map([['outside_dead.dart', 'class OutsideDead {}\n']]))
  writeVirtualFiles(root, new Map([
    ['apps/flutter/lib/real/a.dart', 'class RealA {}\n'],
    ['apps/flutter/lib/target/b.dart', 'class TargetB {}\n'],
  ]))

  const lib = join(root, 'apps/flutter/lib')
  symlinkSync(join(lib, 'target'), join(lib, 'link_dir'))
  symlinkSync(join(lib, 'real/a.dart'), join(lib, 'link_file.dart'))
  symlinkSync(join(outside, 'outside_dead.dart'), join(lib, 'escape.dart'))

  const lines = audit(root)
  assert.ok(lines.includes('[DEAD_EXPORT] apps/flutter/lib/real/a.dart has zero production callers outside tests/barrels'))
  assert.ok(lines.includes('[DEAD_EXPORT] apps/flutter/lib/target/b.dart has zero production callers outside tests/barrels'))
  assert.ok(lines.includes('[DEAD_EXPORT] apps/flutter/lib/link_dir/b.dart has zero production callers outside tests/barrels'))
  assert.ok(lines.includes('[DEAD_EXPORT] apps/flutter/lib/link_file.dart has zero production callers outside tests/barrels'))
  assert.ok(!lines.some(line => line.includes('outside_dead.dart')), 'escaped symlink target was audited')
  assert.deepEqual(lines, [...lines].sort())
})

test('findings are deterministically sorted and unsafe virtual paths are rejected', (t) => {
  const root = freshRoot(t)
  writeVirtualFiles(root, new Map([
    ['apps/flutter/lib/z.dart', 'class Z {}\n'],
    ['apps/flutter/lib/a.dart', 'class A {}\n'],
    ['apps/flutter/lib/m.dart', 'class M {}\n'],
  ]))
  const lines = audit(root)
  assert.deepEqual(lines, [
    '[DEAD_EXPORT] apps/flutter/lib/a.dart has zero production callers outside tests/barrels',
    '[DEAD_EXPORT] apps/flutter/lib/m.dart has zero production callers outside tests/barrels',
    '[DEAD_EXPORT] apps/flutter/lib/z.dart has zero production callers outside tests/barrels',
  ])
  assert.deepEqual(lines, [...lines].sort())

  for (const bad of ['../escape.dart', '/tmp/escape.dart', 'dir\\escape.dart']) {
    assert.throws(() => validateVirtualPath(bad), /unsafe virtual path/)
    assert.throws(
      () => materializeFixture(`// === VIRTUAL_FILE: ${bad} ===\n// class A {}\n`),
      /unsafe virtual path/,
    )
    assert.throws(
      () => writeVirtualFiles(root, new Map([[bad, 'class A {}\n']])),
      /unsafe virtual path/,
    )
  }
})
