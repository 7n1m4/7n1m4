import process from 'node:process'

import { initLogger, LoggerFormat, LoggerLevel, useLogger } from '@guiiai/logg'
import { serve } from '@hono/node-server'
import { Hono } from 'hono'
import { createLoggLogger, injeca, lifecycle } from 'injeca'

import { parsedEnv } from './libs/env'
import { initOtel } from './libs/otel'
import { otelMiddleware } from './middlewares/otel'
import { createInternalError } from './utils/error'

type OtelMetrics = ReturnType<typeof initOtel>

interface AppDeps {
  otel: OtelMetrics | null
}

function buildApp({ otel }: AppDeps) {
  const logger = useLogger('app').useGlobalConfig()

  const app = new Hono()

  if (otel) {
    app.use('*', otelMiddleware(otel))
  }

  return app
    .onError((err, c) => {
      if (err instanceof Error) {
        logger.withError(err).error('Unhandled error')
      }

      const internalError = createInternalError()
      return c.json({
        error: internalError.errorCode,
        message: internalError.message,
      }, internalError.statusCode)
    })
    .on('GET', '/health', c => c.json({ status: 'ok' }))
}

async function createApp() {
  initLogger(LoggerLevel.Debug, LoggerFormat.Pretty)
  injeca.setLogger(createLoggLogger(useLogger('injeca').useGlobalConfig()))

  const otel = injeca.provide('otel', {
    dependsOn: { env: parsedEnv, lifecycle },
    build: ({ dependsOn }) => {
      const o = initOtel(dependsOn.env)
      if (!o)
        return null

      dependsOn.lifecycle.appHooks.onStop(() => o.shutdown())
      return o
    },
  })

  await injeca.start()
  const resolved = await injeca.resolve({ otel })
  const app = buildApp({ otel: resolved.otel })

  useLogger('app').useGlobalConfig().withFields({ port: 3000 }).log('Server started')

  return app
}

// eslint-disable-next-line antfu/no-top-level-await
serve(await createApp())

function handleError(error: unknown, type: string) {
  useLogger().withError(error).error(type)
}

async function shutdown(signal: string) {
  useLogger().log(`Received ${signal}, draining and shutting down...`)
  try {
    await injeca.stop()
  }
  catch (err) {
    handleError(err, 'Shutdown error')
  }
  process.exit(0)
}

process.once('SIGTERM', () => void shutdown('SIGTERM'))
process.once('SIGINT', () => void shutdown('SIGINT'))
// Node recommends restarting after an uncaught exception rather than serving
// requests in an unknown state; docker/systemd will restart the process.
process.on('uncaughtException', (error) => {
  handleError(error, 'Uncaught exception')
  process.exit(1)
})
process.on('unhandledRejection', (error) => {
  handleError(error, 'Unhandled rejection')
  process.exit(1)
})
