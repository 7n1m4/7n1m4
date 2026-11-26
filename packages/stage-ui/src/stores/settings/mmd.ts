import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { defineStore } from 'pinia'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

/** `settings/mmd` as the daemon (`MmdSettings`) carries it. */
export interface DaemonMmdSettings {
  mmdIdleAnimationEnabled: boolean
  mmdRenderScale: number
}

export const useSettingsMmd = defineStore('settings-mmd', () => {
  const mmdIdleAnimationEnabled = useLocalStorageManualReset<boolean>('settings/mmd/idle-enabled', true)
  const mmdRenderScale = useLocalStorageManualReset<number>('settings/mmd/render-scale', 1)

  function resetState() {
    mmdIdleAnimationEnabled.reset()
    mmdRenderScale.reset()
  }

  bridgeDaemonSettings<DaemonMmdSettings>(
    'mmd',
    () => ({
      mmdIdleAnimationEnabled: mmdIdleAnimationEnabled.value,
      mmdRenderScale: mmdRenderScale.value,
    }),
    (value) => {
      mmdIdleAnimationEnabled.value = value.mmdIdleAnimationEnabled
      mmdRenderScale.value = value.mmdRenderScale
    },
  )

  return {
    mmdIdleAnimationEnabled,
    mmdRenderScale,

    resetState,
  }
})