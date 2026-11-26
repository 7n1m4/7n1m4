import { useLocalStorageManualReset } from '@proj-anima/stage-shared/composables'
import { defineStore } from 'pinia'

import { bridgeDaemonSettings } from '../../composables/daemon-settings'

/** `settings/user-profile` as the daemon (`UserProfileSettings`) carries it. */
export interface DaemonUserProfileSettings {
  name: string
  description: string
  prompt: string
  voiceProfileId: string
}

export const useSettingsUserProfile = defineStore('settings-user-profile', () => {
  const name = useLocalStorageManualReset<string>('settings/user-profile/name', 'Richy')
  const description = useLocalStorageManualReset<string>(
    'settings/user-profile/description',
    'A hands-on, down-to-earth creator who loves building things from scratch. Prefers honest, direct conversation and cozy downtime after a long day of work.',
  )
  const prompt = useLocalStorageManualReset<string>('settings/user-profile/prompt', '')
  const voiceProfileId = useLocalStorageManualReset<string>('settings/user-profile/voice-profile-id', '')

  function resetState() {
    name.reset()
    description.reset()
    prompt.reset()
    voiceProfileId.reset()
  }

  bridgeDaemonSettings<DaemonUserProfileSettings>(
    'user-profile',
    () => ({
      name: name.value,
      description: description.value,
      prompt: prompt.value,
      voiceProfileId: voiceProfileId.value,
    }),
    (value) => {
      name.value = value.name
      description.value = value.description
      prompt.value = value.prompt
      voiceProfileId.value = value.voiceProfileId
    },
  )

  return {
    name,
    description,
    prompt,
    voiceProfileId,
    resetState,
  }
})