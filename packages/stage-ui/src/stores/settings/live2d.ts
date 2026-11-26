import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { defineStore } from 'pinia'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

/** `settings/live2d` as the daemon (`Live2dSettings`) carries it. */
export interface DaemonLive2dSettings {
  live2dDisableFocus: boolean
  live2dFollowSpeed: number
  live2dIdleAnimationEnabled: boolean
  live2dAutoBlinkEnabled: boolean
  live2dForceAutoBlinkEnabled: boolean
  live2dShadowEnabled: boolean
  live2dMaxFps: number
}

export const useSettingsLive2d = defineStore('settings-live2d', () => {
  const live2dDisableFocus = useLocalStorageManualReset<boolean>('settings/live2d/disable-focus', false)
  const live2dFollowSpeed = useLocalStorageManualReset<number>('settings/live2d/follow-speed', 0.5)
  const live2dIdleAnimationEnabled = useLocalStorageManualReset<boolean>('settings/live2d/idle-animation-enabled', true)
  const live2dAutoBlinkEnabled = useLocalStorageManualReset<boolean>('settings/live2d/auto-blink-enabled', true)
  const live2dForceAutoBlinkEnabled = useLocalStorageManualReset<boolean>('settings/live2d/force-auto-blink-enabled', false)
  const live2dShadowEnabled = useLocalStorageManualReset<boolean>('settings/live2d/shadow-enabled', true)
  const live2dMaxFps = useLocalStorageManualReset<number>('settings/live2d/max-fps', 0)

  function resetState() {
    live2dDisableFocus.reset()
    live2dFollowSpeed.reset()
    live2dIdleAnimationEnabled.reset()
    live2dAutoBlinkEnabled.reset()
    live2dForceAutoBlinkEnabled.reset()
    live2dShadowEnabled.reset()
    live2dMaxFps.reset()
  }

  bridgeDaemonSettings<DaemonLive2dSettings>(
    'live2d',
    () => ({
      live2dDisableFocus: live2dDisableFocus.value,
      live2dFollowSpeed: live2dFollowSpeed.value,
      live2dIdleAnimationEnabled: live2dIdleAnimationEnabled.value,
      live2dAutoBlinkEnabled: live2dAutoBlinkEnabled.value,
      live2dForceAutoBlinkEnabled: live2dForceAutoBlinkEnabled.value,
      live2dShadowEnabled: live2dShadowEnabled.value,
      live2dMaxFps: live2dMaxFps.value,
    }),
    (value) => {
      live2dDisableFocus.value = value.live2dDisableFocus
      live2dFollowSpeed.value = value.live2dFollowSpeed
      live2dIdleAnimationEnabled.value = value.live2dIdleAnimationEnabled
      live2dAutoBlinkEnabled.value = value.live2dAutoBlinkEnabled
      live2dForceAutoBlinkEnabled.value = value.live2dForceAutoBlinkEnabled
      live2dShadowEnabled.value = value.live2dShadowEnabled
      live2dMaxFps.value = value.live2dMaxFps
    },
  )

  return {
    live2dDisableFocus,
    live2dFollowSpeed,
    live2dIdleAnimationEnabled,
    live2dAutoBlinkEnabled,
    live2dForceAutoBlinkEnabled,
    live2dShadowEnabled,
    live2dMaxFps,
    resetState,
  }
})