import { nextTick, watch } from 'vue'

import { daemonRequest, hasDaemon } from './daemon-rpc'

/**
 * Daemon-backed settings sections.
 *
 * The names are the daemon's own section keys — the single source of truth is
 * `settings_section()` in `crates/anima-daemon/src/core.rs`, which both
 * `settings.get` and `settings.set` route through. Adding a section there is
 * what makes it addressable here.
 */
export type DaemonSettingsSection
  = | 'general'
    | 'chat'
    | 'theme'
    | 'control-strip'
    | 'cards'
    | 'stage-model'
    | 'captions'
    | 'stage-window'
    | 'positioning'
    | 'spine'
    | 'mmd'
    | 'live2d'
    | 'audio-device'
    | 'user-profile'
    | 'local-llm'

/** `data` payload of a `settings.get` reply. */
interface SettingsGetReply {
  section: string
  settings: string
}

/** `data` payload of a `settings.set` reply. */
interface SettingsSetReply {
  ok: boolean
}

/**
 * Read one settings section from the daemon.
 *
 * The daemon carries the section as a JSON string (`SettingsGetReply.settings`),
 * so it is decoded here and callers see plain data. Throws when the daemon is
 * unreachable or the section is unknown, which is what makes a caller fall back
 * to its local cache.
 */
export async function fetchDaemonSettings<T>(section: DaemonSettingsSection): Promise<T> {
  const reply = await daemonRequest<SettingsGetReply>('settings.get', { section })
  return JSON.parse(reply.settings) as T
}

/** Write one settings section to the daemon, which owns it from then on. */
export async function saveDaemonSettings(section: DaemonSettingsSection, value: unknown): Promise<void> {
  const reply = await daemonRequest<SettingsSetReply>('settings.set', { section, settings: value })
  if (!reply.ok)
    throw new Error(`daemon rejected settings for section: ${section}`)
}

/** Options for {@link bridgeDaemonSettings}. */
export interface DaemonSettingsBridgeOptions {
  /**
   * Skip the daemon round trip. Defaults to `hasDaemon()`, so stage-web keeps
   * its localStorage-only behavior; tests and embedders can force either path.
   */
  enabled?: boolean
  /** Watch deeply (the default); set false for sections held in a single ref. */
  deep?: boolean
}

/**
 * Make the daemon the authority for one settings section while the local
 * storage-backed state stays the cache.
 *
 * On bridge, the daemon value is hydrated into `read`'s target; afterwards
 * every change to that state is written back. A failed round trip is swallowed
 * on purpose: the daemon owns the value, but a temporarily unreachable gateway
 * must not break the settings UI that still has a usable cache.
 *
 * Returns a stop handle that also drops the hydration write-back in flight.
 */
export function bridgeDaemonSettings<T>(
  section: DaemonSettingsSection,
  read: () => T,
  write: (value: T) => void,
  options: DaemonSettingsBridgeOptions = {},
): { stop: () => void } {
  const enabled = options.enabled ?? hasDaemon()
  let stopped = false
  let hydrating = true
  let hydration = 0
  // `read()` allocates a fresh object each call, so snapshot the serialized
  // value at bridge time to detect edits made while settings.get is in flight.
  const atBridge = read()

  const stopWatch = watch(
    read,
    (value) => {
      if (stopped || hydrating || !enabled)
        return
      hydrating = true
      const started = ++hydration
      void saveDaemonSettings(section, value).catch(() => {}).finally(() => {
        if (started === hydration)
          hydrating = false
      })
    },
    { deep: options.deep ?? true },
  )

  if (enabled) {
    const started = ++hydration
    void fetchDaemonSettings<T>(section).then((value) => {
      if (stopped || started !== hydration)
        return
      // An edit made while settings.get was in flight wins: leave the local
      // value alone so it is saved, and skip this stale hydration entirely.
      if (JSON.stringify(read()) !== JSON.stringify(atBridge)) {
        hydrating = false
        // The watcher that recorded this edit is still queued; replay the
        // write after it runs so the daemon does not keep stale data.
        nextTick(() => {
          if (!stopped && started === hydration)
            void saveDaemonSettings(section, read()).catch(() => {})
        })
        return
      }
      write(value)
      // Let the watcher queued by hydration observe the installed value before
      // accepting further edits as write-backs.
      nextTick(() => {
        if (started === hydration)
          hydrating = false
      })
    }).catch(() => {
      if (started === hydration)
        hydrating = false
    })
  }

  return {
    stop: () => {
      stopped = true
      stopWatch()
    },
  }
}
