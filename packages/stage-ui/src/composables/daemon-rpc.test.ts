import type * as DaemonRpcModule from './daemon-rpc'

/**
 * `window` and `RUNTIME_ENVIRONMENT` decide whether a daemon exists, so the
 * env is primed before the module is resolved through `freshRpc()` below.
 */
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

/**
 * The daemon RPC transport.
 *
 * The seam under test is `daemonRequest`: what goes on the wire, and how each
 * server answer settles the call. A fake WebSocket stands in for the gateway —
 * the only boundary mocked — so the real auth handshake, request id, timeout
 * and teardown all run.
 */

interface SentFrame {
  type?: string
  authToken?: string
  action?: string
  payload?: Record<string, unknown>
  id?: string
}

/** One scripted fake socket: it records what the client sent. */
class FakeWebSocket {
  static instances: FakeWebSocket[] = []

  sent: SentFrame[] = []
  closed = false
  onopen: (() => void) | null = null
  onerror: (() => void) | null = null
  onmessage: ((event: { data: string }) => void) | null = null

  constructor(public url: string) {
    FakeWebSocket.instances.push(this)
  }

  send(raw: string) {
    this.sent.push(JSON.parse(raw) as SentFrame)
  }

  close() {
    this.closed = true
  }

  /** Deliver a server frame to the client. */
  receive(frame: unknown) {
    this.onmessage?.({ data: JSON.stringify(frame) })
  }

  /** Run the connection opening the browser would have performed. */
  open() {
    this.onopen?.()
  }

  /** The `rpc` frame the client sent, if it got past auth. */
  get rpcFrame(): SentFrame | undefined {
    return this.sent.find(frame => frame.type === 'rpc')
  }
}

/** Resolve the transport against a module registry reset per test. */
function freshRpc(): Promise<typeof DaemonRpcModule> {
  vi.resetModules()
  return import('./daemon-rpc')
}

let mod: typeof DaemonRpcModule

