// Scoped WAVE-0 gate: lint only the .mjs files a change touched.
// Never use `pnpm lint` / `eslint .` here: full-repo lint OOMs (airi-9uz).
import process from 'node:process'

import { spawnSync } from 'node:child_process'

function git(args) {
  return spawnSync('git', args, { encoding: 'utf8' })
}

function run(base) {
  const resolved = git(['rev-parse', '--verify', '--quiet', `${base}^{commit}`])
  if (resolved.status !== 0) {
    console.error(`guard-eslint-mjs: invalid --base: ${base}`)
    return 1
  }

  const changed = git(['diff', '--name-only', '--diff-filter=ACMR', '-z', base])
  const untracked = git(['ls-files', '--others', '--exclude-standard', '-z'])
  if (changed.status !== 0 || untracked.status !== 0) {
    console.error('guard-eslint-mjs: failed to compute touched file set')
    return 1
  }

  const mjs = new Set()
  for (const output of [changed.stdout, untracked.stdout]) {
    for (const file of output.split('\0')) {
      if (file && file.endsWith('.mjs'))
        mjs.add(file)
    }
  }

  const files = [...mjs].sort()
  if (files.length === 0) {
    console.info('guard-eslint-mjs: no touched .mjs files; nothing to lint')
    return 0
  }

  let failed = 0
  for (const file of files) {
    console.info(`guard-eslint-mjs: eslint ${file}`)
    const result = spawnSync('pnpm', ['exec', 'eslint', '--no-warn-ignored', file], { stdio: 'inherit' })
    if (result.status !== 0) {
      console.error(`guard-eslint-mjs: FAILED ${file} (exit ${result.status})`)
      failed++
    }
  }

  if (failed > 0) {
    console.error(`guard-eslint-mjs: ${failed} of ${files.length} touched .mjs file(s) failed lint`)
    return 1
  }

  console.info(`guard-eslint-mjs: all ${files.length} touched .mjs file(s) lint clean`)
  return 0
}

const arg = process.argv.slice(2).find(value => value.startsWith('--base='))
const base = arg?.slice('--base='.length)

if (!base) {
  console.error('guard-eslint-mjs: missing required --base=<sha>')
  process.exit(1)
}

process.exit(run(base))
