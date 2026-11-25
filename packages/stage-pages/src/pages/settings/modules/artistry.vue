<script setup lang="ts">
import { useBackgroundStore } from '@proj-anima/stage-ui/stores/background'
import { useAiriCardStore } from '@proj-anima/stage-ui/stores/modules/airi-card'
import { storeToRefs } from 'pinia'

const backgroundStore = useBackgroundStore()
const airiCardStore = useAiriCardStore()
const { journalEntries } = storeToRefs(backgroundStore)

// NOTICE: only pre-existing journal art is listed here. Generation is deprecated;
// this page never calls a generation backend and never mutates stored image data.


function applyToStage(id: string) {
  const card = airiCardStore.activeCard
  if (!card?.extensions?.airi?.modules)
    return
  card.extensions.airi.modules.activeBackgroundId = id
}
</script>

<template>
  <div class="flex flex-col gap-6">
    <div class="flex items-center justify-between gap-4">
      <div>
        <h2 class="text-lg text-neutral-800 font-bold md:text-2xl dark:text-neutral-100">
          Image Journal
        </h2>
        <p class="text-xs text-neutral-400 dark:text-neutral-500">
          Image generation is deprecated and disabled. Existing generated images remain available in the image journal; future image control targets an external SAI integration.
        </p>
      </div>
      <div class="shrink-0 rounded-xl border border-amber-500/40 bg-amber-500/10 px-3 py-1.5 text-[11px] text-amber-700 font-semibold dark:text-amber-300">
        Generation disabled
      </div>
    </div>

    <div class="grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-3">
      <div
        v-for="entry in journalEntries"
        :key="entry.id"
        class="flex flex-col gap-2 rounded-2xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-900/50"
      >
        <img :src="backgroundStore.getBackgroundUrl(entry.id) || entry.url || undefined" :alt="entry.title" class="h-40 w-full rounded-xl object-cover">
        <div class="text-xs text-neutral-700 font-semibold dark:text-neutral-200">
          {{ entry.title }}
        </div>
        <div class="line-clamp-2 text-[11px] text-neutral-500 dark:text-neutral-400">
          {{ entry.prompt || 'No prompt recorded' }}
        </div>
        <button
          type="button"
          class="mt-1 rounded-xl bg-primary-500/10 px-3 py-1.5 text-xs text-primary-600 font-bold transition-all hover:bg-primary-500 hover:text-white dark:bg-primary-500/20 dark:text-primary-300"
          @click="applyToStage(entry.id)"
        >
          Apply to Stage
        </button>
      </div>
    </div>

    <div
      v-if="journalEntries.length === 0"
      class="rounded-2xl border border-neutral-200 bg-white p-8 text-center text-xs text-neutral-400 dark:border-neutral-800 dark:bg-neutral-900/50"
    >
      No generated images are stored in the image journal yet.
    </div>
  </div>
</template>

<route lang="yaml">
meta:
  layout: settings
  titleKey: settings.pages.modules.artistry.title
  subtitleKey: settings.title
  stageTransition:
    name: slide
</route>