import assert from 'node:assert/strict'
import { spawnSync } from 'node:child_process'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { test } from 'node:test'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const auditorPath = path.join(__dirname, 'audit-doc-citations.mjs')

function fixtureDoc(t, body) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'doc-citations-'))
  const doc = path.join(dir, 'fixture.md')
  fs.writeFileSync(doc, `# Fixture\n\n${body}\n`)
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }))
  return doc
}

function runAuditor(doc) {
  return spawnSync(process.execPath, [auditorPath, '--doc', doc], { encoding: 'utf-8' })
}

function outputOf(result) {
  return `${result.stdout ?? ''}${result.stderr ?? ''}`
}

test('RED: a deleted relative path with a line range is reported as broken', (t) => {
  const doc = fixtureDoc(t, 'see `libs/auth.ts:10-15` for the gate')
  const result = runAuditor(doc)
  assert.notEqual(result.status, 0, `auditor accepted a deleted citation:\n${outputOf(result)}`)
  assert.match(outputOf(result), /broken citation/)
  assert.ok(outputOf(result).includes('libs/auth.ts:10-15'), `diagnostic must name the citation:\n${outputOf(result)}`)
})

test('Guard A: canonical citation with ports and prose references passes', (t) => {
  const doc = fixtureDoc(t, 'see `crates/anima-daemon/src/gateway.rs:1` and `ws://localhost:6121/ws` '
    + '(port 6121, localhost:6121, 127.0.0.1:6121, §5, Section 4, Step 3, line 10)')
  const result = runAuditor(doc)
  assert.equal(result.status, 0, `auditor rejected valid prose:\n${outputOf(result)}`)
  assert.doesNotMatch(outputOf(result), /broken citation/)
})

test('Guard B: a valid path plus symbol with no line anchor passes', (t) => {
  const doc = fixtureDoc(t, 'see `crates/anima-core/src/pacing.rs` and the `TtftWindow` symbol')
  const result = runAuditor(doc)
  assert.equal(result.status, 0, `auditor rejected a symbol-only citation:\n${outputOf(result)}`)
  assert.doesNotMatch(outputOf(result), /broken citation/)
})

test('Guard C: a bare :digits continuation anchor after a cited file passes', (t) => {
  const doc = fixtureDoc(t, 'see `crates/anima-daemon/src/gateway.rs:1608`; '
    + 'the cursor constant is at `:1975`')
  const result = runAuditor(doc)
  assert.equal(result.status, 0, `auditor rejected a continuation anchor:\n${outputOf(result)}`)
  assert.doesNotMatch(outputOf(result), /broken citation/)
})

test('Out-of-range: a uniquely resolvable relative path past EOF is broken', (t) => {
  const doc = fixtureDoc(t, 'see `features/chat/chat_composer_controller.dart:999999` for send mode')
  const result = runAuditor(doc)
  assert.notEqual(result.status, 0, `auditor accepted a past-EOF relative anchor:\n${outputOf(result)}`)
  assert.match(outputOf(result), /cited line out of range/)
  assert.ok(outputOf(result).includes('features/chat/chat_composer_controller.dart:999999'),
    `diagnostic must name the citation:\n${outputOf(result)}`)
})

test('Ambiguous: two fixture files sharing a suffix are reported as broken', (t) => {
  const doc = fixtureDoc(t, 'see `libs/auth.ts:10-15` for the gate')
  const dir = path.dirname(doc)
  for (const twin of ['a', 'b']) {
    const nested = path.join(dir, twin, 'libs')
    fs.mkdirSync(nested, { recursive: true })
    fs.writeFileSync(path.join(nested, 'auth.ts'), 'export const gate = true\n')
  }
  const result = runAuditor(doc)
  assert.notEqual(result.status, 0, `auditor accepted an ambiguous relative path:\n${outputOf(result)}`)
  assert.match(outputOf(result), /cited path is ambiguous/)
  assert.ok(outputOf(result).includes('libs/auth.ts:10-15'),
    `diagnostic must name the citation:\n${outputOf(result)}`)
})
