import process from 'node:process'

import {
  existsSync,
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { dirname, join, posix, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url))
export const REPO_ROOT = join(SCRIPT_DIR, '../..')
const LIB_PREFIX = 'apps/flutter/lib'
const PACKAGE_PREFIX = 'package:anima_control/'
const DEAD_EXPORT = '[DEAD_EXPORT]'
const REGION_LOCK = '[REGION_LOCK]'
const ERROR = '[NO_DEAD_EXPORTS_ERROR]'

// The witness is newly added; everything else in apps/flutter/lib that has no
// direct production caller predates this guard and is grandfathered here with
// its reason. Keeping the set explicit (rather than a zone-wide skip) means the
// live-tree audit reports exactly the one verified witness line.
export const GRANDFATHERED = new Map([
  ['apps/flutter/lib/main.dart', 'Flutter entrypoint launched by the runtime, never imported by another lib file.'],
  ['apps/flutter/lib/daemon_client/direct_websocket_transport.dart', 'Transport chosen by the client factory at runtime, not imported directly.'],
  ['apps/flutter/lib/daemon_client/protocol.dart', 'Wire schema consumed through the client surface; pre-existing module.'],
  ['apps/flutter/lib/daemon_client/reconnect_policy.dart', 'Policy injected into the client constructor; pre-existing module.'],
  ['apps/flutter/lib/features/onboarding/onboarding_rules.dart', 'Pre-existing onboarding data module outside this lane.'],
  ['apps/flutter/lib/speech/audio_cache.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/lip_sync_generator.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/math_speech.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/piper_tts_engine.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/price_speech.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/provider_instance.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/speech_intent_queue.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/ssml.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/speech/ust_transform.dart', 'Pre-existing speech helper reached only from tests.'],
  ['apps/flutter/lib/ui/app_snackbar.dart', 'Pre-existing UI helper reached only from tests.'],
])

