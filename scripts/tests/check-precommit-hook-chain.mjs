import assert from 'node:assert/strict'
import process from 'node:process'

import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const GLOBSTAR = '((?:[^/]*(?:/|$))*)'
const WILDCARD = '([^/]*)'
const EXTGLOB = /[!@+?]\(/

function resolveConfigPath(argv) {
  const index = argv.indexOf('--config')
  if (index !== -1) {
    const value = argv[index + 1]
    if (!value)
      throw new Error('--config requires a path')
    return { path: value, overridden: true }
  }
  if (process.env.NANO_STAGED_CONFIG_PATH)
    return { path: process.env.NANO_STAGED_CONFIG_PATH, overridden: true }
  return { path: new URL('../../package.json', import.meta.url), overridden: false }
}

// nano-staged 0.9.0 semantics: extended braces, and `globstar` is enabled only
// for patterns containing a slash — then `*` is one path segment and a
// boundary `**` spans segments. Extglobs are rejected rather than approximated
// because they change which files a pattern claims.
export function globToRegExp(glob) {
  if (EXTGLOB.test(glob))
    throw new Error(`unsupported extglob syntax in pattern ${glob}`)

  const globstar = glob.includes('/')
  let source = ''
  let inGroup = false

  for (let pos = 0; pos < glob.length; pos++) {
    const char = glob[pos]

    if (char === '*') {
      let stars = 1
      while (glob[pos + 1] === '*') {
        stars++
        pos++
      }
      if (!globstar) {
        source += '.*'
      }
      else {
        const prev = glob[pos - stars]
        const next = glob[pos + 1]
        const isGlobStar = stars > 1
          && (prev === '/' || prev === undefined)
          && (next === '/' || next === undefined)
        if (isGlobStar) {
          source += GLOBSTAR
          if (next === '/')
            pos++
        }
        else {
          source += WILDCARD
        }
      }
      continue
    }

    if (char === '/') {
      source += '\\/'
      if (glob[pos + 1] === '/')
        source += '?'
    }
    else if (char === '{') {
      inGroup = true
      source += '('
    }
    else if (char === '}') {
      inGroup = false
      source += ')'
    }
    else if (char === ',') {
      source += inGroup ? '|' : '\\,'
    }
    else if (char === '?') {
      source += '.'
    }
    else if (char === '\\' || char === '$' || char === '^' || char === '=' || char === '.') {
      source += `\\${char}`
    }
    else {
      source += char
    }
  }

  return new RegExp(`^${source}$`)
}

// Markdown, JSON and YAML have no formatter configured and must stay untouched.
const DOC_PATHS = [
  'AGENTS.md',
  'docs/README.md',
  'package.json',
  'pnpm-workspace.yaml',
  '.github/workflows/ci.yml',
]

// Every representative file in a family must be owned by exactly one pattern
// and command — a witness alone would let a competing formatter slip through.
const FAMILIES = [
  {
    paths: ['crates/anima-channel/src/wire.rs', 'crates/anima-daemon/src/core.rs'],
    pattern: '*.rs',
    command: 'rustfmt --edition 2021',
  },
  {
    paths: ['apps/flutter/lib/speech/math_speech.dart', 'apps/flutter/lib/features/chat/chat_screen.dart'],
    pattern: '*.dart',
    command: 'dart format',
  },
  {
    paths: [
      'packages/stage-ui/src/utils/math-speech.js',
      'packages/stage-ui/src/utils/math-speech.cjs',
      'packages/stage-ui/src/utils/math-speech.mjs',
      'packages/stage-ui/src/utils/math-speech.ts',
      'packages/stage-ui/src/components/Stage.tsx',
      'packages/stage-ui/src/components/Stage.vue',
    ],
    pattern: '*.{js,cjs,mjs,ts,tsx,vue}',
    command: 'eslint --fix',
  },
]

function check(config) {
  assert.ok(config && typeof config === 'object' && !Array.isArray(config), 'package.json must define a nano-staged config object')

  const entries = Object.entries(config).map(([pattern, command]) => ({ pattern, command }))
  const matchesFor = path => entries.filter(({ pattern }) => globToRegExp(pattern).test(path))
  const patternsFor = path => matchesFor(path).map(entry => entry.pattern)
  const commandsFor = path => [
    ...new Set(matchesFor(path).flatMap(entry => Array.isArray(entry.command) ? entry.command : [entry.command])),
  ]

  for (const path of DOC_PATHS) {
    const matched = patternsFor(path)
    if (matched.length > 0)
      throw new Error(`${path} must match no nano-staged glob but matched: ${matched.join(', ')}`)
  }

  for (const { paths, pattern, command } of FAMILIES) {
    for (const path of paths) {
      const patterns = patternsFor(path)
      const commands = commandsFor(path)
      if (patterns.length !== 1 || patterns[0] !== pattern || commands.length !== 1 || commands[0] !== command)
        throw new Error(`${path}: expected only ${pattern} -> "${command}", got patterns=[${patterns.join(', ')}] commands=[${commands.join(', ')}]`)
    }
  }
}

function main() {
  const { path, overridden } = resolveConfigPath(process.argv.slice(2))
  const pkg = JSON.parse(readFileSync(path, 'utf8'))
  check(pkg['nano-staged'])

  if (overridden) {
    const hook = pkg['simple-git-hooks']?.['pre-commit']
    if (typeof hook !== 'string' || !hook.includes('pnpm nano-staged'))
      throw new Error('simple-git-hooks pre-commit must invoke "pnpm nano-staged"')
  }

  console.info('nano-staged chain OK: rustfmt for .rs, dart format for .dart, eslint for JS-family; docs/JSON/YAML untouched')
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  try {
    main()
  }
  catch (error) {
    console.error(error.message)
    process.exitCode = 1
  }
}
