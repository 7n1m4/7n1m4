import type { WidgetsWindowManager } from '../../../windows/widgets'
import type { ArtistryProvider, ArtistryRequest } from './providers/base'

import { useLogg } from '@guiiai/logg'

import { ComfyUIProvider } from './providers/comfyui'
import { NanoBananaProvider } from './providers/nanobanana'
import { PollinationsProvider } from './providers/pollinations'
import { ReplicateProvider } from './providers/replicate'

const log = useLogg('artistry-bridge').useGlobalConfig()

function robustParse(input: any): any {
  if (typeof input === 'object' && input !== null)
    return input
  if (typeof input === 'string') {
    try {
      return JSON.parse(input)
    }
    catch {
      return {}
    }
  }
  return {}
}

const lastTriggerMap = new Map<string, string>()
const activeRunMap = new Map<string, string>()

function createRunId(widgetId: string) {
  return `${widgetId}:${Date.now()}:${Math.random().toString(36).slice(2, 8)}`
}

// Maintaining a registry of providers
export const artistryProviders = new Map<string, ArtistryProvider>()
artistryProviders.set('comfyui', new ComfyUIProvider())
artistryProviders.set('replicate', new ReplicateProvider())
artistryProviders.set('nanobanana', new NanoBananaProvider())
artistryProviders.set('pollinations', new PollinationsProvider())

export async function generateHeadless(params: {
  prompt: string
  model?: string
  provider?: string
  options?: Record<string, any>
  globals?: any
}): Promise<{ imageUrl?: string, base64?: string, error?: string }> {
  // Image generation is deprecated and disabled. This stub keeps the IPC contract
  // and provider registry intact for backcompat, but never calls any provider.
  // A future image-control integration will target an external SAI here.
  log.warn(`[Headless] Generation request rejected (deprecated): provider=${params.provider || 'default'}`)
  return { error: 'Image generation is deprecated and disabled. Existing generated images remain available in the image journal; future image control will target an external SAI integration.' }
}

let cachedArtistryConfig: any = null

