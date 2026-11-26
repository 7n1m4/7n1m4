import assert from 'node:assert/strict'

import { Buffer } from 'node:buffer'
import { mkdirSync, mkdtempSync, readdirSync, rmSync, statSync, utimesSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { pruneCache } from '../prune-turbo-cache.js'

const root = mkdtempSync(join(tmpdir(), 'turbo-prune-test-'))
const cacheDir = join(root, '.turbo', 'cache')
mkdirSync(cacheDir, { recursive: true })

function makeEntry(hash, sizeBytes, day) {
  const mtime = new Date(2026, 0, day)
  const names = [`${hash}.tar.zst`, `${hash}-meta.json`]
  writeFileSync(join(cacheDir, names[0]), Buffer.alloc(sizeBytes, 1))
  writeFileSync(join(cacheDir, names[1]), '{}')
  for (const name of names)
    utimesSync(join(cacheDir, name), mtime, mtime)
}

try {
  // Five 30-byte entries (150 bytes total); cap at 100. After pruning one
  // entry (30 bytes) the cache is 120 and STILL over the cap: the old `break`
  // before the ceiling stopped here, leaving the cache over budget.
  for (let i = 0; i < 5; i++)
    makeEntry(`hash${i}`, 30, i + 1)

  pruneCache(cacheDir, 100)

  const remaining = readdirSync(cacheDir).filter(name => name.endsWith('.tar.zst'))
  assert.ok(remaining.length <= 3, `expected at most 3 entries after pruning, got ${remaining.length}`)
  const total = readdirSync(cacheDir).reduce((sum, name) => sum + statSync(join(cacheDir, name)).size, 0)
  assert.ok(total <= 100, `cache still over cap: ${total}`)
  assert.ok(total <= 96, `expected three entries after pruning down to cap, got ${total}`)
  assert.ok(!remaining.includes('hash0.tar.zst'), 'oldest entry should be pruned first')
  for (const hash of remaining.map(name => name.replace('.tar.zst', ''))) {
    assert.ok(readdirSync(cacheDir).includes(`${hash}-meta.json`), `metadata for ${hash} lost`)
  }

  // Empty cache directories are legal (a fresh build or an all-pruned cache):
  // the pruner must leave them in place and do nothing.
  for (const name of readdirSync(cacheDir))
    rmSync(join(cacheDir, name))
  pruneCache(cacheDir, 100)
  assert.deepEqual(readdirSync(cacheDir), [])

  console.info(`✓ pruner enforces the cap: ${remaining.length} entries, ${total} bytes <= 100`)
}
finally {
  rmSync(root, { recursive: true, force: true })
}