const DIRECTIVE_START_RE = /\b(import|export|part)\b/g
const URI_LITERAL_RE = /(['"])([^'"]*)\1/g
const VIRTUAL_FILE_RE = /^\s*\/\/ === VIRTUAL_FILE: (\S+) ===\s*$/

function blank(chars, start, end) {
  for (let i = start; i < end; i += 1) {
    if (chars[i] !== '\n')
      chars[i] = ' '
  }
}

// Two views, same shape as flutter_boundary_graph.mjs: noComments keeps string
// bodies so URIs can be read; code blanks comments AND string bodies so a
// keyword inside a literal cannot fake a directive.
export function lexDart(source) {
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

// A keyword only opens a top-level directive: file start or right after `;`.
// `{`/`}` are not allowed predecessors - `const m = {import: 'dead.dart'};`
// is a map key, not a directive, and must never fabricate a caller or barrel.
function inDirectivePosition(code, index) {
  let i = index - 1
  while (i >= 0 && /\s/.test(code[i]))
    i -= 1
  if (i < 0)
    return true
  return code[i] === ';'
}

// A conditional directive carries several URI literals. The statement end is
// found in `code`, where string bodies are blanked, so a `;` inside a URI
// cannot truncate it and every URI before the real semicolon is captured.
export function extractDirectives(noComments, code) {
  const directives = []
  for (const match of noComments.matchAll(DIRECTIVE_START_RE)) {
    if (code[match.index] !== match[0][0] || !inDirectivePosition(code, match.index))
      continue
    const end = code.indexOf(';', match.index)
    if (end === -1)
      continue
    for (const uri of noComments.slice(match.index, end).matchAll(URI_LITERAL_RE))
      directives.push({ kind: match[1], uri: uri[2] })
  }
  return directives
}

// Token view for region anchors: whitespace is irrelevant, quote style is
// canonicalised to `'`, and `noComments`/`code` decide whether string bodies
// participate. A token sequence match cannot be evaded by a newline before `(`,
// a double-quoted URI, or an identifier containing the anchor as a substring.
function tokenize(source) {
  const tokens = []
  const n = source.length
  let i = 0
  while (i < n) {
    const c = source[i]
    if (/\s/.test(c)) {
      i += 1
      continue
    }
    if (c === '/' && source[i + 1] === '/') {
      while (i < n && source[i] !== '\n')
        i += 1
      continue
    }
    if (c === '/' && source[i + 1] === '*') {
      i += 2
      while (i < n && (source[i] !== '*' || source[i + 1] !== '/'))
        i += 1
      i = Math.min(n, i + 2)
      continue
    }
    if (c === '\'' || c === '"') {
      const triple = source[i + 1] === c && source[i + 2] === c
      const delim = triple ? 3 : 1
      let j = i + delim
      let body = ''
      while (j < n) {
        if (source[j] === '\\') {
          body += source[j] + (source[j + 1] ?? '')
          j += 2
          continue
        }
        if (!triple && source[j] === c) {
          j += 1
          break
        }
        if (triple && source[j] === c && source[j + 1] === c && source[j + 2] === c) {
          j += 3
          break
        }
        body += source[j]
        j += 1
      }
      tokens.push(`'${body}'`)
      i = j
      continue
    }
    if (/[$_a-z]/i.test(c)) {
      let j = i + 1
      while (j < n && /[\w$]/.test(source[j]))
        j += 1
      tokens.push(source.slice(i, j))
      i = j
      continue
    }
    if (/\d/.test(c)) {
      let j = i + 1
      while (j < n && /[\w.]/.test(source[j]))
        j += 1
      tokens.push(source.slice(i, j))
      i = j
      continue
    }
    tokens.push(c)
    i += 1
  }
  return tokens
}

function tokenSequenceIncludes(sourceTokens, anchorTokens) {
  if (anchorTokens.length === 0 || anchorTokens.length > sourceTokens.length)
    return false
  for (let i = 0; i + anchorTokens.length <= sourceTokens.length; i += 1) {
    let matched = true
    for (let j = 0; j < anchorTokens.length; j += 1) {
      if (sourceTokens[i + j] !== anchorTokens[j]) {
        matched = false
        break
      }
    }
    if (matched)
      return true
  }
  return false
}

export function validateVirtualPath(rel) {
  if (rel.includes('..') || rel.includes('\\') || posix.isAbsolute(rel))
    throw new Error(`unsafe virtual path: ${rel}`)
  return rel
}

export function materializeFixture(source) {
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
    // Non-comment lines are fixture scaffolding (`void main() {}`), not
    // virtual file content.
    if (stripped === line && line.trim() !== '')
      continue
    lines.push(stripped)
  }
  if (current)
    virtualFiles.set(current, lines.join('\n'))
  return virtualFiles
}

export function writeVirtualFiles(root, files) {
  for (const [rel, content] of files) {
    const safe = validateVirtualPath(rel)
    const abs = join(root, ...safe.split('/'))
    if (!resolve(abs).startsWith(`${resolve(root)}${sep}`))
      throw new Error(`virtual path escapes root: ${rel}`)
    mkdirSync(dirname(abs), { recursive: true })
    writeFileSync(abs, content, 'utf8')
  }
}

function resolveUri(fromRel, uri) {
  if (uri.startsWith(PACKAGE_PREFIX)) {
    const resolved = posix.normalize(posix.join(LIB_PREFIX, uri.slice(PACKAGE_PREFIX.length)))
    if (resolved === '..' || resolved.startsWith('../') || posix.isAbsolute(resolved))
      return null
    return resolved
  }
  // dart:*, package:flutter/*, absolute and backslash URIs never resolve here.
  if (uri.startsWith('/') || uri.includes(':') || uri.includes('\\'))
    return null
  const resolved = posix.normalize(posix.join(posix.dirname(fromRel), uri))
  if (resolved === '..' || resolved.startsWith('../') || posix.isAbsolute(resolved))
    return null
  return resolved
}

function resolveTarget(fromRel, uri, files) {
  const resolved = resolveUri(fromRel, uri)
  return resolved && files.has(resolved) ? resolved : null
}

function loadGraph(root) {
  const files = new Map()
  const base = join(root, ...LIB_PREFIX.split('/'))
  if (!existsSync(base))
    return files

  let rootReal
  try {
    rootReal = realpathSync(root)
  }
  catch {
    return files
  }
  // statSync/realpathSync follow symlinks: a linked Dart file or directory
  // inside the root is part of the graph, while a target that escapes the root
  // is rejected. The per-branch `ancestors` set breaks symlink cycles without
  // hiding a directory that is reachable through more than one path.
  function insideRoot(real) {
    return real === rootReal || real.startsWith(`${rootReal}${sep}`)
  }

  function walk(dir, ancestors) {
    for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0)) {
      const abs = join(dir, entry.name)
      let info
      let real
      try {
        info = statSync(abs)
        real = realpathSync(abs)
      }
      catch {
        continue
      }
      if (!insideRoot(real))
        continue
      if (info.isDirectory()) {
        if (ancestors.has(real))
          continue
        walk(abs, new Set([...ancestors, real]))
      }
      else if (info.isFile() && (entry.name.endsWith('.dart') || real.endsWith('.dart'))) {
        const rel = relative(root, abs).split(sep).join('/')
        const { noComments, code } = lexDart(readFileSync(abs, 'utf8'))
        const directives = extractDirectives(noComments, code)
        files.set(rel, {
          rel,
          directives,
          isBarrel: directives.some(d => d.kind === 'export'),
          importTargets: new Set(),
        })
      }
    }
  }
  walk(base, new Set([rootReal]))

  for (const info of files.values()) {
    for (const directive of info.directives) {
      if (directive.kind !== 'import')
        continue
      const target = resolveTarget(info.rel, directive.uri, files)
      if (target)
        info.importTargets.add(target)
    }
  }
  return files
}

