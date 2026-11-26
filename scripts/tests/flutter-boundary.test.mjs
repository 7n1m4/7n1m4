import assert from 'node:assert/strict'
// eslint-disable-next-line test/no-import-node-test -- this guard runs under `node --test`
import test from 'node:test'

import {
  lstatSync,
  mkdirSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, join, posix, relative, sep } from 'node:path'
import { fileURLToPath } from 'node:url'

const DEFAULT_LIB_ROOT = fileURLToPath(new URL('../../apps/flutter/lib', import.meta.url))

// Rule F scope: opt-in marker (`// pure-formatter`) inside speech/** or any
// **/formatters/**. The current tree has no markers, so the engines that
// legitimately import dart:io / dart:async / dart:convert / dart:typed_data
// stay green; a new pure formatter opts in explicitly and is then checked.
const DEFAULT_MARKER = 'pure-formatter'

// --- scanner implementation ---

// Exact allowlist: no globs, no directory prefixes. Each entry is a real
// verified tree path with its own reason, plus the ONLY rule-P imports and
// APIs that reason covers; anything else in the same file still fails.
const ALLOWLIST = [
  {
    path: 'daemon_client/direct_websocket_transport.dart',
    reason: 'sole sanctioned WS transport (web_socket_channel + HttpClient TLS)',
    imports: ['package:web_socket_channel/io.dart', 'package:web_socket_channel/web_socket_channel.dart'],
    apis: ['HttpClient'],
  },
  {
    path: 'features/chat/composer_draft_store.dart',
    reason: 'local draft cache (writeAsStringSync of composer drafts)',
    imports: [],
    apis: ['writeAsStringSync'],
  },
  {
    path: 'features/stage/model_asset_resolver.dart',
    reason: 'model cache (writeAsBytes of downloaded model into temp)',
    imports: [],
    apis: ['writeAsBytes'],
  },
  {
    path: 'features/stage/stage_scene_manager.dart',
    reason: 'scene cache (writeAsBytes/writeAsString of scene payloads)',
    imports: [],
    apis: ['writeAsBytes', 'writeAsString'],
  },
  {
    path: 'speech/piper_tts_engine.dart',
    reason: 'generated WAV scratch; Process.start is the ONLY permitted process use, and only to invoke the local piper binary',
    imports: [],
    apis: ['Process.start'],
  },
  {
    path: 'connection/linux_gateway_discovery.dart',
    reason: 'read-only D-Bus discovery via literal-argv Process.run, never runInShell; no config writes or token binding',
    imports: [],
    apis: ['Process.run'],
  },
]

