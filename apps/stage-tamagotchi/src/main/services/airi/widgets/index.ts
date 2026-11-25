import type { createContext } from '@moeru/eventa/adapters/electron/main'
import type { BrowserWindow, IpcMainEvent } from 'electron'

import type { WidgetsWindowManager } from '../../../windows/widgets'

import { defineInvokeHandlers } from '@moeru/eventa'
import { artistryComfyHealthCheck, artistryGenerateHeadless } from '@proj-anima/stage-shared'

import { widgetsAdd, widgetsClear, widgetsFetch, widgetsHideWindow, widgetsOpenWindow, widgetsPrepareWindow, widgetsRemove, widgetsResizeWindow, widgetsUpdate } from '../../../../shared/eventa'
import { ipcMain } from '../../../eventa-bus'


interface InvokeOptions {
  raw?: { ipcMainEvent?: IpcMainEvent }
}

function isFromWindow(options: InvokeOptions | undefined, window: BrowserWindow) {
  const sender = options?.raw?.ipcMainEvent?.sender
  if (!sender)
    return false

  if (sender.id === window.webContents.id)
    return true

  if (window.webContents.devToolsWebContents && sender.id === window.webContents.devToolsWebContents.id)
    return true

  return false
}

export function createWidgetsService(params: { context: ReturnType<typeof createContext>['context'], widgetsManager: WidgetsWindowManager, window: BrowserWindow }) {
  // Support direct ipcRenderer.invoke from DevTools console or user scripts
  try {
    ipcMain.removeHandler('eventa:invoke:electron:windows:widgets:add')
  }
  catch {}
  ipcMain.handle('eventa:invoke:electron:windows:widgets:add', async (_event, args) => {
    const payload = Array.isArray(args) ? args[0] : args
    return payload ? params.widgetsManager!.pushWidget(payload) : undefined
  })

  try {
    ipcMain.removeHandler('eventa:invoke:electron:windows:widgets:clear')
  }
  catch {}
  ipcMain.handle('eventa:invoke:electron:windows:widgets:clear', async () => {
    return params.widgetsManager!.clearWidgets()
  })

  defineInvokeHandlers(params.context, {
    widgetsPrepareWindow,
    widgetsOpenWindow,
    widgetsAdd,
    widgetsUpdate,
    widgetsRemove,
    widgetsClear,
    widgetsFetch,
    widgetsHideWindow,
    widgetsResizeWindow,
    artistryGenerateHeadless,
    artistryComfyHealthCheck,
  }, {
    widgetsPrepareWindow: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return params.widgetsManager!.prepareWidgetWindow(payload ?? undefined)
    },
    widgetsOpenWindow: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return params.widgetsManager!.openWindow(payload ?? undefined)
    },
    widgetsAdd: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return payload ? params.widgetsManager!.pushWidget(payload) : undefined
    },
    widgetsUpdate: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return payload ? params.widgetsManager!.updateWidget(payload) : undefined
    },
    widgetsRemove: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return payload?.id ? params.widgetsManager!.removeWidget(payload.id) : undefined
    },
    widgetsClear: async (_payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return params.widgetsManager!.clearWidgets()
    },
    widgetsFetch: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return payload?.id ? params.widgetsManager!.getWidgetSnapshot(payload.id) : undefined
    },
    widgetsHideWindow: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return params.widgetsManager!.hideWindow(payload ?? undefined)
    },
    widgetsResizeWindow: async (payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return undefined
      return params.widgetsManager!.resizeWidgetWindow({
        ...payload,
        window: params.window,
      })
    },
    artistryGenerateHeadless: async (_payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        return { error: 'Unauthorized window' }
      // Image generation is deprecated/disabled; never reach the provider bridge.
      return { error: 'Image generation is deprecated and disabled. Existing generated images remain available in the image journal; future image control will target an external SAI integration.' }
    },
    artistryComfyHealthCheck: async (_payload, options) => {
      if (!isFromWindow(options as InvokeOptions, params.window))
        throw new Error('Unauthorized window')
      // Health check performs no external call while image generation is deprecated.
      throw new Error('Image generation is deprecated and disabled; ComfyUI health check is unavailable. Future image control will target an external SAI integration.')
    },
  })
}