// A caller must be a non-test, non-barrel lib file with a DIRECT import. Only
// lib files are loaded, so apps/flutter/test/** imports never enter the graph,
// and barrel re-exports are never added as caller edges.
export function audit(root = REPO_ROOT) {
  const files = loadGraph(root)
  const callers = new Map([...files.keys()].map(rel => [rel, new Set()]))
  for (const info of files.values()) {
    if (info.isBarrel)
      continue
    for (const target of info.importTargets)
      callers.get(target)?.add(info.rel)
  }

  const lines = []
  for (const info of files.values()) {
    if (info.isBarrel || GRANDFATHERED.has(info.rel))
      continue
    if ((callers.get(info.rel)?.size ?? 0) === 0)
      lines.push(`${DEAD_EXPORT} ${info.rel} has zero production callers outside tests/barrels`)
  }
  return lines.sort()
}

// STATIC table only: all anchors below are verified against the current source
// of the shared file. `table-only` means verify-and-report; the checker reads
// these files and never derives anchors from content or writes them back.
// `import ...` anchors are matched as resolved targets; other anchors are
// token sequences, so quote style and whitespace cannot rewrite a bypass.
export const SHARED_REGIONS = [
  {
    path: 'apps/flutter/lib/features/chat/chat_screen.dart',
    mode: 'table-only',
    symbolAnchors: [
      'import \'chat_message_display.dart\';',
      'stripMarkers(m.text)',
      'Key(\'chat-sessions-button\')',
      'ListView.builder(',
      'Key(\'chat-copy-$messageIndex\')',
      'MarkdownBody(',
    ],
    forbiddenAnchors: [
      'import \'chat_archetype_style.dart\'',
      'bubbleDecorationFor(',
      'ArchetypeStyledBubble(',
      'styleFor(',
    ],
  },
]

function anchorImportUri(anchor) {
  const match = anchor.match(/^import\s+(['"])([^'"]*)\1/)
  return match ? match[2] : null
}

export function auditSharedRegions(root = REPO_ROOT) {
  const lines = []
  for (const region of SHARED_REGIONS) {
    if (region.mode !== 'table-only')
      continue
    const abs = join(root, ...region.path.split('/'))
    if (!existsSync(abs))
      continue
    const source = readFileSync(abs, 'utf8')
    const { noComments, code } = lexDart(source)
    const importTargets = new Set(
      extractDirectives(noComments, code)
        .filter(d => d.kind === 'import')
        .map(d => resolveUri(region.path, d.uri))
        .filter(Boolean),
    )
    // Required anchors keep string bodies so Key('...') can be verified.
    // Forbidden call anchors use the code view, so a comment or string that
    // merely mentions a call cannot trigger a false positive.
    const presentTokens = tokenize(noComments)
    const codeTokens = tokenize(code)

    for (const anchor of region.symbolAnchors) {
      const uri = anchorImportUri(anchor)
      const present = uri
        ? importTargets.has(resolveUri(region.path, uri))
        : tokenSequenceIncludes(presentTokens, tokenize(anchor))
      if (!present)
        lines.push(`${REGION_LOCK} ${region.path} missing required anchor: ${anchor}`)
    }
    for (const anchor of region.forbiddenAnchors) {
      const uri = anchorImportUri(anchor)
      const present = uri
        ? importTargets.has(resolveUri(region.path, uri))
        : tokenSequenceIncludes(codeTokens, tokenize(anchor))
      if (present)
        lines.push(`${REGION_LOCK} ${region.path} contains forbidden anchor: ${anchor}`)
    }
  }
  return lines.sort()
}

function main(argv) {
  const rootIndex = argv.indexOf('--root')
  const explicitRoot = rootIndex !== -1
  const root = explicitRoot ? argv[rootIndex + 1] : REPO_ROOT
  if (!root || !existsSync(root)) {
    process.stderr.write(`${ERROR} --root requires an existing directory\n`)
    return 2
  }
  const libAbs = join(root, ...LIB_PREFIX.split('/'))
  if (!existsSync(libAbs)) {
    process.stderr.write(`${ERROR} --root has no ${LIB_PREFIX}: ${root}\n`)
    return 1
  }
  if (loadGraph(root).size === 0) {
    process.stderr.write(`${ERROR} --root has no Dart files under ${LIB_PREFIX}: ${root}\n`)
    return 1
  }

  const lines = [...audit(root), ...auditSharedRegions(root)].sort()
  for (const line of lines)
    process.stderr.write(`${line}\n`)
  return lines.length > 0 ? 1 : 0
}

// Keep the module importable by node:test; only run the CLI when invoked directly.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url))
  process.exitCode = main(process.argv.slice(2))
