import assert from 'node:assert/strict'
// eslint-disable-next-line test/no-import-node-test -- this guard runs under `node --test`
import test from 'node:test'

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

// Guard: keep the daemon RPC handler count in docs/ in sync with gateway.rs.
// Structural source check + exact current-claim checks against the five docs.
// Historical/dated counts in feature-parity-checklist.md are intentionally kept.

const root = join(dirname(fileURLToPath(import.meta.url)), '..', '..')
const read = rel => readFileSync(join(root, rel), 'utf8')

const gateway = read('crates/anima-daemon/src/gateway.rs')

// Count every m.insert( call site; extract static string keys passed as the
// first argument, plus the one dynamic loop that registers two mcp verbs.
const insertSites = (gateway.match(/m\.insert\(/g) || []).length
const staticKeys = [...gateway.matchAll(/m\.insert\(\s*"([^"]+)"\.to_string\(\)/g)].map(m => m[1])
const staticVerbCount = new Set(staticKeys).size
const dynamicLoop = gateway.match(/for method in \[([^\]]+)\]\s*\{\s*m\.insert\(\s*method\.to_string\(\)/)
const dynamicVerbs = dynamicLoop
  ? dynamicLoop[1].split(',').map(s => s.trim().replace(/^"|"$/g, ''))
  : []
const totalVerbs = staticVerbCount + dynamicVerbs.length

test('gateway.rs registers exactly 56 m.insert handler sites', () => {
  assert.equal(insertSites, 56, `expected 56 m.insert sites, found ${insertSites}`)
})

test('gateway.rs has 55 distinct static verbs + 2 dynamic mcp verbs = 57', () => {
  assert.equal(staticVerbCount, 55, `expected 55 static verb literals, found ${staticVerbCount}`)
  assert.deepEqual([...dynamicVerbs].sort(), ['mcp.call_tool', 'mcp.tools_call'])
  assert.equal(totalVerbs, 57, `expected 57 registered verb names, found ${totalVerbs}`)
})

// Each doc must state the current counts derived above, and must not retain a
// stale count. include/exclude are exact substrings so a future recount fails
// loudly instead of silently drifting.
const docChecks = [
  {
    file: 'docs/rosetta-stone.md',
    include: [
      '(line 845) registers **56** `renderer.*` RPC handler insertions',
      '`m.insert` at 900-2853; 57 distinct registered action names = 55 literals plus the dynamic `mcp.tools_call`/`mcp.call_tool` loop',
      'src/dispatch.rs:310-317',
    ],
    exclude: ['(line 818)', 'registers **53**', 'at 873-2785', 'dispatch.rs:299-304'],
  },
  {
    file: 'docs/design-daemon-gateway.md',
    include: [
      '`crates/anima-daemon/src/gateway.rs:845`) registers **56** RPC handler insertions',
      '`m.insert` at lines 900-2853;',
      'The feature set is 57 distinct action names:',
      '8 `mcp.*` names and 4 `acp.*` names.',
      'are separate from the 56 insertions.',
    ],
    exclude: [
      'gateway.rs:688-2122',
      'registers **47** RPC handler insertions',
      'lines 797-2540',
      '45 distinct action names',
      '4 `mcp.*` names',
      'separate from the 42 insertions',
    ],
  },
  {
    file: 'docs/feature-parity-checklist.md',
    include: [
      'HEAD current: 56 insertions / 57 literal names.',
      'handler inventory corrected to 42 `m.insert` insertions (40 distinct verbs)',
      'round 3 re-count: 47 `m.insert` insertions / 45 distinct action names',
    ],
    exclude: ['HEAD current: 53 insertions / 52 literal names.'],
  },
  {
    file: 'docs/README.md',
    include: ['via **56** `renderer.*` RPC handler insertions (57 registered verb names)'],
    exclude: ['**36** `renderer.*` RPC handlers'],
  },
  {
    file: 'docs/plan-flutter-native-model-rendering.md',
    include: ['the registry is now 56 `m.insert` insertions (57 distinct verbs)'],
    exclude: ['the registry is now 42 `m.insert` insertions (40 distinct verbs)'],
  },
]

for (const { file, include, exclude } of docChecks) {
  test(`${file} states the current ${insertSites} insertions / ${totalVerbs} verbs`, () => {
    const text = read(file)
    for (const snippet of include) {
      assert.ok(text.includes(snippet), `${file} missing current-count text: ${snippet}`)
    }
    for (const stale of exclude) {
      assert.ok(!text.includes(stale), `${file} still contains stale text: ${stale}`)
    }
  })
}