// Client-owned state writers / outbound transports. A leading \b anchors the
// token, \w* absorbs suffixes (SecureSocket, HttpClientRequest), and an optional
// dotted member catches Process.start and only FileMode.write (used by
// File.open(mode: FileMode.write)); FileMode.read and ProcessException are
// read-only and must not trip the guard.
const FORBIDDEN_IMPORT_PREFIXES = [
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
const IO_WRITE_NETWORK = /\b(?:writeAsString\w*|writeAsBytes\w*|openWrite|createSink|SecureSocket\w*|ServerSocket\w*|HttpClient\w*|Socket\w*|HttpServer\w*|RawSocket\w*|RandomAccessFile(?:\.\w+)?|FileMode\.write|writeFrom\w*|Process(?:\.\w+)?)\b/g

function blank(chars, start, end) {
  for (let i = start; i < end; i += 1) {
    if (chars[i] !== '\n')
      chars[i] = ' '
  }
}

// One lexer pass produces three aligned views of the source (newlines kept):
//   noComments  - comments blanked, string contents intact
//   code        - comments AND strings blanked (the executable skeleton)
//   comments    - only comment text kept (for the Rule F opt-in marker)
function lexDart(source) {
  const noComments = source.split('')
  const code = source.split('')
  const comments = Array.from({ length: source.length }, () => ' ')
  const n = source.length
  let i = 0
  while (i < n) {
    const c = source[i]
    const d = source[i + 1]
    if (c === '/' && d === '/') {
      let j = i
      while (j < n && source[j] !== '\n') j += 1
      for (let k = i; k < j; k += 1) comments[k] = source[k]
      blank(noComments, i, j)
      blank(code, i, j)
      i = j
      continue
    }
    if (c === '/' && d === '*') {
      let j = i + 2
      while (j < n && (source[j] !== '*' || source[j + 1] !== '/')) j += 1
      const end = Math.min(n, j + 2)
      for (let k = i; k < end; k += 1) comments[k] = source[k]
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
      // Strings stay visible in noComments so import URIs remain readable;
      // a lookalike is rejected below because its keyword is blank in code.
      blank(code, i, Math.min(n, j))
      i = Math.min(n, j)
      continue
    }
    i += 1
  }
  return {
    noComments: noComments.join(''),
    code: code.join(''),
    comments: comments.join(''),
  }
}

// `part` URIs are library-relative in Dart, so they are intentionally ignored.
function extractImports(noComments, code) {
  const uris = []
  for (const match of noComments.matchAll(/\b(?:import|export)\s+(['"])([^'"]*)\1/g)) {
    // The keyword must be real code, not text inside a string literal.
    if (code[match.index] === match[0][0])
      uris.push(match[2])
  }
  return uris
}

function isRuleFScope(rel) {
  const dirs = rel.split('/').slice(0, -1)
  return dirs.includes('speech') || dirs.includes('formatters')
}

function isAllowedPureImport(uri, file) {
  if (uri === 'dart:core' || uri === 'dart:math')
    return true
  if (uri.startsWith('package:flutter/'))
    return true
  if (uri.includes(':'))
    return false
  // posix.join drops a leading slash, so reject absolute URIs before joining.
  if (uri.startsWith('/'))
    return false
  // Relative imports are read-only wire models, but must stay inside the lib
  // root: a `..` escape could pull in a competing writer.
  const resolved = posix.normalize(posix.join(posix.dirname(file), uri))
  return !resolved.startsWith('..') && !resolved.startsWith('/')
}

function ruleFFindings(file, code, imports) {
  const findings = []
  const add = detail => findings.push({ file, rule: 'F', detail })
  for (const uri of imports) {
    if (!isAllowedPureImport(uri, file)) {
      add(uri.includes(':') ? `pure formatter disallows import: ${uri}` : `pure formatter relative import escapes lib root: ${uri}`)
    }
  }
  for (const token of ['ChangeNotifier', 'StateNotifier']) {
    if (new RegExp(`\\b${token}\\b`).test(code))
      add(`notifier in pure formatter: ${token}`)
  }
  for (const token of ['async', 'await', 'Future', 'Stream', 'StreamController']) {
    if (new RegExp(`\\b${token}\\b`).test(code))
      add(`async in pure formatter: ${token}`)
  }

  let depth = 0
  for (const line of code.split('\n')) {
    const trimmed = line.trimStart()
    if (depth === 0) {
      const finalLiteral = /^final\b[^=]*=\s*(?:<[^>]*>)?\s*[[{]/.test(trimmed)
      const finalTyped = /^final\b[^=]+\b(?:List|Map|Set)\b(?:<[^>]*>)?/.test(trimmed) && !/=\s*const\b/.test(trimmed)
      if (/^var\b/.test(trimmed))
        add('mutable top-level state: var')
      else if (/^late\b/.test(trimmed))
        add('mutable top-level state: late')
      else if (finalLiteral || finalTyped)
        add('mutable top-level state: final collection')
    }
    if (/^static\b/.test(trimmed)) {
      const staticLate = /^static\s+late\b/.test(trimmed)
      const staticMutable = !/\b(?:final|const)\b/.test(trimmed) && /\s=\s/.test(trimmed) && !/=>/.test(trimmed)
      const staticFinalCollection = (
        /^static\s+final\b[^=]+\b(?:List|Map|Set)\b(?:<[^>]*>)?/.test(trimmed)
        || /^static\s+final\b[^=]*=\s*(?:<[^>]*>)?\s*[[{]/.test(trimmed)
      ) && !/=\s*const\b/.test(trimmed)
      if (staticLate || staticMutable || staticFinalCollection) {
        add(staticLate ? 'mutable static field: late' : staticFinalCollection ? 'mutable static field: final collection' : 'mutable static field')
      }
    }
    for (const ch of line) {
      if (ch === '{')
        depth += 1
      else if (ch === '}')
        depth = Math.max(0, depth - 1)
    }
  }
  return findings
}

function scanFile(rel, source, marker, findings) {
  const { noComments, code, comments } = lexDart(source)
  const imports = extractImports(noComments, code)

  const allow = ALLOWLIST.find(entry => entry.path === rel)
  for (const uri of imports) {
    if (FORBIDDEN_IMPORT_PREFIXES.some(prefix => uri.startsWith(prefix)) && !allow?.imports.includes(uri)) {
      findings.push({ file: rel, rule: 'P', detail: `forbidden import: ${uri}` })
    }
  }
  const seen = new Set()
  for (const match of code.matchAll(IO_WRITE_NETWORK)) {
    const token = match[0]
    if (seen.has(token))
      continue
    seen.add(token)
    if (allow?.apis.includes(token))
      continue
    findings.push({ file: rel, rule: 'P', detail: `dart:io write/network API: ${token}` })
  }

  const markerRe = new RegExp(`//\\s*${marker.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`)
  if (isRuleFScope(rel) && markerRe.test(comments)) {
    findings.push(...ruleFFindings(rel, code, imports))
  }
}

const compare = (a, b) => (a < b ? -1 : a > b ? 1 : 0)

export function scanFlutterLib(root = DEFAULT_LIB_ROOT, options = {}) {
  const { marker = DEFAULT_MARKER } = options
  const findings = []

  function walk(dir) {
    const entries = readdirSync(dir, { withFileTypes: true })
      .sort((a, b) => compare(a.name, b.name))
    for (const entry of entries) {
      const abs = join(dir, entry.name)
      const rel = relative(root, abs).split(sep).join('/')
      // Fail closed: hidden paths and symlinks are places a competing writer
      // could hide, so report them instead of silently skipping them.
      if (entry.name.startsWith('.') || entry.isSymbolicLink()) {
        findings.push({ file: rel, rule: 'U', detail: `unscanned path: ${rel}` })
        continue
      }
      if (entry.isDirectory()) {
        walk(abs)
        continue
      }
      if (!entry.isFile() || !entry.name.endsWith('.dart'))
        continue
      scanFile(rel, readFileSync(abs, 'utf8'), marker, findings)
    }
  }

  walk(root)
  return findings.sort((a, b) => compare(a.file, b.file) || compare(a.rule, b.rule) || compare(a.detail, b.detail))
}
// --- end scanner implementation ---

function makeLibRoot(t) {
  const root = mkdtempSync(join(tmpdir(), 'flutter-boundary-'))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  return root
}

function writeDart(root, relPath, content) {
  const abs = join(root, ...relPath.split('/'))
  mkdirSync(dirname(abs), { recursive: true })
  writeFileSync(abs, content)
  return abs
}

function findingsFor(root, options) {
  return scanFlutterLib(root, options)
}

test('forbidden import fails', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/chat/evil.dart', 'import \'package:hive/hive.dart\';\n')

  const findings = findingsFor(root)
  assert.ok(findings.some(f => f.rule === 'P' && /package:hive\//.test(f.detail)), JSON.stringify(findings))
})

test('forbidden export re-export fails', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/chat/reexport.dart', 'export \'package:hive/hive.dart\';\n')

  const findings = findingsFor(root)
  assert.ok(
    findings.some(f => f.rule === 'P' && /forbidden import: package:hive\//.test(f.detail)),
    JSON.stringify(findings),
  )
})

test('mutable top-level state fails', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/bad_formatter.dart', [
    '// pure-formatter',
    'import \'dart:core\';',
    '',
    'var counter = 0;',
    'const int fixed = 1;',
    '',
  ].join('\n'))
  writeDart(root, 'features/formatters/bad_static.dart', [
    '// pure-formatter',
    'class Bad {',
    '  static int _count = 0;',
    '}',
    '',
  ].join('\n'))
  writeDart(root, 'features/formatters/bad_late.dart', [
    '// pure-formatter',
    'late final int resolved;',
    '',
  ].join('\n'))
  writeDart(root, 'features/formatters/bad_collection.dart', [
    '// pure-formatter',
    'final List<int> values = [1, 2];',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  assert.equal(findings.filter(f => f.rule === 'F').length, 4, JSON.stringify(findings))
})

test('non-const final collections initialized from calls fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/computed_formatter.dart', [
    '// pure-formatter',
    'final List<int> computed = compute();',
    'final Map<String, int> locked = Map.unmodifiable({\'a\': 1});',
    'final Set<String> names = buildNames();',
    'final List rawList = buildList();',
    'final Map rawMap = Map();',
    'final Set rawSet = buildSet();',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  assert.equal(findings.filter(f => f.rule === 'F').length, 6, JSON.stringify(findings))
  assert.match(details, /mutable top-level state: final collection/)
})

test('static late and static final collection fields fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/formatters/static_state.dart', [
    '// pure-formatter',
    'class Stateful {',
    '  static late int counter;',
    '  static final List<int> values = [1, 2];',
    '  static final List raw = build();',
    '  static final rawValues = [1, 2];',
    '  static const List<int> frozen = [3];',
    '}',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  assert.equal(findings.filter(f => f.rule === 'F').length, 4, JSON.stringify(findings))
  assert.match(details, /mutable static field: late/)
  assert.match(details, /mutable static field: final collection/)
})

test('allowlisted paths pass', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'daemon_client/direct_websocket_transport.dart', [
    'import \'dart:io\';',
    'import \'package:web_socket_channel/io.dart\';',
    'import \'package:web_socket_channel/web_socket_channel.dart\';',
    'final c = HttpClient();',
    '',
  ].join('\n'))
  writeDart(root, 'features/chat/composer_draft_store.dart', [
    'import \'dart:io\';',
    'File(\'drafts.json\').writeAsStringSync(\'[]\');',
    '',
  ].join('\n'))
  writeDart(root, 'features/stage/model_asset_resolver.dart', [
    'import \'dart:io\';',
    'File(\'model\').writeAsBytes(<int>[1]);',
    '',
  ].join('\n'))
  writeDart(root, 'features/stage/stage_scene_manager.dart', [
    'import \'dart:io\';',
    'File(\'scene\').writeAsString(\'x\');',
    'File(\'scene2\').writeAsBytes(<int>[1]);',
    '',
  ].join('\n'))
  writeDart(root, 'speech/piper_tts_engine.dart', [
    'import \'dart:io\';',
    'final d = Directory.systemTemp.createTemp(\'anima-piper-\');',
    '',
  ].join('\n'))

  // Control: the exact same content at a non-allowlisted path must still fail,
  // proving the allowlist is a set of exact paths and not a glob/prefix.
  writeDart(root, 'features/chat/not_allowlisted.dart', [
    'import \'dart:io\';',
    'import \'package:web_socket_channel/web_socket_channel.dart\';',
    'final c = HttpClient();',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  assert.deepEqual(
    findings.map(f => f.file),
    ['features/chat/not_allowlisted.dart', 'features/chat/not_allowlisted.dart'],
    JSON.stringify(findings),
  )
  assert.ok(findings.every(f => f.rule === 'P'))
})

test('allowlist only exempts its documented imports and APIs', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/chat/composer_draft_store.dart', [
    'import \'dart:io\';',
    'import \'package:hive/hive.dart\';',
    'File(\'drafts.json\').writeAsStringSync(\'[]\');',
    'Socket.connect(\'evil\', 1);',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  assert.ok(findings.some(f => f.rule === 'P' && /forbidden import: package:hive\//.test(f.detail)), JSON.stringify(findings))
  assert.match(details, /write\/network API: Socket\b/, details)
  assert.doesNotMatch(details, /writeAsStringSync/, details)
})

test('piper allowlist permits only Process.start', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/piper_tts_engine.dart', [
    'import \'dart:io\';',
    'Process.start(\'piper\', <String>[]);',
    'Process.run(\'sh\', <String>[]);',
    'Socket.connect(\'evil\', 1);',
    '',
  ].join('\n'))

  const exact = new Set(findingsFor(root).map(f => f.detail))
  assert.equal(exact.has('dart:io write/network API: Process.start'), false, [...exact].join(' | '))
  assert.equal(exact.has('dart:io write/network API: Process.run'), true, [...exact].join(' | '))
  assert.equal(exact.has('dart:io write/network API: Socket'), true, [...exact].join(' | '))
})

test('linux gateway allowlist rejects Process.start and Socket', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'connection/linux_gateway_discovery.dart', [
    'import \'dart:io\';',
    'Process.start(\'sh\', <String>[]);',
    'Socket.connect(\'evil\', 1);',
    '',
  ].join('\n'))

  const exact = new Set(findingsFor(root).map(f => f.detail))
  assert.equal(exact.has('dart:io write/network API: Process.start'), true, [...exact].join(' | '))
  assert.equal(exact.has('dart:io write/network API: Socket'), true, [...exact].join(' | '))
})

test('constant top-level tables pass', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/good_formatter.dart', [
    '// pure-formatter',
    'import \'dart:math\';',
    'import \'pcm_source.dart\';',
    '',
    'const List<int> table = <int>[1, 2, 3];',
    'const Map<String, int> lookup = <String, int>{\'a\': 1};',
    'double format(double v) => v.abs();',
    '',
  ].join('\n'))

  assert.deepEqual(findingsFor(root), [])
})

