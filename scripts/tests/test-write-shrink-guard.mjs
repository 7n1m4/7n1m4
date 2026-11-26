import assert from 'node:assert/strict'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import test from 'node:test'

import writeShrinkGuard, { evaluateWriteShrink, WHOLE_FILE_REPLACE_MARKER } from '../../.omp/hooks/pre/write-shrink-guard.js'

function makeFixture(t) {
  const cwd = mkdtempSync(join(tmpdir(), 'write-shrink-guard-'))
  t.after(() => rmSync(cwd, { recursive: true, force: true }))
  return cwd
}

function captureHandler() {
  let handler
  writeShrinkGuard({
    on(event, fn) {
      assert.equal(event, 'tool_call')
      handler = fn
    },
  })
  assert.equal(typeof handler, 'function')
  return handler
}

function longFile(target, lines = 120) {
  writeFileSync(target, `${Array.from({ length: lines }, (_, i) => `line ${i}`).join('\n')}\n`)
}

test('blocks a one-line write replacing a 120-line file with a reason naming the marker', t => {
  const cwd = makeFixture(t)
  const target = join(cwd, 'large.dart')
  longFile(target)

  const result = captureHandler()({
    toolName: 'write',
    input: { path: target, content: 'class Empty {}\n' },
  }, { cwd })

  assert.equal(result?.block, true)
  assert.match(result.reason, /write rejected/)
  assert.match(result.reason, /120 lines/)
  assert.match(result.reason, /1 line/)
  assert.match(result.reason, /whole_file_replace: true/)
  assert.match(result.reason, /first line/)
})

test('allows a marked one-line write and strips the marker from the executed input', t => {
  const cwd = makeFixture(t)
  const target = join(cwd, 'large.dart')
  longFile(target)

  const result = captureHandler()({
    toolName: 'write',
    input: { path: target, content: `${WHOLE_FILE_REPLACE_MARKER}\nclass Empty {}\n` },
  }, { cwd })

  assert.equal(result?.block, undefined)
  assert.equal(result?.input.content, 'class Empty {}\n')
  assert.equal(result.input.path, target)
  assert.doesNotMatch(result.input.content, /whole_file_replace/)
})

test('allows an intentional full-length rewrite', t => {
  const cwd = makeFixture(t)
  const target = join(cwd, 'large.dart')
  longFile(target)
  const content = `${Array.from({ length: 120 }, (_, i) => `rewritten ${i}`).join('\n')}\n`

  assert.equal(captureHandler()({
    toolName: 'write',
    input: { path: target, content },
  }, { cwd }), undefined)
})

test('allows writes to missing files and short files', t => {
  const cwd = makeFixture(t)
  const handler = captureHandler()
  const content = 'one line\n'

  assert.equal(handler({
    toolName: 'write',
    input: { path: join(cwd, 'missing.dart'), content },
  }, { cwd }), undefined)

  const short = join(cwd, 'short.dart')
  longFile(short, 3)
  assert.equal(handler({
    toolName: 'write',
    input: { path: short, content },
  }, { cwd }), undefined)
})

test('ignores non-write tools and non-plain target paths', t => {
  const cwd = makeFixture(t)
  const target = join(cwd, 'large.dart')
  longFile(target)
  const handler = captureHandler()
  const content = `${WHOLE_FILE_REPLACE_MARKER}\none line\n`

  assert.equal(handler({ toolName: 'edit', input: { path: target, content } }, { cwd }), undefined)
  assert.equal(handler({ toolName: 'write', input: { path: 'local://notes/1', content } }, { cwd }), undefined)
  assert.equal(handler({ toolName: 'write', input: { path: 'agent://session/file', content } }, { cwd }), undefined)

  const archive = join(cwd, 'snapshot.sqlite')
  longFile(archive)
  assert.equal(handler({ toolName: 'write', input: { path: archive, content } }, { cwd }), undefined)
})

test('pure decision helper detects the opt-out marker from content', () => {
  const base = {
    toolName: 'write',
    input: { path: 'big.dart', content: 'x' },
    existingLineCount: 120,
    proposedLineCount: 1,
  }
  assert.equal(evaluateWriteShrink(base)?.block, true)

  const optOut = evaluateWriteShrink({
    ...base,
    input: { path: 'big.dart', content: `${WHOLE_FILE_REPLACE_MARKER}\nx` },
    proposedLineCount: 1,
  })
  assert.equal(optOut?.block, undefined)

  assert.equal(evaluateWriteShrink({ ...base, toolName: 'read' }), undefined)
})
