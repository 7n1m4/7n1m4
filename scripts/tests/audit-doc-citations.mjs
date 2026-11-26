#!/usr/bin/env node

/**
 * AIRI docs path:line citation drift auditor.
 *
 * Parses repo-relative `path:line` citations in Markdown (line ranges and
 * comma-separated anchors included) and fails when the referenced file is
 * missing or a cited line falls outside the file. This is a docs-anchor check
 * only — it does not duplicate the wire-type or golden-fixture drift checks in
 * `crates/anima-channel` (those validate generated/fixture content).
 *
 * Usage:
 *   node scripts/tests/audit-doc-citations.mjs
 *   node scripts/tests/audit-doc-citations.mjs --all-docs
 *   node scripts/tests/audit-doc-citations.mjs --doc docs/rosetta-stone.md --verbose
 */

import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = path.resolve(__dirname, '..', '..')
const DEFAULT_DOCS = [
  'docs/feature-parity-checklist.md',
  'docs/data-catalog.md',
]
const CITATION_ROOTS = new Set(['crates', 'apps', 'packages', 'docs', 'scripts'])

// Repo-relative path followed by one or more line anchors: 42, 42-100, 42,100-142.
const CITATION_RE = /\b((?:crates|apps|packages|docs|scripts)\/[\w./@-]+):(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)\b/g

const args = process.argv.slice(2)
const isVerbose = args.includes('--verbose') || args.includes('-v')
const scanAllDocs = args.includes('--all-docs')

function findMarkdown(dir) {
  const results = []
  if (!fs.existsSync(dir))
    return results
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name)
    if (entry.isDirectory()) {
      results.push(...findMarkdown(full))
    }
    else if (entry.isFile() && entry.name.endsWith('.md')) {
      results.push(path.relative(REPO_ROOT, full).replace(/\\/g, '/'))
    }
  }
  return results
}

function collectDocs() {
  if (scanAllDocs)
    return findMarkdown(path.join(REPO_ROOT, 'docs')).sort()

  const explicit = []
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--doc' && args[i + 1]) {
      explicit.push(args[++i])
    }
    else if (args[i] === '--verbose' || args[i] === '-v' || args[i] === '--all-docs') {
      continue
    }
    else if (!args[i].startsWith('--')) {
      explicit.push(args[i])
    }
  }
  return explicit.length > 0 ? explicit : DEFAULT_DOCS
}

function citedNumbers(spec) {
  return spec.split(',').flatMap((part) => {
    const bounds = part.split('-').map(Number)
    return bounds.length === 2
      ? [bounds[0], bounds[1]]
      : bounds
  })
}

const fileLineCache = new Map()
const OUTSIDE_REPO = Symbol('outside-repo')
function fileLineCount(relPath) {
  if (!fileLineCache.has(relPath)) {
    const abs = path.resolve(REPO_ROOT, relPath)
    // Reject traversal before touching the filesystem: a `docs/../../etc/passwd:1`
    // citation must not turn this auditor into a line-count oracle.
    if (!abs.startsWith(`${REPO_ROOT}${path.sep}`)) {
      fileLineCache.set(relPath, OUTSIDE_REPO)
    }
    else if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
      fileLineCache.set(relPath, null)
    }
    else {
      const text = fs.readFileSync(abs, 'utf8')
      // A trailing newline ends the last real line; split() would count an
      // extra empty segment and let a citation one past EOF pass. An empty
      // file has zero lines.
      const lines = text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0)
      fileLineCache.set(relPath, lines)
    }
  }
  return fileLineCache.get(relPath)
}