test('read-only Platform dart:io imports pass', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'connection/platform_check.dart', [
    'import \'dart:io\';',
    '',
    'bool get isLinux => Platform.isLinux;',
    '',
  ].join('\n'))

  assert.deepEqual(findingsFor(root), [])
})

test('file-write APIs fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/data/writer.dart', [
    'import \'dart:io\';',
    'File(\'a\').writeAsString(\'x\');',
    'File(\'b\').writeAsBytes(<int>[1]);',
    'File(\'c\').openWrite();',
    'File(\'d\').createSink();',
    'final client = HttpClient();',
    'final s = Socket.connect("host", 80);',
    'final ss = ServerSocket.bind("host", 80);',
    'final hs = HttpServer.bind("host", 80);',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  for (const token of [
    'writeAsString',
    'writeAsBytes',
    'openWrite',
    'createSink',
    'HttpClient',
    'Socket',
    'ServerSocket',
    'HttpServer',
  ]) {
    assert.ok(details.includes(token), `missing ${token} in ${details}`)
  }
  assert.ok(findings.every(f => f.rule === 'P'))
})

test('compound socket and http client API names fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/data/network.dart', [
    'import \'dart:io\';',
    'final s = SecureSocket.connect(\'host\', 443);',
    'final r = HttpClientRequest();',
    '',
  ].join('\n'))

  const details = findingsFor(root).map(f => f.detail).join(' | ')
  assert.match(details, /write\/network API: SecureSocket\b/, details)
  assert.match(details, /write\/network API: HttpClientRequest\b/, details)
})

