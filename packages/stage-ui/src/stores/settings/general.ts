import messages from '@proj-anima/i18n/locales'

import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { acceptHMRUpdate, defineStore } from 'pinia'
import { onMounted } from 'vue'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

const languageRemap: Record<string, string> = {
  'zh': 'zh-Hans',
  'zh-CN': 'zh-Hans',
  'zh-TW': 'zh-Hant',
  'zh-HK': 'zh-Hant',
  'en-US': 'en',
  'en-GB': 'en',
  'en-AU': 'en',
  'en': 'en',
  'es-ES': 'es',
  'es-MX': 'es',
  'es-AR': 'es',
  'es': 'es',
  'ru': 'ru',
  'ru-RU': 'ru',
  'fr': 'fr',
  'fr-FR': 'fr',
  'ja': 'ja',
  'ja-JP': 'ja',
}

/** `settings/general` as the daemon (`GeneralSettings`) carries it. */
export interface DaemonGeneralSettings {
  language: string
  disableTransitions: boolean
  usePageSpecificTransitions: boolean
  remoteSyncEnabled: boolean
  websocketSecureEnabled: boolean
  autostart: boolean
}

export const useSettingsGeneral = defineStore('settings-general', () => {
  const language = useLocalStorageManualReset<string>('settings/language', '')

  const disableTransitions = useLocalStorageManualReset<boolean>('settings/disable-transitions', true)
  const usePageSpecificTransitions = useLocalStorageManualReset<boolean>('settings/use-page-specific-transitions', true)

  const websocketSecureEnabled = useLocalStorageManualReset<boolean>('settings/websocket/secure-enabled', false)

  // Not owned by this store: mirrored so the daemon round trip preserves them
  // instead of resetting them to their defaults on every write-back.
  const remoteSyncEnabled = useLocalStorageManualReset<boolean>('settings/privacy/remote-sync-enabled', false)
  const autostart = useLocalStorageManualReset<boolean>('settings/autostart', false)

  function getLanguage() {
    let language = localStorage.getItem('settings/language')

    if (!language) {
      // Fallback to browser language
      language = navigator.language || 'en'
    }

    const languages = Object.keys(messages!)
    if (languageRemap[language || 'en'] != null) {
      language = languageRemap[language || 'en']
    }
    if (language && languages.includes(language))
      return language

    return 'en'
  }

  function resetState() {
    language.reset()
    disableTransitions.reset()
    usePageSpecificTransitions.reset()
    websocketSecureEnabled.reset()
    remoteSyncEnabled.reset()
    autostart.reset()
  }

  onMounted(() => language.value = getLanguage())

  bridgeDaemonSettings<DaemonGeneralSettings>(
    'general',
    () => ({
      language: language.value,
      disableTransitions: disableTransitions.value,
      usePageSpecificTransitions: usePageSpecificTransitions.value,
      remoteSyncEnabled: remoteSyncEnabled.value,
      websocketSecureEnabled: websocketSecureEnabled.value,
      autostart: autostart.value,
    }),
    (value) => {
      language.value = value.language
      disableTransitions.value = value.disableTransitions
      usePageSpecificTransitions.value = value.usePageSpecificTransitions
      remoteSyncEnabled.value = value.remoteSyncEnabled
      websocketSecureEnabled.value = value.websocketSecureEnabled
      autostart.value = value.autostart
    },
  )

  return {
    language,
    disableTransitions,
    usePageSpecificTransitions,
    websocketSecureEnabled,
    remoteSyncEnabled,
    autostart,
    getLanguage,
    resetState,
  }
})

// Phase 0B: pure localStorage-backed state plus one settings bridge — safe for
// direct Pinia HMR patching. No-op in production (import.meta.hot is undefined).
if (import.meta.hot) {
  import.meta.hot.accept(acceptHMRUpdate(useSettingsGeneral, import.meta.hot))
}