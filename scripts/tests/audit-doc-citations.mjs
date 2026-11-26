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
const SOURCE_ROOTS = ['apps', 'crates', 'packages', 'docs', 'scripts']
const SKIP_DIRS = new Set(['node_modules', '.git', 'dist', 'build', '.dart_tool', '.venv', 'target'])

// A path citation must have a directory segment plus a file-like final segment
// and a line anchor; a bare `:digits` is a continuation anchor. Ports, section
// numbers and single-segment shorthands (`gateway.rs:79`) deliberately do not
// match. The lookbehind stops a path from being matched starting mid-segment.
const CITATION_RE = /(?<![\/\w@.+-])(?:([\w@.+-]+(?:\/[\w@.+-]+)+):(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*)|:(\d+(?:-\d+)?(?:,\d+(?:-\d+)?)*))\b/g

// Explicit narrow prose contract. The token shape above already excludes these,
// but keep the allowlist stated so it cannot be widened accidentally.
const ALLOWED_PROSE_RE = /^(?:wss?:\/\/\S+|\b(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]):\d+\b|\bport\s+\d+\b|§\d+|\b(?:Section|Step|line)\s+\d+\b)$/i

const args = process.argv.slice(2)
const isVerbose = args.includes('--verbose') || args.includes('-v')
const scanAllDocs = args.includes('--all-docs')
// A doc outside the repo may cite files next to it. Index its directory too so
// shorthand citations resolve against the tree the doc actually lives in.
const EXTERNAL_ROOTS = [...new Set(args
  .filter(arg => !arg.startsWith('--') && path.isAbsolute(arg) && fs.existsSync(arg))
  .map(arg => path.dirname(arg))
  .filter(dir => !dir.startsWith(`${REPO_ROOT}${path.sep}`)))]

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
function fileLineCount(relPath, root = REPO_ROOT) {
  const key = `${root}\0${relPath}`
  if (!fileLineCache.has(key)) {
    const abs = path.resolve(root, relPath)
    // Reject traversal before touching the filesystem: a `docs/../../etc/passwd:1`
    // citation must not turn this auditor into a line-count oracle.
    if (!abs.startsWith(`${root}${path.sep}`)) {
      fileLineCache.set(key, OUTSIDE_REPO)
    }
    else if (!fs.existsSync(abs) || fs.statSync(abs).isDirectory()) {
      fileLineCache.set(key, null)
    }
    else {
      const text = fs.readFileSync(abs, 'utf8')
      // A trailing newline ends the last real line; split() would count an
      // extra empty segment and let a citation one past EOF pass. An empty
      // file has zero lines.
      const lines = text === '' ? 0 : text.split('\n').length - (text.endsWith('\n') ? 1 : 0)
      fileLineCache.set(key, lines)
    }
  }
  return fileLineCache.get(key)
}

// Shorthand citations in docs omit the source root (`gateway.rs:79`,
// `features/chat/chat_composer_controller.dart:68-73`). Build a lazy index of
// source files so a still-existing file resolves and a deleted one does not.
let repoFileIndex = null
function addSourceFiles(base, root) {
  if (!fs.existsSync(base))
    return
  const stack = [base]
  while (stack.length > 0) {
    const dir = stack.pop()
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) {
        if (!SKIP_DIRS.has(entry.name))
          stack.push(full)
      }
      else if (entry.isFile()) {
        repoFileIndex.push({ root, file: path.relative(root, full).replace(/\\/g, '/') })
      }
    }
  }
}
function sourceFiles() {
  if (!repoFileIndex) {
    repoFileIndex = []
    for (const rootName of SOURCE_ROOTS)
      addSourceFiles(path.join(REPO_ROOT, rootName), REPO_ROOT)
    for (const root of EXTERNAL_ROOTS)
      addSourceFiles(root, root)
  }
  return repoFileIndex
}

function matchingRepoFiles(relPath) {
  return sourceFiles().filter(entry => entry.file === relPath || entry.file.endsWith(`/${relPath}`))
}

function isAllowedProse(token) {
  return ALLOWED_PROSE_RE.test(token)
}

/** Validate every repo-relative path:line citation in `text`. Returns error strings. */
function validateText(docLabel, text) {
  const errors = []
  for (const [lineIndex, line] of text.split('\n').entries()) {
    CITATION_RE.lastIndex = 0
    let match
    while ((match = CITATION_RE.exec(line)) !== null) {
      const [, relPath, spec, bareSpec] = match
      // Bare `:digits` continuation anchors and prose numbers are allowed.
      if (bareSpec || isAllowedProse(match[0])) {
        continue
      }
      const where = `${docLabel}:${lineIndex + 1}`
      if (!CITATION_ROOTS.has(relPath.split('/')[0])) {
        const matches = matchingRepoFiles(relPath)
        if (matches.length === 0) {
          errors.push(`${where}: cited file is missing — \`${relPath}:${spec}\``)
        }
        else if (matches.length > 1) {
          // A suffix shared by several files cannot identify the intended one;
          // treating it as valid would let a deleted original pass silently.
          errors.push(`${where}: cited path is ambiguous — \`${relPath}:${spec}\` (${matches.length} files share this path)`)
        }
        else {
          // Exactly one file: apply the same line-range contract as canonical
          // paths, resolved against the root that file was indexed from.
          const maxLine = fileLineCount(matches[0].file, matches[0].root)
          for (const n of citedNumbers(spec)) {
            if (!Number.isInteger(n) || n < 1 || n > maxLine) {
              errors.push(`${where}: cited line out of range — \`${relPath}:${spec}\` (file has ${maxLine} lines)`)
            }
          }
          if (isVerbose) {
            console.info(`  ↳ ${where}: ${relPath}:${spec} (${maxLine} lines)`)
          }
        }
        continue
      }
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
// Prove the broadened relative-path detector is non-vacuous: libs/auth.ts was
// deleted in 73495d98, so this citation must still be reported as broken.
const probeRelative = validateText('self-test', 'see `libs/auth.ts:10-15` for the gate')
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
  || !probeTraversal.some(e => e.includes('escapes the repository'))
  || !probeRelative.some(e => e.includes('libs/auth.ts:10-15'))) {
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
  const count = [...text.matchAll(CITATION_RE)].filter(m => m[1] && !isAllowedProse(m[0])).length
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
