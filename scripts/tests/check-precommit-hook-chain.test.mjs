import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { test } from 'node:test'
import { fileURLToPath } from 'node:url'

import { globToRegExp } from './check-precommit-hook-chain.mjs'

const checkerPath = join(dirname(fileURLToPath(import.meta.url)), 'check-precommit-hook-chain.mjs')

const JS_GLOB = '*.{js,cjs,mjs,ts,tsx,vue}'
const CORRECT_CONFIG = {
  '*.rs': 'rustfmt --edition 2021',
  '*.dart': 'dart format',
  [JS_GLOB]: 'eslint --fix',
}

function run(t, config, options = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'precommit-chain-'))
  t.after(() => rmSync(dir, { recursive: true, force: true }))

  const fixture = join(dir, 'package.json')
  writeFileSync(fixture, JSON.stringify({
    'nano-staged': config,
    'simple-git-hooks': options.hooks ?? { 'pre-commit': 'pnpm nano-staged' },
  }))

  const result = spawnSync(process.execPath, [checkerPath, '--config', fixture], { encoding: 'utf8' })
  assert.equal(result.error, undefined)
  assert.doesNotMatch(result.stderr, /Cannot find module|MODULE_NOT_FOUND|ENOENT/)
  return result
}

const without = key => {
  const config = { ...CORRECT_CONFIG }
  delete config[key]
  return config
}

test('correct three mappings pass', t => {
  const result = run(t, CORRECT_CONFIG)
  assert.equal(result.status, 0)
  assert.match(result.stdout, /nano-staged chain OK/)
})

test('missing eslint mapping fails and names eslint and the JS-family glob', t => {
  const result = run(t, without(JS_GLOB))
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /eslint/)
  assert.match(result.stderr, /\*\.\{js,cjs,mjs,ts,tsx,vue\}/)
})

const missingFormatterCases = [
  { name: 'missing rustfmt', key: '*.rs', named: [/rustfmt/, /\*\.rs/] },
  { name: 'missing dart', key: '*.dart', named: [/dart format/, /\*\.dart/] },
]

for (const { name, key, named } of missingFormatterCases) {
  test(`${name} fails`, t => {
    const result = run(t, without(key))
    assert.notEqual(result.status, 0)
    for (const pattern of named)
      assert.match(result.stderr, pattern)
  })
}

const commandMutationCases = [
  { name: 'wrong rust edition', config: { ...CORRECT_CONFIG, '*.rs': 'rustfmt --edition 2018' }, expected: /rustfmt --edition 2021/ },
  { name: 'wrong dart command', config: { ...CORRECT_CONFIG, '*.dart': 'dart format --line-length 80' }, expected: /-> "dart format"/ },
  { name: 'wrong eslint command', config: { ...CORRECT_CONFIG, [JS_GLOB]: 'prettier --write' }, expected: /eslint --fix/ },
]

for (const { name, config, expected } of commandMutationCases) {
  test(`${name} fails`, t => {
    const result = run(t, config)
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, expected)
  })
}

const docFormatterCases = [
  { name: '*.md', path: /AGENTS\.md/, glob: /\*\.md/ },
  { name: '*.json', path: /package\.json/, glob: /\*\.json/ },
  { name: '*.yml', path: /ci\.yml/, glob: /\*\.yml/ },
  { name: '*.yaml', path: /pnpm-workspace\.yaml/, glob: /\*\.yaml/ },
]

for (const { name, path, glob } of docFormatterCases) {
  test(`formatting ${name} fails`, t => {
    const result = run(t, { ...CORRECT_CONFIG, [name]: 'prettier --write' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, path)
    assert.match(result.stderr, glob)
  })
}

test('a competing pattern fails even when the witness still holds', t => {
  const result = run(t, { ...CORRECT_CONFIG, 'crates/anima-daemon/**/*.rs': 'prettier --write' })
  assert.notEqual(result.status, 0)
  assert.match(result.stderr, /crates\/anima-daemon\/\*\*\/\*\.rs/)
  assert.match(result.stderr, /prettier --write/)
})

const extglobCases = ['!(*.rs)', '@(AGENTS|README).md', '+(*.dart)', '?(*.ts)']

for (const pattern of extglobCases) {
  test(`unsupported extglob ${pattern} fails`, t => {
    const result = run(t, { ...CORRECT_CONFIG, [pattern]: 'prettier --write' })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /unsupported extglob syntax/)
    assert.match(result.stderr, /extglob/)
  })
}

const hookCases = [
  { name: 'missing hook', hooks: {} },
  { name: 'no-op hook', hooks: { 'pre-commit': 'echo noop' } },
]

for (const { name, hooks } of hookCases) {
  test(`pre-commit chain fails with ${name}`, t => {
    const result = run(t, CORRECT_CONFIG, { hooks })
    assert.notEqual(result.status, 0)
    assert.match(result.stderr, /pre-commit/)
    assert.match(result.stderr, /pnpm nano-staged/)
  })
}

test('slash wildcard is one segment; no-slash wildcard spans directories', () => {
  assert.equal(globToRegExp('src/*.rs').test('src/a.rs'), true)
  assert.equal(globToRegExp('src/*.rs').test('src/a/b.rs'), false)
  assert.equal(globToRegExp('*.rs').test('crates/anima-channel/src/wire.rs'), true)
  assert.equal(globToRegExp('crates/**/*.rs').test('crates/a/b.rs'), true)
})
