import { createBadRequestError } from './error'

/**
 * Parse a JSON request body. A malformed body is a client error (400); letting
 * the raw SyntaxError reach the global handler would report a 500 instead.
 */
export async function readJsonBody(req: { json: () => Promise<unknown> }): Promise<any> {
  try {
    return await req.json()
  }
  catch {
    throw createBadRequestError('Invalid JSON body', 'INVALID_JSON')
  }
}
