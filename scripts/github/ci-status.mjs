#!/usr/bin/env node

import process from 'node:process'

import { execSync } from 'node:child_process'

const REPO = 'dasilva333/airi'
const args = process.argv.slice(2)
const isWatch = args.includes('--watch') || args.includes('-w')
const isRelease = args.includes('--release') || args.includes('-r')
const isLogError = args.includes('--log-error') || args.includes('-e')
const isSelfTest = args.includes('--self-test')
const isAdvisory = args.includes('--advisory')
const tagArg = args.find(a => a.startsWith('--tag='))?.split('=')[1]

// A release is only complete when every platform artifact is attached. Names
// match by stable fragments because versions and artifact prefixes change
// between releases. The Rust binaries are the ones installed into ~/.local/bin
// by the systemd/D-Bus units, so a release without them is broken on Linux.
const REQUIRED_RELEASE_ARTIFACTS = [
  { label: 'macOS dmg', pattern: /\.dmg$/ },
  { label: 'macOS zip', pattern: /-mac\.zip$/ },
  { label: 'Windows installer', pattern: /-windows-x64-setup\.exe$/ },
  { label: 'Windows zip', pattern: /-windows-x64\.zip$/ },
  { label: 'Linux x64 bundle', pattern: /-linux-(x64|amd64).*\.(deb|rpm|flatpak|tar\.zst|tar\.gz)$/ },
  { label: 'Linux arm64 bundle', pattern: /-linux-(arm64|aarch64).*\.(deb|rpm|flatpak|tar\.zst|tar\.gz)$/ },
  { label: 'Linux x64 daemon', pattern: /-linux-x64-anima-daemon$/ },
  { label: 'Linux x64 supervisor', pattern: /-linux-x64-anima-supervisor$/ },
  { label: 'Linux arm64 daemon', pattern: /-linux-arm64-anima-daemon$/ },
  { label: 'Linux arm64 supervisor', pattern: /-linux-arm64-anima-supervisor$/ },
  { label: 'Android APK', pattern: /\.apk$/ },
  { label: 'iOS IPA', pattern: /\.ipa$/ },
]

function missingReleaseArtifacts(assets) {
  const names = assets.map(a => typeof a === 'string' ? a : a.name)
  return REQUIRED_RELEASE_ARTIFACTS
    .filter(({ pattern }) => !names.some(name => pattern.test(name)))
    .map(({ label }) => label)
}

function gh(cmd) {
  try {
    return execSync(`gh ${cmd}`, { encoding: 'utf-8', stdio: ['pipe', 'pipe', 'pipe'] }).trim()
  }
  catch (err) {
    if (err.stdout)
      return err.stdout.trim()
    throw err
  }
}

function ghJson(cmd) {
  const output = gh(cmd)
  return output ? JSON.parse(output) : null
}

function formatDuration(startedAt, completedAt) {
  const start = new Date(startedAt).getTime()
  const end = completedAt ? new Date(completedAt).getTime() : Date.now()
  const sec = Math.floor((end - start) / 1000)
  if (sec < 60)
    return `${sec}s`
  const min = Math.floor(sec / 60)
  const remSec = sec % 60
  return `${min}m${remSec}s`
}

function printReleaseAssets(tag, assets, publishedAt) {
  console.info(`\n📦 Assets for Release [${tag}]:`)
  if (!assets || assets.length === 0) {
    console.info('  No assets attached yet.')
    return
  }

  console.info(`  Published: ${publishedAt} | Total Assets: ${assets.length}\n`)
  const maxName = Math.max(...assets.map(a => a.name.length), 10)
  for (const a of assets) {
    const sizeMb = (a.size / (1024 * 1024)).toFixed(2)
    console.info(`  • ${a.name.padEnd(maxName + 2)} ${sizeMb.padStart(7)} MB  (${a.contentType || 'file'})`)
  }
}

