<script setup lang="ts">
import { useArtistryStore } from '@proj-anima/stage-ui/stores/modules/artistry'
import { storeToRefs } from 'pinia'

const artistryStore = useArtistryStore()
const { pollinationsApiKey, pollinationsModel } = storeToRefs(artistryStore)
</script>

<template>
  <div class="flex flex-col gap-6">
    <div class="rounded-xl border border-amber-500/40 bg-amber-500/10 p-5">
      <div class="mb-3 flex items-center gap-3">
        <div class="i-solar:magic-stick-3-bold-duotone text-3xl text-amber-500" />
        <div>
          <h2 class="text-xl text-neutral-800 font-semibold dark:text-neutral-100">
            Image generation is deprecated
          </h2>
          <p class="text-sm text-neutral-600 dark:text-neutral-400">
            Pollinations provider settings are disabled. Image generation is deprecated and disabled; existing generated images remain available in the image journal. Future image control targets an external SAI integration.
          </p>
        </div>
      </div>
      <p class="text-xs text-neutral-500 dark:text-neutral-500">
        Existing configuration is preserved (model: {{ pollinationsModel || 'auto' }}, key: {{ pollinationsApiKey ? 'set' : 'not set' }}); nothing is reset.
      </p>
    </div>
  </div>
</template>

<route lang="yaml">
meta:
  layout: settings
  titleKey: settings.pages.providers.provider.pollinations.settings.title
  subtitleKey: settings.title
  stageTransition:
    name: slide
</route>