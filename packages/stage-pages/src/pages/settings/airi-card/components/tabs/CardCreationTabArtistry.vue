<script setup lang="ts">
defineProps<{
  artistryProviderOptions: { value: string, label: string }[]
  defaultArtistryProviderPlaceholder: string
}>()
</script>

<template>
  <div class="tab-content ml-auto mr-auto w-95% flex flex-col gap-5">
    <div class="border border-amber-500/30 rounded-2xl bg-amber-500/10 p-5">
      <div class="flex items-start gap-3">
        <div class="i-solar:info-circle-bold-duotone mt-0.5 text-xl text-amber-600 dark:text-amber-300" />
        <div class="flex flex-col gap-1.5">
          <h3 class="text-base text-neutral-800 font-semibold dark:text-neutral-100">
            Image generation is deprecated
          </h3>
          <p class="text-xs text-neutral-600 leading-relaxed dark:text-neutral-300">
            Image generation is disabled. Existing generated images remain available in the image journal. Future image control targets an external SAI integration.
          </p>
          <p class="text-[11px] text-neutral-500 dark:text-neutral-400">
            Existing Artistry card fields are preserved but are no longer editable here.
          </p>
        </div>
      </div>
    </div>
  </div>
</template>