/** Validate every repo-relative path:line citation in `text`. Returns error strings. */
function validateText(docLabel, text) {
  const errors = []
  for (const [lineIndex, line] of text.split('\n').entries()) {
    CITATION_RE.lastIndex = 0
    let match
    while ((match = CITATION_RE.exec(line)) !== null) {
      const [, relPath, spec] = match
      if (!CITATION_ROOTS.has(relPath.split('/')[0])) {
        continue
      }
      const where = `${docLabel}:${lineIndex + 1}`
      const maxLine = fileLineCount(relPath)
      if (maxLine === OUTSIDE_REPO) {
        errors.push(`${where}: cited path escapes the repository — \`${relPath}:${spec}\``)
        continue
      }
      if (maxLine === null) {
        errors.push(`${where}: cited file is missing — \`${relPath}:${spec}\``)
        continue
      }
      for (const n of citedNumbers(spec)) {
        if (!Number.isInteger(n) || n < 1 || n > maxLine) {
          errors.push(`${where}: cited line out of range — \`${relPath}:${spec}\` (file has ${maxLine} lines)`)
        }
      }
      if (isVerbose) {
        console.info(`  ↳ ${where}: ${relPath}:${spec} (${maxLine} lines)`)
      }
    }
  }
  return errors
}

// Self-check: prove the detector is non-vacuous before trusting a green run.
const probeDoc = 'docs/data-catalog.md'
const probeSource = fs.readFileSync(path.resolve(REPO_ROOT, probeDoc), 'utf8')
const probeLineCount = probeSource.split('\n').length - (probeSource.endsWith('\n') ? 1 : 0)
const probeBad = validateText('self-test', 'see `docs/__audit_no_such_file__.md:12` and `docs/data-catalog.md:999999`')
const probeGood = validateText('self-test', 'see `docs/data-catalog.md:1`')
const probePastEof = validateText('self-test', `see \`${probeDoc}:${probeLineCount + 1}\``)
// Traverse out of the repo to a file that really exists, so a missing-file
// error cannot satisfy this probe: enough `..` to reach the filesystem root.
const fsRoot = path.parse(REPO_ROOT).root
const repoDepth = path.relative(fsRoot, REPO_ROOT).split(path.sep).filter(Boolean).length
const outsideFile = (process.platform === 'win32' ? ['Windows/win.ini'] : ['etc/passwd', 'etc/hosts'])
  .find(candidate => fs.existsSync(path.join(fsRoot, candidate)))
if (!outsideFile) {
  console.error('❌ Citation auditor self-check failed — no known file outside the repo for the traversal probe.')
  process.exit(1)
}
const probeTraversalCitation = `docs/${'../'.repeat(repoDepth + 1)}${outsideFile}`
const probeTraversal = validateText('self-test', `see \`${probeTraversalCitation}:1\``)
if (!probeBad.some(e => e.includes('cited file is missing'))
  || !probeBad.some(e => e.includes('out of range'))
  || probeGood.length !== 0
  || probePastEof.length !== 1
  || !probeTraversal.some(e => e.includes('escapes the repository'))) {
  console.error('❌ Citation auditor self-check failed — detector would give a false green.')
  process.exit(1)
}

const docs = collectDocs()
console.info('🔗 AIRI docs path:line citation audit')
console.info(`📁 Repo root: ${REPO_ROOT}`)
console.info(`📄 Docs scanned: ${docs.join(', ')}\n`)

let totalCitations = 0
let totalErrors = 0
for (const doc of docs) {
  const abs = path.resolve(REPO_ROOT, doc)
  if (!fs.existsSync(abs)) {
    console.error(`❌ ${doc}: doc file missing`)
    totalErrors++
    continue
  }
  const text = fs.readFileSync(abs, 'utf8')
  CITATION_RE.lastIndex = 0
  const count = [...text.matchAll(CITATION_RE)].filter(m => CITATION_ROOTS.has(m[1].split('/')[0])).length
  totalCitations += count
  const errors = validateText(doc, text)
  totalErrors += errors.length
  if (errors.length === 0) {
    console.info(`✅ ${doc}: ${count} path:line citation(s) valid`)
  }
  else {
    console.error(`❌ ${doc}: ${errors.length} broken citation(s)`)
    for (const err of errors) {
      console.error(`   - ${err}`)
    }
  }
}

console.info(`\n📊 Checked ${totalCitations} citation(s) across ${docs.length} doc(s); ${totalErrors} broken.`)
if (totalErrors > 0) {
  console.error('❌ Docs citation drift detected. Fix the cited anchors or the stale file references.')
  process.exit(1)
}
console.info('✅ All cited files and lines exist.')
