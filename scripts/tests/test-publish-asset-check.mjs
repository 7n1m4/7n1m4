import assert from 'node:assert/strict'
import process from 'node:process'

import { spawnSync } from 'node:child_process'
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

const pending = [{ name: 'Release: Linux Desktop', status: 'in_progress', createdAt: '2026-01-01T00:00:00Z' }]
const completed = [{ name: 'Release: Linux Desktop', status: 'completed', conclusion: 'success', createdAt: '2026-01-01T00:00:00Z' }]
const failed = [{ name: 'Release: Linux Desktop', status: 'completed', conclusion: 'failure', createdAt: '2026-01-01T00:00:00Z' }]
const noRun = []

function runHelper(name, runs) {
  const root = mkdtempSync(join(tmpdir(), 'publish-asset-check-'))
  const fakeBin = join(root, 'bin')
  const logPath = join(root, 'commands.log')
  mkdirSync(fakeBin, { recursive: true })
  writeFileSync(join(fakeBin, 'gh'), `#!/usr/bin/node\nprocess.stdout.write(${JSON.stringify(JSON.stringify(runs))})\n`, { mode: 0o755 })
  writeFileSync(join(fakeBin, 'node'), '#!/usr/bin/node\nprocess.exit(process.argv.includes("--advisory") ? 0 : 1)\n', { mode: 0o755 })

  const command = name === 'checkMacAssets' ? 'publish-mac.js' : 'publish-win.js'
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', `
    import { appendFileSync } from 'node:fs'
    const originalLog = console.info
    console.info = (...args) => {
      const text = args.join(' ')
      if (text.includes('Running:'))
        appendFileSync(${JSON.stringify(logPath)}, text.split('Running: ')[1] + String.fromCharCode(10))
      originalLog(...args)
    }
    const module = await import(${JSON.stringify(new URL(`../release/${command}`, import.meta.url).href)})
    module.checkReleaseAssets('v0.0.0-test')
  `], {
    cwd: root,
    encoding: 'utf-8',
    env: { ...process.env, PATH: `${fakeBin}:${process.env.PATH}` },
  })
  if (result.status !== 0)
    console.error(result.stderr)
  const log = readFileSync(logPath, 'utf-8')
  rmSync(root, { recursive: true, force: true })
  return { result, log }
}

for (const helper of ['checkMacAssets', 'checkWinAssets']) {
  const advisory = runHelper(helper, pending)
  assert.match(advisory.log, /ci-status\.mjs --release --tag=v0\.0\.0-test --advisory/, `${helper} must use advisory flag while Linux CI runs`)
  assert.equal(advisory.result.status, 0, `${helper} must not fail while Linux CI is pending`)

  for (const [label, runs] of [['failed', failed], ['no run', noRun]]) {
    const caseResult = runHelper(helper, runs)
    assert.match(caseResult.log, /ci-status\.mjs --release --tag=v0\.0\.0-test --advisory/, `${helper} must stay advisory with ${label}`)
    assert.equal(caseResult.result.status, 0, `${helper} must not fail with ${label}`)
  }

  const strict = runHelper(helper, completed)
  assert.match(strict.log, /ci-status\.mjs --release --tag=v0\.0\.0-test\n/, `${helper} must use strict gate after Linux CI succeeds`)
  assert.equal(strict.result.status, 1, `${helper} must fail when the strict gate reports missing assets`)
}

console.info('✓ publish helpers: advisory until Linux CI succeeds, fatal afterwards')
