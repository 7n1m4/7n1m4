import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { defineStore } from 'pinia'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

export type CaptionDocking = 'top' | 'bottom' | 'head' | 'none'
export type CaptionLayoutMode = 'single' | 'multi'

/** `settings/captions` as the daemon (`CaptionsSettings`) carries it. */
export interface DaemonCaptionsSettings {
  enabled: boolean
  fontSize: number
  opacity: number
  docking: string
}

export const useSettingsCaptions = defineStore('settings-captions', () => {
  const showCaptions = useLocalStorageManualReset<boolean>('settings/captions/enabled', true)
  const fontSize = useLocalStorageManualReset<number>('settings/captions/font-size', 100)
  const opacity = useLocalStorageManualReset<number>('settings/captions/opacity', 20)
  const docking = useLocalStorageManualReset<CaptionDocking>('settings/captions/docking', 'none')
  const followStageVisibility = useLocalStorageManualReset<boolean>('settings/captions/follow-stage-visibility', true)
  const followStagePosition = useLocalStorageManualReset<boolean>('settings/captions/follow-stage-position', true)
  const layoutMode = useLocalStorageManualReset<CaptionLayoutMode>('settings/captions/layout-mode', 'single')
  const resetTrigger = useLocalStorageManualReset<number>('settings/captions/reset-trigger', 0)

  // Head-tethered caption plank (in-scene PIXI renderer). Independent of the
  // windowed caption above; both may run simultaneously. Live2D-only in MVP.
  const headTetheredCaptionEnabled = useLocalStorageManualReset<boolean>('settings/captions/head-tethered/enabled', false)
  const headTetheredCaptionOffset = useLocalStorageManualReset<{ x: number, y: number }>('settings/captions/head-tethered/offset', { x: 0, y: -15 })
  const headTetheredCaptionFollowStrength = useLocalStorageManualReset<number>('settings/captions/head-tethered/follow-strength', 100)

  function resetState() {
    showCaptions.reset()
    fontSize.reset()
    opacity.reset()
    docking.reset()
    followStageVisibility.reset()
    followStagePosition.reset()
    layoutMode.reset()
    resetTrigger.reset()
    headTetheredCaptionEnabled.reset()
    headTetheredCaptionOffset.reset()
    headTetheredCaptionFollowStrength.reset()
  }

  function triggerReset() {
    resetTrigger.value = Date.now()
  }

  // Only the four fields `CaptionsSettings` defines are daemon-owned. The
  // follow/layout/head-tether knobs are not in the daemon schema, so they stay
  // local and are deliberately left out of both directions of the bridge.
  bridgeDaemonSettings<DaemonCaptionsSettings>(
    'captions',
    () => ({
      enabled: showCaptions.value,
      fontSize: fontSize.value,
      opacity: opacity.value,
      docking: docking.value,
    }),
    (value) => {
      showCaptions.value = value.enabled
      fontSize.value = value.fontSize
      opacity.value = value.opacity
      docking.value = value.docking as CaptionDocking
    },
  )

  return {
    showCaptions,
    fontSize,
    opacity,
    docking,
    followStageVisibility,
    followStagePosition,
    layoutMode,
    resetTrigger,
    headTetheredCaptionEnabled,
    headTetheredCaptionOffset,
    headTetheredCaptionFollowStrength,
    resetState,
    triggerReset,
  }
})