beforeEach(async () => {
  FakeWebSocket.instances = []
  vi.stubGlobal('WebSocket', FakeWebSocket as unknown as typeof WebSocket)
  localStorage.clear()
  localStorage.setItem('settings/connection/auth-token', 'test-token')
  mod = await freshRpc()
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('hasDaemon', () => {
  it('reports a daemon for a desktop runtime and none for stage-web', async () => {
    vi.stubEnv('RUNTIME_ENVIRONMENT', 'electron')
    expect(await freshRpc().then(rpc => rpc.hasDaemon())).toBe(true)

    vi.stubEnv('RUNTIME_ENVIRONMENT', 'browser')
    expect(await freshRpc().then(rpc => rpc.hasDaemon())).toBe(false)
  })
})

describe('resolveDaemonWebSocketUrl', () => {
  it('uses the connection override verbatim', () => {
    localStorage.setItem('settings/connection/websocket-url', 'wss://gateway.example.test/custom')
    expect(mod.resolveDaemonWebSocketUrl()).toBe('wss://gateway.example.test/custom')
  })

  it('derives the loopback gateway when nothing is configured', () => {
    expect(mod.resolveDaemonWebSocketUrl()).toBe('ws://localhost:6121/ws')
  })

  it('derives wss from the mirrored host, port and tls flag', () => {
    localStorage.setItem('settings/server-channel/hostname', 'gateway.example.test')
    localStorage.setItem('settings/server-channel/port', '7443')
    localStorage.setItem('settings/server-channel/tls-enabled', 'true')
    expect(mod.resolveDaemonWebSocketUrl()).toBe('wss://gateway.example.test:7443/ws')
  })

  // ROOT CAUSE:
  //
  // resolveDaemonWebSocketUrl accepted any WebSocket URL from localStorage and
  // passed it straight to `new WebSocket`, so a non-loopback `ws://` override
  // sent the bearer auth token over cleartext. The channel-server resolver in
  // stores/mods/api/channel-server.ts already enforces wss beyond loopback;
  // this transport must apply the same policy to overrides and derived URLs.
  it('rewrites a non-loopback ws:// override to wss:// before the token is sent', () => {
    localStorage.setItem('settings/connection/websocket-url', 'ws://192.168.1.10:6121/ws')
    expect(mod.resolveDaemonWebSocketUrl()).toBe('wss://192.168.1.10:6121/ws')
  })

  it('rewrites a derived non-loopback ws:// gateway to wss://', () => {
    localStorage.setItem('settings/server-channel/hostname', 'nas.example.lan')
    localStorage.setItem('settings/server-channel/tls-enabled', 'false')
    expect(mod.resolveDaemonWebSocketUrl()).toBe('wss://nas.example.lan:6121/ws')
  })

  it('keeps loopback ws:// unchanged', () => {
    localStorage.setItem('settings/connection/websocket-url', 'ws://127.0.0.1:6121/ws')
    expect(mod.resolveDaemonWebSocketUrl()).toBe('ws://127.0.0.1:6121/ws')
  })
})

describe('daemonRequest', () => {
  it('refuses to call a daemon that was never connected', async () => {
    localStorage.removeItem('settings/connection/auth-token')
    await expect(mod.daemonRequest('cards.list')).rejects.toThrow('daemon unavailable: not connected')
    expect(FakeWebSocket.instances).toHaveLength(0)
  })

  it('authenticates, sends the action with its payload, and resolves the reply data', async () => {
    const pending = mod.daemonRequest<{ cards: unknown[] }>('cards.list', { limit: 2 })
    const socket = FakeWebSocket.instances[0]
    expect(socket.url).toBe('ws://localhost:6121/ws')

    socket.open()
    expect(socket.sent[0]).toEqual({ type: 'auth', authToken: 'test-token' })

    socket.receive({ type: 'auth', ok: true })
    expect(socket.rpcFrame).toEqual({
      type: 'rpc',
      action: 'cards.list',
      payload: { limit: 2 },
      id: socket.rpcFrame?.id,
    })

    const cards = [{ id: 'card-1', name: 'card-1' }]
    socket.receive({ type: 'rpc', action: 'cards.list', id: socket.rpcFrame?.id, ok: true, data: { cards } })

    await expect(pending).resolves.toEqual({ cards })
    expect(socket.closed).toBe(true)
  })

  it('defaults the payload to an empty object', async () => {
    const pending = mod.daemonRequest('core.status')
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'auth', ok: true })
    expect(socket.rpcFrame?.payload).toEqual({})
    socket.receive({ type: 'rpc', id: socket.rpcFrame?.id, ok: true, data: { status: 'ready' } })
    await pending
  })

  it('rejects with the daemon error message and closes the socket', async () => {
    const pending = mod.daemonRequest('settings.get', { section: 'nope' })
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'auth', ok: true })
    socket.receive({
      type: 'rpc',
      id: socket.rpcFrame?.id,
      ok: false,
      error: { code: 'bad_request', message: 'unknown settings section: nope' },
    })

    await expect(pending).rejects.toThrow('unknown settings section: nope')
    expect(socket.closed).toBe(true)
  })

  it('rejects on an error frame and closes the socket', async () => {
    const pending = mod.daemonRequest('cards.list')
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'error', error: { code: 'forbidden', message: 'token rejected' } })

    await expect(pending).rejects.toThrow('token rejected')
    expect(socket.closed).toBe(true)
  })

  // ROOT CAUSE:
  //
  // The auth ack handler had no once-guard: a replayed `{ type: 'auth', ok: true }`
  // frame sent another `rpc` frame with the same id, duplicating non-idempotent
  // mutations (settings.set, cards.create, journal.append, …). The first ack
  // must consume the handshake; later acks must be ignored until the socket
  // closes.
  it('sends the RPC exactly once even when the auth ack is replayed', async () => {
    const pending = mod.daemonRequest('cards.create', { name: 'card' })
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'auth', ok: true })
    socket.receive({ type: 'auth', ok: true })
    socket.receive({ type: 'auth', ok: true })

    expect(socket.sent.filter(frame => frame.type === 'rpc')).toHaveLength(1)
    socket.receive({ type: 'rpc', id: socket.rpcFrame?.id, ok: true, data: { id: 'card-1' } })
    await expect(pending).resolves.toEqual({ id: 'card-1' })
  })

  it('ignores a reply carrying another request id', async () => {
    const pending = mod.daemonRequest('cards.list')
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'auth', ok: true })
    socket.receive({ type: 'rpc', id: 'someone-else', ok: true, data: { cards: [] } })

    expect(socket.closed).toBe(false)
    socket.receive({ type: 'rpc', id: socket.rpcFrame?.id, ok: true, data: { cards: [{ id: 'a' }] } })
    await expect(pending).resolves.toEqual({ cards: [{ id: 'a' }] })
  })

  it('rejects when the socket errors before answering', async () => {
    const pending = mod.daemonRequest('cards.list')
    FakeWebSocket.instances[0].onerror?.()
    await expect(pending).rejects.toThrow('daemon unreachable')
  })

  it('rejects with a timeout naming the action and closes the socket', async () => {
    vi.useFakeTimers()
    const pending = mod.daemonRequest('cards.list')
    const assertion = expect(pending).rejects.toThrow('daemon rpc timed out: cards.list')
    const socket = FakeWebSocket.instances[0]
    socket.open()
    socket.receive({ type: 'auth', ok: true })

    await vi.advanceTimersByTimeAsync(5000)

    await assertion
    expect(socket.closed).toBe(true)
  })
})
