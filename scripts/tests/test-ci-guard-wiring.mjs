import assert from 'node:assert/strict'
import test from 'node:test'

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const ciYaml = readFileSync(fileURLToPath(new URL('../../.github/workflows/ci.yml', import.meta.url)), 'utf-8')
const pkg = JSON.parse(readFileSync(fileURLToPath(new URL('../../package.json', import.meta.url)), 'utf-8'))

// Slice the `unit-test` job only, from its header to the next top-level job
// header, so a step placed in a different job cannot satisfy the assertion.
function unitTestStepLines(yaml) {
  const lines = yaml.split('\n')
  const start = lines.findIndex(line => /^ {2}unit-test:\s*$/.test(line))
  assert.notEqual(start, -1, 'ci.yml must define a unit-test job')
  const end = lines.findIndex((line, i) => i > start && /^ {2}[\w-]+:\s*$/.test(line))
  assert.notEqual(end, -1, 'ci.yml must define a job after unit-test')
  return lines.slice(start, end)
}

test('unit-test job wires the nano-staged scope guard step', () => {
  const steps = unitTestStepLines(ciYaml)
  assert.ok(
    steps.includes('      - run: pnpm run test:nano-staged-scope'),
    'unit-test job is missing the `      - run: pnpm run test:nano-staged-scope` step',
  )
})

test('package.json defines the test:nano-staged-scope script', () => {
  assert.equal(pkg.scripts?.['test:nano-staged-scope'], 'node scripts/tests/check-nano-staged-scope.mjs')
})
