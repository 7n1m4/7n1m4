import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const packageJson = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'))
const config = packageJson['nano-staged']
assert.ok(config && typeof config === 'object' && !Array.isArray(config), 'package.json must define a nano-staged config object')

// Mirrors nano-staged's own glob-to-regex: extended braces are enabled and `*`
// spans `/` when the pattern has no slash, so `*.rs` reaches nested crates too.
function globToRegExp(glob) {
  const globstar = glob.includes('/')
  let source = ''
  let inGroup = false

  for (let i = 0; i < glob.length; i++) {
    const char = glob[i]

    if (char === '*') {
      let starCount = 1
      while (glob[i + 1] === '*') {
        starCount++
        i++
      }
      const prev = glob[i - starCount]
      const next = glob[i + 1]
      const isGlobstar = globstar
        && starCount > 1
        && (prev === '/' || prev === undefined)
        && (next === '/' || next === undefined)

      if (isGlobstar) {
        source += '(?:[^/]*(?:/|$))*'
        if (next === '/')
          i++
      }
      else {
        source += '.*'
      }
      continue
    }

    if (char === '{') {
      inGroup = true
      source += '('
    }
    else if (char === '}') {
      inGroup = false
      source += ')'
    }
    else if (char === ',' && inGroup) {
      source += '|'
    }
    else if (char === '?') {
      source += '.'
    }
    else {
      source += char.replace(/[|\\{}()[\]^$+*?.]/g, '\\$&')
    }
  }

  return new RegExp(`^${source}$`)
}

const entries = Object.entries(config).map(([pattern, command]) => ({ pattern, command }))
const matchesFor = path => entries.filter(({ pattern }) => globToRegExp(pattern).test(path))
const patternsFor = path => matchesFor(path).map(entry => entry.pattern)
const commandsFor = path => [
  ...new Set(matchesFor(path).flatMap(entry => Array.isArray(entry.command) ? entry.command : [entry.command])),
]

// Markdown, JSON and YAML have no formatter configured and must stay untouched.
for (const path of ['AGENTS.md', 'docs/README.md', 'package.json', 'pnpm-workspace.yaml']) {
  assert.deepEqual(patternsFor(path), [], `${path} must match no nano-staged glob`)
}

// Each lintable/formatable family is owned by exactly one formatter.
const ownership = [
  ['crates/anima-channel/src/wire.rs', '*.rs', 'rustfmt --edition 2021'],
  ['apps/flutter/lib/speech/math_speech.dart', '*.dart', 'dart format'],
  ['packages/stage-ui/src/utils/math-speech.ts', '*.{js,cjs,mjs,ts,tsx,vue}', 'eslint --fix'],
  ['packages/stage-ui/src/components/Stage.vue', '*.{js,cjs,mjs,ts,tsx,vue}', 'eslint --fix'],
]

for (const [path, pattern, command] of ownership) {
  assert.deepEqual(patternsFor(path), [pattern], `${path} must match only ${pattern}`)
  assert.deepEqual(commandsFor(path), [command], `${path} must run only: ${command}`)
}

console.log('nano-staged scope OK: rustfmt for .rs, dart format for .dart, eslint for JS-family; docs/JSON/YAML untouched')
