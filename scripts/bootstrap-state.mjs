#!/usr/bin/env node

/**
 * Round-17 deterministic state bootstrap.
 *
 * Offline and git-write-free: inputs are the five read-only wave-0 receipts,
 * the real .wave0 tree, `state/pinned-guards.sha` (checked against the git
 * index), and constants owned by scripts/sm.mjs. A real run appends the
 * genesis event once and materialises every state/* artifact. A second run is
 * a byte-for-byte no-op.
 *
 * Usage:
 *   node scripts/bootstrap-state.mjs --dry-run
 *   node scripts/bootstrap-state.mjs
 */

import path from 'node:path'
import process from 'node:process'

import { Buffer } from 'node:buffer'
import { pathToFileURL } from 'node:url'

import {
  buildAllState,
  buildBindings,
  buildGenesis,
  buildUnanchoredEvents,
  deriveHead,
  guardPinsFromIndex,
  hashEvent,
  ingestReceipts,
  loadGuardPins,
  readEvents,
  RED_EVIDENCE,
  scanWave0Receipts,
  writeAllState,
} from './sm.mjs'

const args = process.argv.slice(2)
const dryRun = args.includes('--dry-run')

function fail(message) {
  throw new Error(`bootstrap-state: ${message}`)
}

function run() {
  const receipts = ingestReceipts()
  const unanchored = scanWave0Receipts().unanchored
  const guardPins = loadGuardPins()
  const expectedPinText = Object.entries(guardPins)
    .sort(([a], [b]) => Buffer.compare(Buffer.from(a), Buffer.from(b)))
    .map(([p, sha]) => `${sha} ${p}\n`)
    .join('')
  if (guardPinsFromIndex().text !== expectedPinText)
    fail('pinned guard drift against git index')

  const genesis = buildGenesis(receipts, unanchored, guardPins)
  const expectedUnanchored = buildUnanchoredEvents(unanchored, hashEvent(genesis))
  const events = readEvents()
  const gen = events.filter(event => event?.type === 'genesis')
  if (gen.length > 1)
    fail(`expected at most one genesis event, found ${gen.length}`)
  if (gen.length === 0) {
    events.push(genesis, ...expectedUnanchored)
  }
  else if (JSON.stringify(gen[0]) !== JSON.stringify(genesis)) {
    fail('existing genesis event does not match the deterministic genesis payload')
  }

  const actualUnanchored = events.filter(event => event?.type === 'WAVE0_RECEIPT_INGESTED')
  if (JSON.stringify(actualUnanchored) !== JSON.stringify(expectedUnanchored))
    fail('unanchored receipt events do not match the live .wave0 scan')

  events.sort((a, b) => a.seq - b.seq)
  const bindings = buildBindings(receipts, unanchored, guardPins)
  const files = buildAllState({
    bindings,
    events,
    receipts,
    unanchored,
    guardPins,
    headSha: deriveHead(events),
  })

  if (dryRun) {
    for (const name of [...files.keys()].sort()) {
      console.info(`[BOOTSTRAP_DRY_RUN] would write state/${name} (${Buffer.byteLength(files.get(name), 'utf8')} bytes)`)
    }
    console.info(`[BOOTSTRAP_DRY_RUN] genesis: ${gen.length === 0 ? 1 : gen.length}, receipts: ${receipts.length}, unanchored: ${unanchored.length}, guard pins: ${Object.keys(guardPins).length}`)
    console.info(`[BOOTSTRAP_DRY_RUN] red commands preserved: ${RED_EVIDENCE.commands.length}`)
    return 0
  }

  writeAllState(files)
  for (const name of [...files.keys()].sort()) {
    console.info(`[BOOTSTRAP] wrote state/${name} (${Buffer.byteLength(files.get(name), 'utf8')} bytes)`)
  }
  return 0
}

const isMain = process.argv[1]
  ? import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
  : false

if (isMain) {
  try {
    process.exit(run())
  }
  catch (error) {
    console.error(`[BOOTSTRAP_ERROR] ${error.message}`)
    process.exit(1)
  }
}
