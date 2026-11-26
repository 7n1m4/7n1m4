import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { defineStore } from 'pinia'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

/** `settings/spine` as the daemon (`SpineSettings`) carries it. */
export interface DaemonSpineSettings {
  maxFps: number
  renderScale: number
  mixDuration: number
  animationSpeed: number
  idleAnimationEnabled: boolean
  scalePos: { x: number, y: number, scale: number }
}

export const useSettingsSpine = defineStore('settings-spine', () => {
  const spineDefaultMixDuration = useLocalStorageManualReset<number>('settings/spine/default-mix', 0.2)
  const spineIdleAnimationEnabled = useLocalStorageManualReset<boolean>('settings/spine/idle-enabled', true)
  const spineMaxFps = useLocalStorageManualReset<number>('settings/spine/max-fps', 0)
  const spineRenderScale = useLocalStorageManualReset<number>('settings/spine/render-scale', 1)

  // Owned elsewhere: `animationSpeed` lives in the spine runtime store and
  // `scalePos` in the positioning store. Mirrored so the daemon round trip
  // preserves them instead of resetting them to their defaults.
  const spineAnimationSpeed = useLocalStorageManualReset<number>('settings/spine/animation-speed', 1)
  const spineScalePos = useLocalStorageManualReset<{ x: number, y: number, scale: number }>('settings/spine/scale-pos', { x: 0, y: 0, scale: 1 })

  function resetState() {
    spineDefaultMixDuration.reset()
    spineIdleAnimationEnabled.reset()
    spineMaxFps.reset()
    spineRenderScale.reset()
    spineAnimationSpeed.reset()
    spineScalePos.reset()
  }

  bridgeDaemonSettings<DaemonSpineSettings>(
    'spine',
    () => ({
      maxFps: spineMaxFps.value,
      renderScale: spineRenderScale.value,
      mixDuration: spineDefaultMixDuration.value,
      animationSpeed: spineAnimationSpeed.value,
      idleAnimationEnabled: spineIdleAnimationEnabled.value,
      scalePos: spineScalePos.value,
    }),
    (value) => {
      spineMaxFps.value = value.maxFps
      spineRenderScale.value = value.renderScale
      spineDefaultMixDuration.value = value.mixDuration
      spineAnimationSpeed.value = value.animationSpeed
      spineIdleAnimationEnabled.value = value.idleAnimationEnabled
      spineScalePos.value = value.scalePos
    },
  )

  return {
    spineDefaultMixDuration,
    spineIdleAnimationEnabled,
    spineMaxFps,
    spineRenderScale,
    spineAnimationSpeed,
    spineScalePos,

    resetState,
  }
})