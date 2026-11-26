import assert from 'node:assert/strict'
import process from 'node:process'

import { spawnSync } from 'node:child_process'
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptPath = fileURLToPath(new URL('../github/ci-status.mjs', import.meta.url))

function run(args, env) {
  return spawnSync(process.execPath, [scriptPath, ...args], {
    encoding: 'utf-8',
    env: { ...process.env, ...env },
  })
}

// A fake `gh` captures and echoes each invocation, so assertions can check the
// exact -R value that reached the command.
function ghLog() {
  const fakeBin = mkdtempSync(join(tmpdir(), 'ci-status-repo-'))
  const log = join(fakeBin, 'log')
  writeFileSync(
    join(fakeBin, 'gh'),
    `#!/usr/bin/env node\nconst line = process.argv.slice(2).join(' '); require('node:fs').appendFileSync(${JSON.stringify(log)}, line + '\\n'); process.stdout.write(JSON.stringify({ echo: line, assets: [] }) + '\\n')\n`,
    { mode: 0o755 },
  )
  return { fakeBin, log }
}

const { fakeBin, log } = ghLog()
function runWithGh(args, env = {}) {
  const result = run(args, { PATH: `${fakeBin}:${process.env.PATH}`, CI_REPO: '', ...env })
  assert.equal(result.status, 0, result.stderr)
  const lines = readFileSync(log, 'utf-8').trim().split('\n')
  return { command: lines.at(-1), stdout: result.stdout }
}
function assertRepo({ command, stdout }, expected, label) {
  const token = `-R ${expected}`
  assert.ok(command.includes(token) && command.split(' ').includes(expected), `${label}: wrong repo in gh command: ${command}`)
  assert.ok(stdout.includes(JSON.stringify(command)) || readFileSync(log, 'utf-8').includes(command), `${label}: gh did not receive the command: ${stdout}`)
}

try {
  // The default follows this checkout's origin (git remote get-url origin).
  assertRepo(runWithGh(['--log-error']), '7n1m4/AnimA', 'default repo')

  // Explicit overrides allow upstream comparisons, including release checks.
  assertRepo(
    runWithGh(['--release', '--tag=v0.0.0-repo-test', '--advisory'], { CI_REPO: 'moeru-ai/airi' }),
    'moeru-ai/airi',
    'CI_REPO override on release view',
  )
  assertRepo(
    runWithGh(['--log-error', '--repo=moeru-ai/airi'], { CI_REPO: 'ignored/repo' }),
    'moeru-ai/airi',
    '--repo override',
  )

  // Malformed slugs must never reach a gh command.
  const bad = run(['--log-error', '--repo=not-a-slug'], { PATH: `${fakeBin}:${process.env.PATH}` })
  assert.equal(bad.status, 1, 'invalid repo slug must fail')
  assert.match(bad.stderr, /Invalid repository slug/)
}
finally {
  rmSync(fakeBin, { recursive: true, force: true })
}

console.info('✓ ci-status repo selection: origin default, env/flag override, invalid slug rejected')
