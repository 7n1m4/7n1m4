// Repo-local pre tool_call guard against accidental full-file truncation by
// delegated workers. A small patch belongs in `edit`; a genuinely shortened
// file must carry a first-line content marker, which this hook strips before
// the write executes. The marker lives in content because `write` is strict:
// arbitrary input fields are not part of its public contract.
import { readFileSync, statSync } from 'node:fs'
import { isAbsolute, resolve } from 'node:path'

export const WHOLE_FILE_REPLACE_MARKER = 'whole_file_replace: true'

const MIN_EXISTING_LINES = 100
const MAX_PROPOSED_LINES = 10

const NON_PLAIN_PATH = /(?:^|\/)(?:\.git|node_modules|target)(?:\/|$)|(?:[.#][a-z0-9.+-]+:|^local:|^agent:|\.zip$|\.tar(?:\.[a-z0-9]+)?$|\.7z$|\.rar$|\.sqlite3?$|\.db$|\.db-wal$|\.db-shm$)/i

function countLines(text) {
  let lines = 0
  for (let i = 0; i < text.length; i += 1) {
    if (text.charCodeAt(i) === 10) lines += 1
  }
  if (text.length > 0 && !text.endsWith('\n')) lines += 1
  return lines
}

function stripMarker(content) {
  if (!content.startsWith(`${WHOLE_FILE_REPLACE_MARKER}\n`)) return undefined
  return content.slice(WHOLE_FILE_REPLACE_MARKER.length + 1)
}

// Pure decision helper: no filesystem access, so tests can assert the policy
// at the same boundary production uses. The opt-out is derived from content.
export function evaluateWriteShrink({ toolName, input, existingLineCount, proposedLineCount }) {
  if (toolName !== 'write') return undefined
  const pl = typeof input?.path === 'string' ? input.path : ''
  const content = typeof input?.content === 'string' ? input.content : ''
  if (!pl || !content || NON_PLAIN_PATH.test(pl)) return undefined
  if (stripMarker(content) !== undefined) return undefined
  if (!Number.isInteger(existingLineCount) || existingLineCount < MIN_EXISTING_LINES) return undefined
  if (!Number.isInteger(proposedLineCount) || proposedLineCount > MAX_PROPOSED_LINES) return undefined

  const existingLabel = `${existingLineCount} ${existingLineCount === 1 ? 'line' : 'lines'}`
  const proposedLabel = `${proposedLineCount} ${proposedLineCount === 1 ? 'line' : 'lines'}`
  return {
    block: true,
    reason: `write rejected: ${pl} has ${existingLabel} but the proposed content has only ${proposedLabel}; use edit for small patches, or make the first line exactly "${WHOLE_FILE_REPLACE_MARKER}" for an intentional full-file rewrite (the marker is stripped before writing)`,
  }
}

// A plain, regular file inside the workspace. Internal URLs, archives, DBs,
// directories, symlinks and special files are deliberately left alone.
function safeExistingLineCount(path, cwd) {
  const absolute = isAbsolute(path) ? path : resolve(cwd ?? process.cwd(), path)
  if (NON_PLAIN_PATH.test(path) || NON_PLAIN_PATH.test(absolute)) return undefined
  try {
    const stat = statSync(absolute, { throwIfNoEntry: false })
    if (!stat?.isFile()) return undefined
    return countLines(readFileSync(absolute, 'utf8'))
  } catch {
    return undefined
  }
}

export default function writeShrinkGuard(pi) {
  pi.on('tool_call', (event, ctx) => {
    if (event?.toolName !== 'write') return undefined
    const input = event.input
    const path = typeof input?.path === 'string' ? input.path : ''
    if (!path || typeof input?.content !== 'string') return undefined

    const cwd = typeof ctx?.cwd === 'string' ? ctx.cwd : process.cwd()
    const existingLineCount = safeExistingLineCount(path, cwd)
    if (existingLineCount === undefined) return undefined

    // Return replacement input for marked writes so the marker never reaches
    // disk. Non-block handlers may return `input` per the hook contract.
    const stripped = stripMarker(input.content)
    const decision = evaluateWriteShrink({
      toolName: 'write',
      input,
      existingLineCount,
      proposedLineCount: countLines(stripped ?? input.content),
    })
    if (decision) {
      decision.reason = decision.reason.replace(path, `${path} (relative to ${cwd})`)
      return decision
    }
    return stripped === undefined ? undefined : { input: { ...input, content: stripped } }
  })
}
