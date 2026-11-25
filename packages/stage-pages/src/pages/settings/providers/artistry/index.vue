<script setup lang="ts">
import { onMounted } from 'vue'
import { useRouter } from 'vue-router'

const router = useRouter()

onMounted(() => {
  router.replace('/settings/providers#artistry')
})
</script>

<template>
  <div class="flex items-center justify-center p-8 text-xs text-neutral-400 font-mono">
    Artistry image generation is deprecated. Existing generated images remain available in the image journal; future image control targets an external SAI integration.
  </div>
</template>