test('open-write, random-access and process APIs fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/data/raw_writes.dart', [
    'import \'dart:io\';',
    'File(\'x\').open(mode: FileMode.write);',
    'final a = RandomAccessFile(\'/tmp/raw\');',
    'final b = a.writeFromSync(<int>[1]);',
    'final c = RawSocket.connect(\'host\', 1);',
    'final d = Process.run(\'sh\', <String>[]);',
    'final e = Process(\'sh\');',
    '',
  ].join('\n'))

  const exact = new Set(findingsFor(root).map(f => f.detail))
  for (const token of ['FileMode.write', 'RandomAccessFile', 'writeFromSync', 'RawSocket', 'Process.run', 'Process']) {
    assert.ok(exact.has(`dart:io write/network API: ${token}`), `missing ${token} in ${[...exact].join(' | ')}`)
  }
})

test('read-only FileMode.open passes', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/data/read_only_open.dart', [
    'import \'dart:io\';',
    'final f = File(\'x\').open(mode: FileMode.read);',
    '',
  ].join('\n'))

  assert.deepEqual(findingsFor(root), [])
})

test('web_socket_channel import fails outside allowlist', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/chat/socket.dart', [
    'import \'package:web_socket_channel/web_socket_channel.dart\';',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  assert.ok(findings.some(f => f.rule === 'P' && /web_socket_channel/.test(f.detail)), JSON.stringify(findings))
})

