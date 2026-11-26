#!/usr/bin/env node

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const CACHE_DIR = path.resolve('.turbo/cache')
const MAX_CACHE_SIZE_BYTES = 2 * 1024 * 1024 * 1024 // 2 GB limit

// A turbo cache entry is a `<hash>.tar.zst` plus its `<hash>-meta.json`.
// Never unlink the files inside an entry: a build crossing the size limit
// could otherwise leave a half-written archive that turbo trusts on restore.
function getCacheEntries(dirPath) {
  const entries = new Map()
  for (const name of fs.readdirSync(dirPath)) {
    const match = name.match(/^(.+?)(-meta\.json|\.tar\.zst)$/)
    if (!match)
      continue
    const hash = match[1]
    if (!entries.has(hash))
      entries.set(hash, { hash, size: 0, mtime: 0, files: [] })
    const entry = entries.get(hash)
    const stat = fs.statSync(path.join(dirPath, name))
    entry.size += stat.size
    entry.mtime = Math.max(entry.mtime, stat.mtimeMs)
    entry.files.push(name)
  }
  return [...entries.values()]
}

function dirSize(dirPath) {
  let total = 0
  for (const name of fs.readdirSync(dirPath)) {
    const stat = fs.statSync(path.join(dirPath, name))
    total += stat.isDirectory() ? dirSize(path.join(dirPath, name)) : stat.size
  }
  return total
}

// Deletes oldest-first until the cache is at or under the ceiling. A single
// readdir snapshot may miss files written by a concurrent build, so recheck
// after the initial pass and prune again if the limit is still crossed.
function pruneEntries(trash, cacheDir, maxSize, initialSize) {
  let totalSize = initialSize
  for (let pass = 0; pass < 10; pass++) {
    const entries = getCacheEntries(trash)
    entries.sort((a, b) => a.mtime - b.mtime)

    for (const entry of entries) {
      if (totalSize <= maxSize)
        break
      for (const name of entry.files) {
        fs.unlinkSync(path.join(trash, name))
      }
      totalSize -= entry.size
    }

    // Atomically restore each surviving entry as a unit. The archive and its
    // metadata either both appear in the new cache or neither does.
    for (const entry of entries) {
      if (entry.files.some(name => !fs.existsSync(path.join(trash, name))))
        continue
      for (const name of entry.files) {
        fs.renameSync(path.join(trash, name), path.join(cacheDir, name))
      }
    }

    totalSize = dirSize(trash)
    if (totalSize <= maxSize)
      return
  }
  throw new Error('[Turbo Cache Pruner] Cache still exceeds the size limit after repeated passes')
}

export function pruneCache(cacheDir = CACHE_DIR, maxSize = MAX_CACHE_SIZE_BYTES) {
  if (!fs.existsSync(cacheDir))
    return

  const totalSize = dirSize(cacheDir)
  if (totalSize <= maxSize)
    return

  console.info(`[Turbo Cache Pruner] Cache size is ${(totalSize / (1024 * 1024 * 1024)).toFixed(2)} GB, which exceeds the limit of 2.00 GB.`)

  const parent = path.dirname(cacheDir)
  // Move the whole directory aside first: no reader can observe a partial
  // deletion, and a concurrent build can create a fresh cache immediately.
  const trash = path.join(parent, `.cache-prune-${process.pid}-${Date.now()}`)
  fs.renameSync(cacheDir, trash)
  fs.mkdirSync(cacheDir, { recursive: true })

  try {
    const before = dirSize(trash)
    pruneEntries(trash, cacheDir, maxSize, before)
    console.info(`[Turbo Cache Pruner] Pruned to ${(dirSize(cacheDir) / (1024 * 1024 * 1024)).toFixed(2)} GB.`)
  }
  finally {
    fs.rmSync(trash, { recursive: true, force: true })
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(import.meta.filename)) {
  pruneCache()
}