async function handleArtistryTrigger(params: {
  id: string
  componentName?: string
  componentProps?: any
  widgetsManager: WidgetsWindowManager
}) {
  if (params.componentName !== 'comfy' && params.componentName !== 'artistry')
    return

  log.log(`🔍 Intercepted widget update [${params.id}] for component: ${params.componentName}`)

  const props = robustParse(params.componentProps)
  const status = props.status
  const prompt = props.payload?.prompt || props.prompt

  const config = props._artistryConfig || {}
  if (Object.keys(config).length > 0) {
    cachedArtistryConfig = config
  }
  const configToUse = Object.keys(config).length > 0 ? config : (cachedArtistryConfig || {})

  const providerId = configToUse.provider || configToUse.Globals?.artistryProvider || 'comfyui'

  if (providerId === 'none')
    return

  // Extract options and remix ID fallback
  const options = configToUse.options || {}
  const remixId = props.payload?.remixId || props.remixId || options.remixId || (props.status === 'generating' && !prompt ? '48250602' : undefined)

  const mode = props.mode || (remixId ? 'remix' : 'generate')
  const triggerFingerprint = `${mode}:${remixId || ''}:${prompt || ''}`

  if (status === 'generating' && lastTriggerMap.get(params.id) !== triggerFingerprint && (prompt || remixId)) {
    log.log(`🎯 TRIGGER DETECTED [${params.id}]: ${triggerFingerprint} | Mode: ${mode} | Provider: ${providerId}`)
    lastTriggerMap.set(params.id, triggerFingerprint)
    const runId = createRunId(params.id)
    activeRunMap.set(params.id, runId)

    const provider = artistryProviders.get(providerId)
    if (!provider) {
      log.error(`🔴 Provider '${providerId}' not found.`)
      params.widgetsManager.updateWidget({
        id: params.id,
        componentProps: { status: 'error', actionLabel: `Provider '${providerId}' not available` },
      })
      return
    }

    const globalsToUse = configToUse.Globals

    // Initialize the provider with global config
    if (provider.initialize && globalsToUse) {
      await provider.initialize(globalsToUse)
    }

    try {
      // Build the abstract request
      const request: ArtistryRequest = {
        prompt: configToUse.promptPrefix ? `${configToUse.promptPrefix} ${prompt}` : prompt,
        model: configToUse.model,
        extra: {
          ...props.payload,
          ...options,
          internalJobId: runId, // Track each generation independently, even on the same widget.
          remixId,
        },
      }

      const updateIfActive = (statusUpdate: Record<string, any>) => {
        // NOTICE: the same widget can kick off another generation before the previous one fully
        // settles. Only the most recent run is allowed to keep updating the widget state.
        if (activeRunMap.get(params.id) !== runId)
          return

        params.widgetsManager.updateWidget({
          id: params.id,
          componentProps: statusUpdate,
        })
      }

      let isDone = false

      if ('setJobCallback' in provider) {
        const callbackPromise = new Promise<void>((resolve) => {
          ;(provider as any).setJobCallback(runId, (statusUpdate: any) => {
            updateIfActive(statusUpdate)
            if (statusUpdate.status === 'succeeded' || statusUpdate.status === 'failed') {
              isDone = true
              resolve()
            }
          })
        })

        await provider.generate(request)
        const timeoutPromise = new Promise<void>((_, reject) => setTimeout(() => reject(new Error('Generation timed out')), 1000 * 60 * 10))
        await Promise.race([callbackPromise, timeoutPromise])
      }
      else {
        const job = await provider.generate(request)

        // Polling loop for providers that don't do callbacks (like Replicate)
        const pollStart = Date.now()
        const POLL_TIMEOUT = 1000 * 60 * 10 // 10 minutes
        while (!isDone) {
          if (Date.now() - pollStart > POLL_TIMEOUT) {
            updateIfActive({ status: 'error', actionLabel: 'Generation timed out' })
            break
          }
          const status = await provider.getStatus(job.jobId)
          if (status.status === 'succeeded' || status.status === 'failed') {
            isDone = true
          }

          updateIfActive(status)

          if (!isDone) {
            await new Promise(resolve => setTimeout(resolve, 2000))
          }
        }
      }

      log.log(`🎉 Job complete for ${params.id}. Sending final status: done`)
      updateIfActive({ status: 'done', progress: 100, actionLabel: undefined })
    }
    catch (error: any) {
      log.error(`🔴 Generation failed: ${error.message}`)
      if (activeRunMap.get(params.id) === runId) {
        params.widgetsManager.updateWidget({
          id: params.id,
          componentProps: { status: 'error', actionLabel: error.message },
        })
      }
    }
  }
}

export function setupArtistryBridge(params: { widgetsManager: WidgetsWindowManager }) {
  log.log('🚀 Initializing Artistry bridge (Spawn + Update Interceptor)...')

  const originalUpdateWidget = params.widgetsManager.updateWidget
  params.widgetsManager.updateWidget = async (payload) => {
    const snapshot = params.widgetsManager.getWidgetSnapshot(payload.id)
    await originalUpdateWidget.call(params.widgetsManager, payload)
    await handleArtistryTrigger({
      id: payload.id,
      componentName: snapshot?.componentName,
      componentProps: payload.componentProps,
      widgetsManager: params.widgetsManager,
    })
  }

  const originalPushWidget = params.widgetsManager.pushWidget
  params.widgetsManager.pushWidget = async (payload) => {
    if (payload.componentName === 'comfy' || payload.componentName === 'artistry') {
      log.log(`🖼️  Enabling 'Living Wall' mode for ${payload.id}. Forcing infinite TTL. (Component: ${payload.componentName})`)
      payload.ttlMs = 0
    }

    const resultId = await originalPushWidget.call(params.widgetsManager, payload)

    await handleArtistryTrigger({
      id: resultId,
      componentName: payload.componentName,
      componentProps: payload.componentProps,
      widgetsManager: params.widgetsManager,
    })

    return resultId
  }
}