function verifyReleaseAssets(tag, { advisory = false } = {}) {
  const data = ghJson(`release view ${tag} -R ${REPO} --json assets,tagName,publishedAt`)
  printReleaseAssets(tag, data?.assets, data?.publishedAt)
  const missing = missingReleaseArtifacts(data?.assets ?? [])
  if (missing.length === 0) {
    console.info(`\n✅ Release ${tag} has all required platform artifacts.`)
    return
  }

  const level = advisory ? console.warn : console.error
  level(`\n${advisory ? '⚠️' : '❌'} Release ${tag} is incomplete. Missing artifacts:`)
  for (const label of missing)
    level(`  - ${label}`)

  if (advisory) {
    console.info(`ℹ️ Linux assets may still be building; the release gate has not failed.`)
    return
  }

  process.exitCode = 1
  throw new Error(`Release ${tag} is missing ${missing.length} required artifact(s)`)
}

function selfTest() {
  const complete = [
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
  const hutchNames = [
    'stable-linux-x64-AIRI.tar.zst',
    'linux-x64-AIRI-Setup.tar.gz',
    'stable-linux-arm64-AIRI.tar.zst',
    'linux-arm64-AIRI-Setup.tar.gz',
    'stable-linux-x64-update.json',
  ]
  const cases = [
    { name: 'complete release', assets: complete, expected: [] },
    { name: 'no assets', assets: [], expected: REQUIRED_RELEASE_ARTIFACTS.map(a => a.label) },
    {
      name: 'missing linux and mobile',
      assets: complete.filter(n => !/-linux-|\.ipa$|\.apk$/.test(n)),
      expected: [
        'Linux x64 bundle',
        'Linux arm64 bundle',
        'Linux x64 daemon',
        'Linux x64 supervisor',
        'Linux arm64 daemon',
        'Linux arm64 supervisor',
        'Android APK',
        'iOS IPA',
      ],
    },
    {
      name: 'missing daemon binaries',
      assets: complete.filter(n => !n.endsWith('-anima-daemon') && !n.endsWith('-anima-supervisor')),
      expected: [
        'Linux x64 daemon',
        'Linux x64 supervisor',
        'Linux arm64 daemon',
        'Linux arm64 supervisor',
      ],
    },
    {
      name: 'hutch tarball names count as Linux bundles',
      assets: [...complete.filter(n => !/-linux-(amd64|aarch64)\./.test(n)), ...hutchNames],
      expected: [],
    },
  ]

  let failed = false
  for (const { name, assets, expected } of cases) {
    const actual = missingReleaseArtifacts(assets)
    const ok = JSON.stringify(actual) === JSON.stringify(expected)
    console.info(`${ok ? '✓' : '✗'} ${name}: ${actual.length} missing`)
    if (!ok) {
      console.error(`  expected: ${expected.join(', ') || '(none)'}`)
      console.error(`  actual:   ${actual.join(', ') || '(none)'}`)
      failed = true
    }
  }

  process.exitCode = failed ? 1 : 0
}

function getWorkflowSummary() {
  const runs = ghJson(`run list -R ${REPO} -L 8 --json databaseId,name,status,conclusion,headSha,createdAt,updatedAt,event`)
  if (!runs || runs.length === 0)
    return []

  const summaries = []

  for (const r of runs) {
    let activeJobInfo = ''
    if (r.status === 'in_progress' || r.status === 'queued') {
      try {
        const jobsData = ghJson(`api /repos/${REPO}/actions/runs/${r.databaseId}/jobs`)
        if (jobsData && jobsData.jobs) {
          const inProgress = jobsData.jobs.filter(j => j.status === 'in_progress')
          const queued = jobsData.jobs.filter(j => j.status === 'queued')
          const completed = jobsData.jobs.filter(j => j.status === 'completed')

          if (inProgress.length > 0) {
            const details = inProgress.map((j) => {
              const activeStep = j.steps?.find(s => s.status === 'in_progress')
              return `${j.name}${activeStep ? ` -> [${activeStep.name}]` : ''}`
            })
            activeJobInfo = details.join(' | ')
          }
          else if (queued.length > 0) {
            activeJobInfo = `${queued.length} queued`
          }
          else {
            activeJobInfo = `${completed.length}/${jobsData.jobs.length} completed`
          }
        }
      }
      catch {
        activeJobInfo = 'fetching jobs...'
      }
    }
    else if (r.conclusion === 'failure') {
      try {
        const jobsData = ghJson(`api /repos/${REPO}/actions/runs/${r.databaseId}/jobs`)
        if (jobsData && jobsData.jobs) {
          const failedJob = jobsData.jobs.find(j => j.conclusion === 'failure')
          if (failedJob) {
            const failedStep = failedJob.steps?.find(s => s.conclusion === 'failure')
            activeJobInfo = `FAILED: ${failedJob.name}${failedStep ? ` -> [${failedStep.name}]` : ''}`
          }
        }
      }
      catch {}
    }

    summaries.push({
      id: r.databaseId,
      name: r.name,
      status: r.status,
      conclusion: r.conclusion || 'running',
      duration: formatDuration(r.createdAt, r.status === 'completed' ? r.updatedAt : null),
      sha: (r.headSha || '').slice(0, 7),
      details: activeJobInfo,
    })
  }

  return summaries
}

function printStatusTable() {
  const summaries = getWorkflowSummary()
  if (summaries.length === 0) {
    console.info('No recent workflow runs found.')
    return { activeCount: 0, hasFailure: false }
  }

  console.info(`\n🚀 GitHub Actions Status (${REPO}) at ${new Date().toLocaleTimeString()}:`)
  console.info('─'.repeat(95))
  console.info(`${'ID'.padEnd(13)} ${'Workflow'.padEnd(32)} ${'Status'.padEnd(12)} ${'Time'.padEnd(8)} ${'Details'}`)
  console.info('─'.repeat(95))

  let activeCount = 0
  let hasFailure = false

  for (const s of summaries) {
    if (s.status !== 'completed')
      activeCount++
    if (s.conclusion === 'failure')
      hasFailure = true

    let statusDisplay = s.conclusion
    if (s.status !== 'completed') {
      statusDisplay = `⟳ ${s.status}`
    }
    else if (s.conclusion === 'success') {
      statusDisplay = '✓ success'
    }
    else if (s.conclusion === 'failure') {
      statusDisplay = '✗ failure'
    }

    console.info(`${String(s.id).padEnd(13)} ${s.name.slice(0, 30).padEnd(32)} ${statusDisplay.padEnd(12)} ${s.duration.padEnd(8)} ${s.details}`)
  }

  console.info('─'.repeat(95))
  return { activeCount, hasFailure }
}

async function main() {
  if (isSelfTest) {
    selfTest()
    return
  }

  if (isRelease) {
    if (!tagArg) {
      console.error('❌ Error: --release requires --tag=<tag> (a release check without a tag verifies the wrong release).')
      process.exit(1)
    }
    verifyReleaseAssets(tagArg, { advisory: isAdvisory })
    return
  }

  if (isLogError) {
    const runId = args.find(a => /^\d+$/.test(a))
    const target = runId ? `run view ${runId} --log-failed` : 'run view --log-failed'
    console.info(gh(`${target} -R ${REPO}`))
    return
  }

  const { activeCount } = printStatusTable()

  if (isWatch && activeCount > 0) {
    console.info(`\nWatching ${activeCount} active run(s)... (press Ctrl+C to stop)`)
    while (true) {
      await new Promise(r => setTimeout(r, 20000))
      const res = printStatusTable()
      if (res.activeCount === 0) {
        console.info('\n🎉 All runs completed.')
        if (tagArg)
          verifyReleaseAssets(tagArg)
        process.exit(res.hasFailure || process.exitCode ? 1 : 0)
      }
    }
  }
}

main().catch((err) => {
  console.error(`❌ ${err.message}`)
  process.exit(process.exitCode || 1)
})
