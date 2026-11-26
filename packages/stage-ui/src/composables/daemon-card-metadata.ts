import type { CardMetadataReply, ProvidersListReply } from '@proj-anima/server-shared/types'

import { daemonRequest, hasDaemon } from './daemon-rpc'

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

function parseCardMetadata(value: unknown): DaemonCardMetadata {
  if (!value || typeof value !== 'object' || !('liked' in value) || !('bookmarked' in value))
    throw new Error('daemon returned malformed card metadata')
  const { liked, bookmarked } = value as CardMetadataReply
  if (typeof liked !== 'boolean' || typeof bookmarked !== 'boolean')
    throw new Error('daemon returned malformed card metadata')
  return { liked, bookmarked }
}

/**
 * Whether this stage ever talks to a daemon. Stage-web (no daemon) returns
 * false; the caller falls back to the local IndexedDB cache.
 */
export function hasDaemonCardMetadata(): boolean {
  return hasDaemon()
}

/** Read one card's daemon-owned flags. Missing metadata means both false. */
export async function fetchDaemonCardMetadata(id: string): Promise<DaemonCardMetadata> {
  const reply = await daemonRequest<unknown>('cards.metadata', { id })
  return parseCardMetadata(reply)
}

/** Write one card's daemon-owned flags with explicit booleans (never a flip). */
export async function setDaemonCardMetadata(id: string, metadata: DaemonCardMetadata): Promise<DaemonCardMetadata> {
  const reply = await daemonRequest<unknown>('cards.metadata.set', {
    id,
    liked: metadata.liked,
    bookmarked: metadata.bookmarked,
  })
  return parseCardMetadata(reply)
}

export async function listDaemonCards(): Promise<CardListReply> {
  return daemonRequest<CardListReply>('cards.list', {})
}

export async function getDaemonCard(id: string): Promise<CardGetReply> {
  return daemonRequest<CardGetReply>('cards.get', { id })
}

export async function createDaemonCard(name: string, document: unknown): Promise<CardCreateReply> {
  return daemonRequest<CardCreateReply>('cards.create', { name, document })
}

export async function updateDaemonCard(id: string, document: unknown, name?: string): Promise<CardUpdateReply> {
  return daemonRequest<CardUpdateReply>('cards.update', { id, document, ...(name !== undefined ? { name } : {}) })
}

export async function deleteDaemonCard(id: string): Promise<CardDeleteReply> {
  return daemonRequest<CardDeleteReply>('cards.delete', { id })
}

export async function listDaemonProviders(): Promise<ProvidersListReply> {
  return daemonRequest<ProvidersListReply>('providers.list', {})
}

export async function saveDaemonProvider(payload: Record<string, unknown>): Promise<{ id: string }> {
  return daemonRequest<{ id: string }>('providers.save', payload)
}

export async function deleteDaemonProvider(id: string): Promise<{ deleted: boolean }> {
  return daemonRequest<{ deleted: boolean }>('providers.delete', { id })
}
