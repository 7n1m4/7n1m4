<script setup lang="ts">
const emit = defineEmits<{
  (e: 'sparkleClick', fieldId: string): void
  (e: 'extractTagsClick', fieldId: string): void
}>()

defineProps<{
  artistryProviderOptions: { value: string, label: string }[]
  defaultArtistryProviderPlaceholder: string
}>()

defineModel<string>('selectedArtistryProvider', { required: true })
defineModel<string>('selectedArtistryModel', { required: true })
defineModel<string>('selectedArtistryPromptPrefix', { required: true })
defineModel<string>('selectedArtistryWidgetInstruction', { required: true })
defineModel<boolean>('selectedArtistryAutonomousEnabled', { required: true })
defineModel<number>('selectedArtistryAutonomousThreshold', { required: true })
defineModel<boolean>('selectedArtistryAutonomousMonitorEnabled', { required: false, default: true })
defineModel<boolean>('selectedArtistryAutonomousMonitorDiscordEnabled', { required: false, default: false })
defineModel<'user' | 'assistant'>('selectedArtistryAutonomousTarget', { required: true })
defineModel<number>('selectedArtistryAutonomousHistoryDepth', { required: false, default: 3 })
defineModel<'inherit' | 'custom'>('selectedArtistryAutonomousModelMode', { required: false, default: 'inherit' })
defineModel<string>('selectedArtistryAutonomousProvider', { required: false, default: '' })
defineModel<string>('selectedArtistryAutonomousModel', { required: false, default: '' })
defineModel<'bg' | 'widget' | 'inline' | 'bg_widget'>('selectedArtistrySpawnMode', { required: true })
defineModel<string>('selectedArtistryConfigStr', { required: true })
</script>

<template>
  <div class="tab-content ml-auto mr-auto w-95% flex flex-col gap-5">
    <div class="rounded-2xl border border-amber-500/30 bg-amber-500/10 p-5">
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