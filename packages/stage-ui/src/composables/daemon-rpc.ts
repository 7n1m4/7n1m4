import { isStageWeb } from '@proj-anima/stage-shared'

import { resolveWebSocketUrl } from '../stores/mods/api/channel-server'

/**
 * Shared WebSocket transport for the daemon's renderer RPC plane.
 *
 * Every daemon verb the Vue stage calls (`cards.*`, `providers.*`,
 * `settings.get`/`settings.set`, …) arrives here: one auth handshake, one
 * request id, one timeout, one place that decides whether a daemon exists at
 * all. See `crates/anima-daemon/src/gateway.rs` for the server side and
 * `docs/design-daemon-gateway.md` for the frame contract.
 *
 * Secret-free: the auth token is read from the connection settings the desktop
 * shell mirrors into localStorage and is never persisted by this module. The
 * daemon's SQLite store is the source of truth; localStorage is a cache.
 */

interface RpcErrorObject {
  code: string
  message: string
}

interface RpcReply {
  type?: string
  ok?: boolean
  action?: string
  data?: unknown
  error?: RpcErrorObject
  id?: unknown
}

/** Host timer handle returned by `setTimeout`. */
type DaemonRpcTimer = ReturnType<typeof setTimeout>

const RPC_TIMEOUT_MS = 5000

/**
 * Whether this stage ever talks to a daemon. Stage-web (no daemon) returns
 * false; the caller falls back to its local cache.
 */
export function hasDaemon(): boolean {
  return !isStageWeb()
}

/**
 * Resolve the gateway WebSocket URL from the connection settings the desktop
 * shell mirrors into localStorage. Delegates to the channel-server resolver so
 * the RPC plane applies the same rule as the event plane: a non-loopback
 * `ws://` is upgraded to `wss://` before the bearer token goes on the wire.
 */
export function resolveDaemonWebSocketUrl(): string {
  return resolveWebSocketUrl(key => localStorage.getItem(key))
}

/**
 * Call one daemon RPC verb over a short-lived authenticated WebSocket.
 *
 * The socket authenticates, sends `{ type: 'rpc', action, payload, id }` and
 * resolves with the reply's `data`. Every exit path closes the socket and
 * clears the timeout, so a rejected call never leaks a connection.
 */
export async function daemonRequest<T>(action: string, payload: Record<string, unknown> = {}): Promise<T> {
  const token = localStorage.getItem('settings/connection/auth-token')
  if (!token)
    throw new Error('daemon unavailable: not connected')

  const { promise, resolve, reject } = Promise.withResolvers<T>()
  const id = `${action}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  const socket = new WebSocket(resolveDaemonWebSocketUrl())

  let authenticated = false
  let timeout: DaemonRpcTimer
  const settle = (fn: () => void) => {
    clearTimeout(timeout)
    socket.close()
    fn()
  }
  timeout = setTimeout(() => {
    settle(() => reject(new Error(`daemon rpc timed out: ${action}`)))
  }, RPC_TIMEOUT_MS)

  socket.onopen = () => {
    socket.send(JSON.stringify({ type: 'auth', authToken: token }))
  }
  socket.onerror = () => {
    settle(() => reject(new Error('daemon unreachable')))
  }
  socket.onmessage = (event) => {
    let frame: RpcReply | null = null
    try {
      frame = JSON.parse(String(event.data)) as RpcReply
    }
    catch {
      return
    }
    if (!frame || typeof frame !== 'object') {
      return
    }
    if (frame.type === 'auth' && frame.ok) {
      // Only the first ack consumes the handshake: replays must never send a
      // second copy of a non-idempotent RPC (settings.set, cards.create, …).
      if (authenticated)
        return
      authenticated = true
      socket.send(JSON.stringify({ type: 'rpc', action, payload, id }))
      return
    }
    if (frame.type === 'error') {
      settle(() => reject(new Error(frame?.error?.message || 'daemon rpc failed')))
      return
    }
    if (frame.type === 'rpc' && frame.id === id) {
      if (frame.ok) {
        settle(() => resolve(frame.data as T))
      }
      else {
        settle(() => reject(new Error(frame.error?.message || 'daemon rpc failed')))
      }
    }
  }

  return await promise
}
