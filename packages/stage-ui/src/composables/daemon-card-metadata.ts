import type { CardMetadataReply, ProvidersListReply } from '@proj-anima/server-shared/types'

import { isStageWeb } from '@proj-anima/stage-shared'

// dist declarations lag the Rust-canonical generated source; keep shapes exact
// per packages/server-shared/src/types/generated/anima-channel.ts.
export interface CardInfo {
  id: string
  name: string
}
export interface CardListReply {
  cards: CardInfo[]
  truncated: boolean
}
export interface CardGetReply {
  card: unknown
}
export interface CardCreateReply {
  id: string
  name: string
}
export interface CardUpdateReply {
  updated: boolean
}
export interface CardDeleteReply {
  deleted: boolean
}

// Daemon CRUD + card-metadata RPC client. These verbs live on the WS data
// plane next to settings.set/providers.save — see
// crates/anima-daemon/src/gateway.rs. D-Bus is reserved for gateway control.
// Secret-free: no auth tokens or credentials are persisted here; the daemon's
// SQLite store is the source of truth. Supports BYOS (bring-your-own-storage).
export interface DaemonCardMetadata {
  liked: boolean
  bookmarked: boolean
}

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

const RPC_TIMEOUT_MS = 5000

function resolveWebSocketUrl(): string {
  const override = localStorage.getItem('settings/connection/websocket-url')
  if (override && override.trim())
    return override.trim()

  const tlsFlag = localStorage.getItem('settings/server-channel/tls-enabled')
  let tls = tlsFlag === 'true'
  if (tlsFlag === null) {
    try {
      tls = JSON.parse(localStorage.getItem('settings/server-channel/websocket-tls-config') ?? 'null') !== null
    }
    catch {
      tls = false
    }
  }

  const host = localStorage.getItem('settings/server-channel/hostname') || 'localhost'
  const port = localStorage.getItem('settings/server-channel/port') || '6121'
  return `${tls ? 'wss' : 'ws'}://${host}:${port}/ws`
}

function parseCardMetadata(value: unknown): DaemonCardMetadata {
  if (!value || typeof value !== 'object' || !('liked' in value) || !('bookmarked' in value))
    throw new Error('daemon returned malformed card metadata')
  const { liked, bookmarked } = value as CardMetadataReply
  if (typeof liked !== 'boolean' || typeof bookmarked !== 'boolean')
    throw new Error('daemon returned malformed card metadata')
  return { liked, bookmarked }
}

async function rpc<T>(action: string, payload: Record<string, unknown>): Promise<T> {
  const token = localStorage.getItem('settings/connection/auth-token')
  if (!token)
    throw new Error('daemon unavailable: not connected')

  const { promise, resolve, reject } = Promise.withResolvers<T>()
  const id = `${action}-${Date.now()}-${Math.random().toString(36).slice(2)}`
  const socket = new WebSocket(resolveWebSocketUrl())

  let timeout: ReturnType<typeof setTimeout>
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

/**
 * Whether this stage ever talks to a daemon. Stage-web (no daemon) returns
 * false; the caller falls back to the local IndexedDB cache.
 */
export function hasDaemonCardMetadata(): boolean {
  return !isStageWeb()
}

/** Read one card's daemon-owned flags. Missing metadata means both false. */
export async function fetchDaemonCardMetadata(id: string): Promise<DaemonCardMetadata> {
  const reply = await rpc<unknown>('cards.metadata', { id })
  return parseCardMetadata(reply)
}

/** Write one card's daemon-owned flags with explicit booleans (never a flip). */
export async function setDaemonCardMetadata(id: string, metadata: DaemonCardMetadata): Promise<DaemonCardMetadata> {
  const reply = await rpc<unknown>('cards.metadata.set', {
    id,
    liked: metadata.liked,
    bookmarked: metadata.bookmarked,
  })
  return parseCardMetadata(reply)
}

export async function listDaemonCards(): Promise<CardListReply> {
  return rpc<CardListReply>('cards.list', {})
}

export async function getDaemonCard(id: string): Promise<CardGetReply> {
  return rpc<CardGetReply>('cards.get', { id })
}

export async function createDaemonCard(name: string, document: unknown): Promise<CardCreateReply> {
  return rpc<CardCreateReply>('cards.create', { name, document })
}

export async function updateDaemonCard(id: string, document: unknown, name?: string): Promise<CardUpdateReply> {
  return rpc<CardUpdateReply>('cards.update', { id, document, ...(name !== undefined ? { name } : {}) })
}

export async function deleteDaemonCard(id: string): Promise<CardDeleteReply> {
  return rpc<CardDeleteReply>('cards.delete', { id })
}

export async function listDaemonProviders(): Promise<ProvidersListReply> {
  return rpc<ProvidersListReply>('providers.list', {})
}

export async function saveDaemonProvider(payload: Record<string, unknown>): Promise<{ id: string }> {
  return rpc<{ id: string }>('providers.save', payload)
}

export async function deleteDaemonProvider(id: string): Promise<{ deleted: boolean }> {
  return rpc<{ deleted: boolean }>('providers.delete', { id })
}

export const hasDaemonRpc = hasDaemonCardMetadata
