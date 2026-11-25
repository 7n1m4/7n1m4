<script setup lang="ts">

import { computed } from 'vue'
import { useI18n } from 'vue-i18n'

import AssistantBubble from '../components/assistant-bubble.vue'

import { useOnboardingV3Draft } from '../stores/useOnboardingV3Draft'

const props = defineProps<{
  onNext: () => void
  onPrevious: () => void
}>()

const { t } = useI18n()
const draft = useOnboardingV3Draft()

// NOTICE: image generation is deprecated. This step keeps the draft fields intact
// (provider/model/prompt/director) so existing starter-card data is preserved, but
// it no longer exposes provider, model, key, workflow, or autonomous toggles.
const legacyArtistryConfigured = computed(() => Boolean(draft.state.artistryProvider))

function handleNext() {
  props.onNext()
}
</script>

<template>
  <div :class="['w-full h-full flex flex-col justify-between select-none animate-fadeIn']">
    <div :class="['flex-1 min-h-0 min-w-0 overflow-y-auto px-4 sm:px-6 pt-2 pb-5 flex flex-col gap-4']">
      <div :class="['flex flex-col items-center text-center gap-3 flex-shrink-0']">
        <h1 :class="['text-2xl sm:text-3xl font-bold tracking-tight text-neutral-900 dark:text-white']">
          {{ t('onboarding.steps.artistry.label') }}
        </h1>

        <AssistantBubble
          :message="t('onboarding.steps.artistry.deprecatedNotice')"
          step-key="artistry"
          sticker-id="airi-celebrate"
          tone="primary"
        />
      </div>

      <div :class="['w-full max-w-[760px] mx-auto rounded-[20px] border p-6 sm:p-8 flex flex-col gap-4', 'border-amber-500/40 bg-amber-500/10']">
        <div :class="['flex items-start gap-3']">
          <div :class="['h-9 w-9 rounded-xl bg-amber-500/15 text-amber-600 dark:text-amber-300 flex items-center justify-center flex-shrink-0']">
            <div :class="['i-solar:info-circle-bold-duotone h-5 w-5']" />
          </div>
          <div :class="['min-w-0 flex flex-col gap-2']">
            <h2 :class="['text-base font-bold text-neutral-900 dark:text-white leading-tight']">
              {{ t('onboarding.steps.artistry.deprecatedTitle') }}
            </h2>
            <p :class="['text-xs text-neutral-600 dark:text-neutral-300 leading-relaxed']">
              {{ t('onboarding.steps.artistry.deprecatedNotice') }}
            </p>
            <p
              v-if="legacyArtistryConfigured"
              :class="['text-[11px] text-neutral-500 dark:text-neutral-400']"
            >
              {{ t('onboarding.steps.artistry.deprecatedPreserved') }}
            </p>
          </div>
        </div>
      </div>
    </div>

    <div :class="['flex items-center justify-between pt-4 px-4 sm:px-6 border-t border-neutral-200 dark:border-white/5 shrink-0']">
      <button
        type="button"
        :class="['px-4 py-2 rounded-xl bg-neutral-100 dark:bg-white/5 hover:bg-neutral-200 dark:hover:bg-white/10 text-neutral-700 dark:text-neutral-300 text-xs font-medium border border-neutral-200 dark:border-white/10 transition-colors cursor-pointer']"
        @click="props.onPrevious"
      >
        {{ t('onboarding.shell.previous') }}
      </button>

      <button
        type="button"
        :class="['px-5 py-2 rounded-xl bg-primary-600 hover:bg-primary-500 text-white text-xs font-semibold shadow-md shadow-primary-600/30 transition-colors cursor-pointer']"
        @click="handleNext"
      >
        {{ t('onboarding.shell.next') }}
      </button>
    </div>
  </div>
</template>