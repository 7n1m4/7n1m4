import assert from 'node:assert/strict'
// eslint-disable-next-line test/no-import-node-test -- this guard runs under `node --test`
import test from 'node:test'

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = dirname(fileURLToPath(import.meta.url))
const repoRoot = join(__dirname, '..', '..')
const guard = join(repoRoot, 'scripts', 'tests', 'guard-eslint-mjs.mjs')

// The fixture repo lives inside the checkout so the repo's flat ESLint config
// and pnpm binaries resolve for the guard's `pnpm exec eslint` call.
function fixtureRepo(t) {
  const dir = mkdtempSync(join(repoRoot, '.guard-eslint-fixture-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))

  const git = args => spawnSync('git', args, { cwd: dir, encoding: 'utf8' })
  assert.equal(git(['init', '-q']).status, 0)
  assert.equal(git(['config', 'user.email', 'guard@example.test']).status, 0)
  assert.equal(git(['config', 'user.name', 'Guard Test']).status, 0)
  writeFileSync(join(dir, 'README.md'), 'fixture\n')
  assert.equal(git(['add', 'README.md']).status, 0)
  assert.equal(git(['commit', '-q', '-m', 'base']).status, 0)

  return { dir, base: git(['rev-parse', 'HEAD']).stdout.trim() }
}

function runGuard(dir, args) {
  return spawnSync(process.execPath, [guard, ...args], { cwd: dir, encoding: 'utf8' })
}

const CLEAN_MJS = [
  '// eslint-disable-next-line test/no-import-node-test -- this guard runs under `node --test`',
  `import test from 'node:test'`,
  '',
  `test('fixture', () => {})`,
  '',
].join('\n')

test('RED: a touched .mjs with a bare node:test import fails the guard', (t) => {
  const { dir, base } = fixtureRepo(t)
  writeFileSync(join(dir, 'violation.test.mjs'), `import { test } from 'node:test'\n`)

  const result = runGuard(dir, [`--base=${base}`])
  assert.notEqual(result.status, 0, `guard unexpectedly passed:\n${result.stdout}\n${result.stderr}`)
  assert.match(`${result.stdout}${result.stderr}`, /test\/no-import-node-test/)
})

test('GREEN: the disable comment makes the touched .mjs lint clean', (t) => {
  const { dir, base } = fixtureRepo(t)
  writeFileSync(join(dir, 'clean.test.mjs'), CLEAN_MJS)

  const result = runGuard(dir, [`--base=${base}`])
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
})

test('scope: a violating non-.mjs file is ignored', (t) => {
  const { dir, base } = fixtureRepo(t)
  writeFileSync(join(dir, 'clean.test.mjs'), CLEAN_MJS)
  writeFileSync(join(dir, 'violation.test.js'), `import { test } from 'node:test'\n`)

  const result = runGuard(dir, [`--base=${base}`])
  assert.equal(result.status, 0, `${result.stdout}\n${result.stderr}`)
  assert.match(result.stdout, /clean\.test\.mjs/)
  assert.doesNotMatch(`${result.stdout}${result.stderr}`, /violation\.test\.js/)
})

test('fail-closed: missing or invalid --base exits non-zero', (t) => {
  const { dir } = fixtureRepo(t)
  assert.notEqual(runGuard(dir, []).status, 0)
  assert.notEqual(runGuard(dir, ['--base=does-not-exist-4boj']).status, 0)
})

test('package.json registers the guard script', () => {
  const pkg = JSON.parse(readFileSync(join(repoRoot, 'package.json'), 'utf8'))
  assert.equal(pkg.scripts['guard:eslint-mjs'], 'node scripts/tests/guard-eslint-mjs.mjs')
})
