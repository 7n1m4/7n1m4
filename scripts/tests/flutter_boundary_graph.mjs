import process from 'node:process'

import { spawnSync } from 'node:child_process'
import {
  existsSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
const REPO_ROOT = join(SCRIPT_DIR, '../..')
const FIXTURE = join(SCRIPT_DIR, 'fixtures/flutter_boundary_graph_bypass.dart')
const ZONE_ROOT = 'apps/flutter/lib/features/chat'
const ZONES = new Set(['ui', 'state', 'transport', 'data'])
const RESTRICTED_ZONES = new Set(['ui', 'state'])
const VIOLATION = '[BOUNDARY_GRAPH_VIOLATION]'

// v1 capability surface: dart:io plus the exact storage/network prefixes
// already banned by the round-14 per-file guard (flutter-boundary.test.mjs).
const STORAGE_PREFIXES = [
  'package:shared_preferences/',
  'package:hive/',
  'package:hive_flutter/',
  'package:sqflite/',
  'package:isar/',
  'package:flutter_secure_storage/',
  'package:web_socket_channel/',
  'package:http/',
  'package:dio/',
  'package:drift/',
  'package:sembast/',
]

const EXPECTED_LINE = `${VIOLATION} zone=ui capability=dart:io chain=${ZONE_ROOT}/ui/chat_screen.dart -> ${ZONE_ROOT}/state/chat_barrel.dart -> ${ZONE_ROOT}/data/storage_barrel.dart -> dart:io`
const CONDITIONAL_LINE = `${VIOLATION} zone=ui capability=dart:io chain=${ZONE_ROOT}/ui/cond_screen.dart -> ${ZONE_ROOT}/state/cond_barrel.dart -> ${ZONE_ROOT}/data/cond_data.dart -> dart:io`
const DIRECTIVE_START_RE = /\b(import|export|part)\b/g
const URI_LITERAL_RE = /(['"])([^'"]*)\1/g
const VIRTUAL_FILE_RE = /^\s*\/\/ === VIRTUAL_FILE: (\S+) ===\s*$/

function check(condition, message) {
  if (!condition)
    throw new Error(message)
}

function blank(chars, start, end) {
  for (let i = start; i < end; i += 1) {
    if (chars[i] !== '\n')
      chars[i] = ' '
  }
}

// Same two-view lexer shape as the round-14 guard: comments are blanked in
// noComments, comments AND string bodies in code, so directive keywords that
// merely appear inside a string literal cannot be mistaken for directives.
function lexDart(source) {
  const noComments = source.split('')
  const code = source.split('')
  const n = source.length
  let i = 0
  while (i < n) {
    const c = source[i]
    const d = source[i + 1]
    if (c === '/' && d === '/') {
      let j = i
      while (j < n && source[j] !== '\n')
        j += 1
      blank(noComments, i, j)
      blank(code, i, j)
      i = j
      continue
    }
    if (c === '/' && d === '*') {
      let j = i + 2
      while (j < n && (source[j] !== '*' || source[j + 1] !== '/'))
        j += 1
      const end = Math.min(n, j + 2)
      blank(noComments, i, end)
      blank(code, i, end)
      i = end
      continue
    }
    if (c === '\'' || c === '"') {
      const triple = source[i + 1] === c && source[i + 2] === c
      const delim = triple ? 3 : 1
      let j = i + delim
      while (j < n) {
        if (source[j] === '\\') {
          j += 2
          continue
        }
        if (!triple && source[j] === '\n')
          break
        if (triple && source[j] === c && source[j + 1] === c && source[j + 2] === c) {
          j += 3
          break
        }
        if (!triple && source[j] === c) {
          j += 1
          break
        }
        j += 1
      }
      const end = Math.min(n, j)
      blank(code, i, end)
      i = end
      continue
    }
    i += 1
  }
  return { noComments: noComments.join(''), code: code.join('') }
}

// A conditional directive (`import 'stub.dart' if (dart.library.io) 'd.dart';`)
// carries several URI literals. The statement end is located in `code`, where
// string bodies are blanked, so semicolons inside URIs cannot truncate it.
function extractDirectives(noComments, code) {
  const directives = []
  for (const match of noComments.matchAll(DIRECTIVE_START_RE)) {
    if (code[match.index] !== match[0][0])
      continue
    const end = code.indexOf(';', match.index)
    if (end === -1)
      continue
    for (const uri of noComments.slice(match.index, end).matchAll(URI_LITERAL_RE))
      directives.push({ kind: match[1], uri: uri[2] })
  }
  return directives
}

function bannedCapability(uri) {
  if (uri === 'dart:io' || uri.startsWith('dart:io/'))
    return 'dart:io'
  return STORAGE_PREFIXES.find(prefix => uri.startsWith(prefix)) ?? null
}

function zoneOf(rel) {
  const prefix = `${ZONE_ROOT}/`
  if (!rel.startsWith(prefix))
    return null
  const zone = rel.slice(prefix.length).split('/')[0]
  return ZONES.has(zone) ? zone : null
}

function resolveLocal(fromRel, uri, files) {
  if (uri.startsWith('/') || uri.includes(':') || uri.includes('\\'))
    return null
  const resolved = posix.normalize(posix.join(posix.dirname(fromRel), uri))
  return files.has(resolved) ? resolved : null
}

function loadGraph(root) {
  const files = new Map()
  const escapes = []
  const base = join(root, ...ZONE_ROOT.split('/'))
  if (!existsSync(base))
    return { files, escapes }

  const rootReal = realpathSync(root)
  function withinRoot(target) {
    const rel = relative(rootReal, target)
    return rel === '' || (!rel.startsWith('..') && !posix.isAbsolute(rel))
  }

  const visitedDirs = new Set([rootReal])
  function walk(dir) {
    let realDir
    try {
      realDir = realpathSync(dir)
    }
    catch {
      return
    }
    if (visitedDirs.has(realDir))
      return
    visitedDirs.add(realDir)

    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
      const abs = join(dir, entry.name)
      const rel = relative(root, abs).split(sep).join('/')
      if (entry.isSymbolicLink()) {
        let real
        try {
          real = realpathSync(abs)
          if (!withinRoot(real)) {
            escapes.push(`${VIOLATION} symlink escapes root: ${rel} -> ${relative(rootReal, real).split(sep).join('/')}`)
            continue
          }
        }
        catch {
          escapes.push(`${VIOLATION} symlink target unresolvable: ${rel}`)
          continue
        }
      }

      let st
      try {
        st = statSync(abs)
      }
      catch {
        escapes.push(`${VIOLATION} target unresolvable: ${rel}`)
        continue
      }
      if (st.isDirectory()) {
        walk(abs)
        continue
      }
      if (!st.isFile() || !entry.name.endsWith('.dart'))
        continue

      // NOTICE: symlinks are followed, never skipped — a link back into the
      // tree carries the target's capabilities into the linking zone.
      const { noComments, code } = lexDart(readFileSync(abs, 'utf8'))
      files.set(rel, {
        rel,
        zone: zoneOf(rel),
        directives: extractDirectives(noComments, code),
        directCaps: new Set(),
        exportTargets: new Set(),
        importTargets: new Set(),
        partTargets: new Set(),
      })
    }
  }
  walk(base)

  // Link the graph after discovery so relative URIs (including library-relative
  // part URIs) can be resolved against the complete file set.
  for (const info of files.values()) {
    for (const directive of info.directives) {
      if (directive.kind === 'export' && bannedCapability(directive.uri))
        info.directCaps.add(bannedCapability(directive.uri))
      const target = resolveLocal(info.rel, directive.uri, files)
      if (!target)
        continue
      if (directive.kind === 'export') {
        info.exportTargets.add(target)
      }
      else if (directive.kind === 'import') {
        info.importTargets.add(target)
      }
      else if (directive.kind === 'part') {
        // `part 'x'` lives in the library; `part of 'lib'` lives in the part.
        // Both directions carry declarations into the library namespace.
        info.partTargets.add(target)
        files.get(target).partTargets.add(info.rel)
      }
    }
  }
  return { files, escapes }
}

function exportedCapabilities(files) {
  const caps = new Map([...files.keys()].map(rel => [rel, new Set()]))
  let changed = true
  while (changed) {
    changed = false
    for (const [rel, info] of files) {
      const set = caps.get(rel)
      const before = set.size
      for (const cap of info.directCaps)
        set.add(cap)
      for (const target of info.exportTargets) {
        for (const cap of caps.get(target) ?? [])
          set.add(cap)
      }
      for (const target of info.partTargets) {
        for (const cap of caps.get(target) ?? [])
          set.add(cap)
      }
      if (set.size !== before)
        changed = true
    }
  }
  return caps
}

function exportPath(start, cap, files, seen = new Set()) {
  if (seen.has(start))
    return null
  seen.add(start)
  const info = files.get(start)
  if (!info)
    return null
  if (info.directCaps.has(cap))
    return [start, cap]
  for (const target of [...info.exportTargets, ...info.partTargets].sort()) {
    const tail = exportPath(target, cap, files, new Set(seen))
    if (tail)
      return [start, ...tail]
  }
  return null
}

function format(zone, capability, chain) {
  return `${VIOLATION} zone=${zone} capability=${capability} chain=${chain.join(' -> ')}`
}

// One import hop out of a restricted zone into a file whose exported capability
// set contains a banned capability is the leak; ordinary import chains
// (ui -> state -> data) stay clean because imports are not transitive.
export function audit(root = REPO_ROOT) {
  const { files, escapes } = loadGraph(root)
  const caps = exportedCapabilities(files)
  const lines = new Set(escapes)

  for (const info of files.values()) {
    if (!RESTRICTED_ZONES.has(info.zone))
      continue
    for (const directive of info.directives) {
      if (directive.kind !== 'import' && directive.kind !== 'export')
        continue
      const cap = bannedCapability(directive.uri)
      if (cap)
        lines.add(format(info.zone, cap, [info.rel, cap]))
    }
    for (const target of [...info.importTargets].sort()) {
      for (const cap of [...(caps.get(target) ?? [])].sort()) {
        const path = exportPath(target, cap, files)
        if (path)
          lines.add(format(info.zone, cap, [info.rel, ...path]))
      }
    }
  }
  return [...lines].sort()
}

function validateVirtualPath(rel) {
  if (rel.includes('..') || rel.includes('\\') || posix.isAbsolute(rel))
    throw new Error(`unsafe virtual path: ${rel}`)
  return rel
}

function materializeFixture(source) {
  const virtualFiles = new Map()
  let current = null
  const lines = []
  for (const line of source.split(/\r?\n/)) {
    const marker = line.match(VIRTUAL_FILE_RE)
    if (marker) {
      if (current)
        virtualFiles.set(current, lines.join('\n'))
      current = validateVirtualPath(marker[1])
      lines.length = 0
      continue
    }
    if (!current)
      continue
    const stripped = line.replace(/^\s*\/\/\s?/, '')
    // Non-comment lines are fixture scaffolding (e.g. `void main() {}`), not
    // virtual file content.
    if (stripped === line && line.trim() !== '')
      continue
    lines.push(stripped)
  }
  if (current)
    virtualFiles.set(current, lines.join('\n'))
  return virtualFiles
}

function writeVirtualFiles(root, files) {
  for (const [rel, content] of files) {
    const abs = join(root, ...rel.split('/'))
    mkdirSync(dirname(abs), { recursive: true })
    writeFileSync(abs, content, 'utf8')
  }
}

function selfTest() {
  const tempRoot = mkdtempSync(join(tmpdir(), 'airi-3c7w-'))
  try {
    writeVirtualFiles(tempRoot, materializeFixture(readFileSync(FIXTURE, 'utf8')))
    const lines = audit(tempRoot)
    check(lines.length === 1 && lines[0] === EXPECTED_LINE, `expected ${JSON.stringify([EXPECTED_LINE])}, got ${JSON.stringify(lines)}`)

    // An explicitly supplied --root with no chat tree must fail closed.
    const missing = spawnSync(process.execPath, [fileURLToPath(import.meta.url), '--root', join(tempRoot, 'missing-root')], { encoding: 'utf8' })
    check(missing.status === 1, `--root on a missing tree exited ${missing.status}, expected 1`)
    check(missing.stderr.includes('[BOUNDARY_GRAPH_ERROR]'), 'missing --root did not emit a clear error')

    // Conditional import/export branches must carry their extra URI literals.
    const condRoot = join(tempRoot, 'conditional')
    const prefix = `${ZONE_ROOT}/`
    writeVirtualFiles(condRoot, new Map([
      [`${prefix}ui/cond_screen.dart`, `import '../state/cond_barrel.dart';\n`],
      [`${prefix}state/cond_barrel.dart`, `export '../data/cond_data.dart';\n`],
      [`${prefix}data/cond_data.dart`, `import 'stub.dart';\nexport 'stub.dart' if (dart.library.io) 'dart:io';\n`],
      [`${prefix}data/stub.dart`, 'class Stub {}\n'],
    ]))
    const conditionalLines = audit(condRoot)
    check(conditionalLines.length === 1 && conditionalLines[0] === CONDITIONAL_LINE, `conditional branch: expected ${JSON.stringify([CONDITIONAL_LINE])}, got ${JSON.stringify(conditionalLines)}`)

    // Virtual fixture paths must never escape the materialization root.
    for (const bad of ['../escape.dart', '/tmp/escape.dart', 'ui\\escape.dart']) {
      let rejected = false
      try {
        materializeFixture(`// === VIRTUAL_FILE: ${bad} ===\n// class A {}\n`)
      }
      catch {
        rejected = true
      }
      check(rejected, `unsafe virtual path accepted: ${bad}`)
    }

    process.stderr.write(`${EXPECTED_LINE}\n`)
    return 0
  }
  catch (error) {
    process.stderr.write(`[SELF_TEST_FAIL] ${error?.message ?? String(error)}\n`)
    return 1
  }
  finally {
    rmSync(tempRoot, { recursive: true, force: true })
  }
}

function main(argv) {
  if (argv.includes('--self-test'))
    return selfTest()
  const rootIndex = argv.indexOf('--root')
  const explicitRoot = rootIndex !== -1
  const root = explicitRoot ? argv[rootIndex + 1] : REPO_ROOT
  if (!root) {
    process.stderr.write('[BOUNDARY_GRAPH_ERROR] --root requires a directory\n')
    return 2
  }
  if (!existsSync(join(root, ...ZONE_ROOT.split('/')))) {
    process.stderr.write(`[BOUNDARY_GRAPH_ERROR] --root has no ${ZONE_ROOT}: ${root}\n`)
    return 1
  }
  const lines = audit(root)
  for (const line of lines)
    process.stderr.write(`${line}\n`)
  return lines.length > 0 ? 1 : 0
}

process.exitCode = main(process.argv.slice(2))