test('http and database writer imports fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/data/network_writer.dart', [
    'import \'package:http/http.dart\';',
    'import \'package:dio/dio.dart\';',
    'import \'package:drift/drift.dart\';',
    'import \'package:sembast/sembast.dart\';',
    '',
  ].join('\n'))

  const details = findingsFor(root).map(f => f.detail).join(' | ')
  for (const uri of ['package:http/', 'package:dio/', 'package:drift/', 'package:sembast/']) {
    assert.ok(details.includes(uri), `missing ${uri} in ${details}`)
  }
})

test('comment and string decoys do not fail', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/chat/decoys.dart', [
    '// import \'package:hive/hive.dart\';',
    '/*',
    'import \'package:sqflite/sqflite.dart\';',
    '*/',
    'const String singleLine = "import \'package:web_socket_channel/io.dart\';";',
    'const String multiLine = \'\'\'',
    'import \'package:isar/isar.dart\';',
    '\'\'\'',
    '// final c = HttpClient(); File(\'x\').writeAsString(\'y\');',
    'const String ioDecoy = "HttpClient writeAsString openWrite Socket";',
    '',
  ].join('\n'))

  assert.deepEqual(findingsFor(root), [])
})

test('pure formatter import restriction fails on dart:async', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/async_formatter.dart', [
    '// pure-formatter',
    'import \'dart:async\';',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  assert.ok(findings.some(f => f.rule === 'F' && /dart:async/.test(f.detail)), JSON.stringify(findings))
})

