import type { ProviderCatalogProvider } from '../database/repos/providers.repo'

import { nanoid } from 'nanoid'
import { defineStore } from 'pinia'
import { computed, ref } from 'vue'

import { deleteDaemonProvider, hasDaemonCardMetadata, listDaemonProviders, saveDaemonProvider } from '../composables/daemon-card-metadata'
import { providersRepo } from '../database/repos/providers.repo'
import { getDefinedProvider, listProviders } from '../libs/providers/providers'

// Daemon ProviderKind is one of five canonical tags; local definition IDs are
// much finer grained. Everything HTTP-compatible falls back to open-ai-compatible.
function toDaemonProviderKind(definitionId: string): string {
  if (definitionId === 'anthropic')
    return 'anthropic'
  if (definitionId === 'google-generative-ai')
    return 'google-gemini'
  if (definitionId === 'amazon-bedrock')
    return 'aws-bedrock'
  if (definitionId === 'ollama' || definitionId === 'lm-studio')
    return 'local-server'
  return 'open-ai-compatible'
}

export const useProviderCatalogStore = defineStore('provider-catalog', () => {
  const defs = computed(() => listProviders())
  const configs = ref<Record<string, ProviderCatalogProvider>>({})

  async function fetchList() {
    const cached = await providersRepo.getAll()
    configs.value = cached

    if (hasDaemonCardMetadata()) {
      try {
        const { providers: infos } = await listDaemonProviders()
        const newConfigs = { ...configs.value }
        for (const info of infos) {
          const existing = newConfigs[info.id]
          newConfigs[info.id] = {
            id: info.id,
            definitionId: existing?.definitionId ?? info.id,
            name: existing?.name ?? info.id,
            config: existing?.config ?? {},
            validated: existing?.validated ?? false,
            validationBypassed: existing?.validationBypassed ?? false,
          }
          if (info.model) {
            newConfigs[info.id].config = { ...newConfigs[info.id].config, model: info.model }
          }
          if (info.baseUrl) {
            newConfigs[info.id].config = { ...newConfigs[info.id].config, baseUrl: info.baseUrl }
          }
        }
        configs.value = newConfigs
        await providersRepo.saveAll(newConfigs)
      }
      catch (err) {
        console.error('Failed to list daemon providers', err)
      }
    }
  }

  async function addProvider(definitionId: string, initialConfig: Record<string, any> = {}) {
    const definition = getDefinedProvider(definitionId)
    if (!definition) {
      throw new Error(`Provider definition with id "${definitionId}" not found.`)
    }

    const id = nanoid()
    const provider: ProviderCatalogProvider = {
      id,
      definitionId,
      name: definition.name,
      config: initialConfig,
      validated: false,
      validationBypassed: false,
    }

    configs.value[id] = provider
    await providersRepo.upsert(provider)

    if (hasDaemonCardMetadata()) {
      try {
        await saveDaemonProvider({
          id,
          kind: toDaemonProviderKind(definitionId),
          enabled: true,
          model: String(initialConfig.model ?? ''),
          baseUrl: String(initialConfig.baseUrl ?? ''),
        })
      }
      catch (err) {
        console.error('Failed to save daemon provider', err)
      }
    }

    return provider
  }

  async function removeProvider(providerId: string) {
    if (!configs.value[providerId]) {
      return
    }

    delete configs.value[providerId]
    await providersRepo.remove(providerId)

    if (hasDaemonCardMetadata()) {
      try {
        await deleteDaemonProvider(providerId)
      }
      catch (err) {
        console.error('Failed to delete daemon provider', err)
      }
    }
  }

  async function commitProviderConfig(providerId: string, newConfig: Record<string, any>, options: { validated: boolean, validationBypassed: boolean }) {
    const provider = configs.value[providerId]
    if (!provider) {
      return
    }

    provider.config = { ...newConfig }
    provider.validated = options.validated
    provider.validationBypassed = options.validationBypassed
    await providersRepo.upsert(provider)

    if (hasDaemonCardMetadata()) {
      try {
        const payload: Record<string, any> = {
          id: providerId,
          kind: toDaemonProviderKind(provider.definitionId),
          enabled: true,
          model: String(newConfig.model ?? ''),
          baseUrl: String(newConfig.baseUrl ?? ''),
        }
        if (typeof newConfig.apiKey === 'string') {
          payload.apiKey = newConfig.apiKey
          if (options.validated) {
            payload.rotateSecrets = true
          }
        }
        await saveDaemonProvider(payload)
      }
      catch (err) {
        console.error('Failed to save daemon provider', err)
      }
    }

    return provider
  }

  return {
    configs,
    defs,
    getDefinedProvider,

    fetchList,
    addProvider,
    removeProvider,
    commitProviderConfig,
  }
})
