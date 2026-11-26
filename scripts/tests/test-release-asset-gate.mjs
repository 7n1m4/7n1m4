import assert from 'node:assert/strict'
import process from 'node:process'

import { spawnSync } from 'node:child_process'
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'

const gatePath = fileURLToPath(new URL('../github/ci-status.mjs', import.meta.url))
const tag = 'v0.0.0-gate-test'
const completeAssets = [
  'AIRI-1.2.3-ios.ipa',
  'AIRI-1.2.3-pocket.apk',
  'airi-1.2.3-darwin-arm64.dmg',
  'airi-1.2.3-arm64-mac.zip',
  'airi-1.2.3-windows-x64-setup.exe',
  'airi-1.2.3-windows-x64.zip',
  'airi-1.2.3-linux-amd64.deb',
  'airi-1.2.3-linux-aarch64.rpm',
  'airi-1.2.3-linux-x64-anima-daemon',
  'airi-1.2.3-linux-x64-anima-supervisor',
  'airi-1.2.3-linux-arm64-anima-daemon',
  'airi-1.2.3-linux-arm64-anima-supervisor',
]

function runWithFakeGh(output, args) {
  const fakeBin = mkdtempSync(join(tmpdir(), 'ci-status-gh-'))
  try {
    writeFileSync(
      join(fakeBin, 'gh'),
      '#!/usr/bin/env node\nprocess.stdout.write(process.env.FAKE_GH_OUTPUT || "")\n',
      { mode: 0o755 },
    )
    return spawnSync(process.execPath, args, {
      encoding: 'utf-8',
      env: {
        ...process.env,
        PATH: `${fakeBin}:${process.env.PATH}`,
        FAKE_GH_OUTPUT: output,
      },
    })
  }
  finally {
    rmSync(fakeBin, { recursive: true, force: true })
  }
}

function invokeGate({ assets, advisory = false }) {
  const output = JSON.stringify({ assets: assets.map(name => ({ name, size: 1, contentType: 'application/octet-stream' })) })
  const args = [gatePath, '--release', `--tag=${tag}`]
  if (advisory)
    args.push('--advisory')
  return runWithFakeGh(output, args)
}

const missingManifest = runWithFakeGh(JSON.stringify({ assets: [] }), [gatePath, '--release', `--tag=${tag}`])
assert.equal(missingManifest.status, 1, 'strict check with no assets must fail')
assert.match(missingManifest.stderr || missingManifest.stdout, /missing 12 required artifact/i)

const advisory = invokeGate({
  assets: completeAssets.filter(name => !name.includes('-linux-')),
  advisory: true,
})
assert.equal(advisory.status, 0, 'pending Linux CI must keep the publish-time gate advisory')
assert.match(advisory.stdout, /has not failed/i)

const strict = invokeGate({
  assets: completeAssets.filter(name => !name.includes('-linux-')),
})
assert.equal(strict.status, 1, 'completed Linux CI must restore the strict gate')
assert.match(strict.stderr || strict.stdout, /missing 6 required artifact/i)

console.info('✓ release asset gate: advisory while Linux CI runs, strict after completion')