test('pure formatter relative import cannot escape lib root', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/escape.dart', [
    '// pure-formatter',
    'import \'../../outside.dart\';',
    '',
  ].join('\n'))
  writeDart(root, 'speech/stays_inside.dart', [
    '// pure-formatter',
    'import \'../data/wire_model.dart\';',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  assert.ok(findings.some(f => f.file === 'speech/escape.dart' && /escapes lib root/.test(f.detail)), JSON.stringify(findings))
  assert.equal(findings.some(f => f.file === 'speech/stays_inside.dart'), false, details)
})

test('pure formatter absolute import URI fails', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'speech/absolute.dart', [
    '// pure-formatter',
    'import \'/etc/passwd.dart\';',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  assert.ok(
    findings.some(f => f.rule === 'F' && /escapes lib root: \/etc\/passwd\.dart/.test(f.detail)),
    JSON.stringify(findings),
  )
})

test('pure formatter rejects notifier and async', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'features/formatters/notifier.dart', [
    '// pure-formatter',
    'class Formatter extends ChangeNotifier {}',
    '',
  ].join('\n'))
  writeDart(root, 'features/formatters/async_io.dart', [
    '// pure-formatter',
    'Future<void> run() async { await Future<void>.delayed(Duration.zero); }',
    '',
  ].join('\n'))

  const findings = findingsFor(root)
  const details = findings.map(f => f.detail).join(' | ')
  assert.ok(details.includes('ChangeNotifier'), details)
  assert.ok(/async/.test(details), details)
  assert.ok(findings.every(f => f.rule === 'F'))
})

test('sorted deterministic findings', (t) => {
  const root = makeLibRoot(t)
  writeDart(root, 'z_last.dart', 'import \'package:hive/hive.dart\';\n')
  writeDart(root, 'a_first.dart', [
    'import \'package:isar/isar.dart\';',
    'import \'package:hive_flutter/hive_flutter.dart\';',
    '',
  ].join('\n'))
  writeDart(root, 'm_mid.dart', [
    'import \'dart:io\';',
    'File(\'x\').writeAsString(\'y\');',
    '',
  ].join('\n'))

  const first = findingsFor(root)
  const second = findingsFor(root)
  assert.deepEqual(second, first)
  assert.deepEqual(
    first.map(f => f.file),
    [...first.map(f => f.file)].sort(),
  )
  assert.ok(first.length >= 4, JSON.stringify(first))
})

test('hidden paths and symlinks fail closed', (t) => {
  const root = makeLibRoot(t)
  const outside = mkdtempSync(join(tmpdir(), 'flutter-boundary-outside-'))
  t.after(() => rmSync(outside, { recursive: true, force: true }))

  writeDart(root, '.hidden/evil.dart', 'import \'package:hive/hive.dart\';\n')
  writeDart(root, '.hidden.dart', 'import \'package:hive/hive.dart\';\n')
  writeDart(root, 'notes.txt', 'import \'package:hive/hive.dart\';\n')
  const outsideFile = writeDart(outside, 'outside_writer.dart', 'import \'package:hive/hive.dart\';\n')
  symlinkSync(outsideFile, join(root, 'linked_outside.dart'))
  assert.equal(lstatSync(join(root, 'linked_outside.dart')).isSymbolicLink(), true)

  const findings = findingsFor(root)
  assert.deepEqual(findings.map(f => f.file), ['.hidden', '.hidden.dart', 'linked_outside.dart'], JSON.stringify(findings))
  assert.ok(findings.every(f => f.rule === 'U' && /^unscanned path: /.test(f.detail)), JSON.stringify(findings))
})

test('real flutter lib tree stays green', () => {
  assert.deepEqual(scanFlutterLib(DEFAULT_LIB_ROOT), [])
})
