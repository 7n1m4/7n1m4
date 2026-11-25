import type { Card } from '../define'
import type { CharacterCardV3 } from './types/character_card_v3'

/**
 * Serializes an AIRI `Card` into a Character Card Spec V3 object (`{ spec: 'chara_card_v3', spec_version: '3.0', data }`).
 *
 * `greetings[0]` → `data.first_mes`, `greetings.slice(1)` → `alternate_greetings`;
 * `messageExample` is formatted to the `<START>`-delimited `mes_example` string;
 * `extensions` carries `depth_prompt`/`fav`/`talkativeness` defaults merged with the card's
 * own extensions (including `extensions.airi`).
 *
 * This is the only correct way to build a CCv3 `card.json` — do not hand-roll the envelope.
 *
 * @param data The card data to export
 * @returns A CharacterCardV3 compatible object
 */
export function exportToJSON(data: Card): CharacterCardV3 {
  return {
    spec: 'chara_card_v3',
    spec_version: '3.0',
    data: createCardData(data),
  }
}

/**
 * Creates the data portion of a CharacterCardV3 object
 * @param data Source card data
 * @returns The formatted card data
 */
function createCardData(data: Card): CharacterCardV3['data'] {
  return {
    name: data.name,
    nickname: data.nickname,
    description: data.description ?? '',
    personality: data.personality ?? '',
    scenario: data.scenario ?? '',
    first_mes: data.greetings?.[0] ?? '',
    alternate_greetings: data.greetings?.slice(1) ?? [],
    group_only_greetings: data.greetingsGroupOnly ?? [],
    character_version: data.version,
    creator: data.creator ?? '',
    creator_notes: data.notes ?? '',
    creator_notes_multilingual: data.notesMultilingual,
    system_prompt: data.systemPrompt ?? '',
    post_history_instructions: data.postHistoryInstructions ?? '',
    mes_example: formatMessageExample(data.messageExample),
    tags: data.tags ?? [],
    extensions: createExtensions(data),
  }
}

/**
 * Formats message examples into the required string format
 * @param messageExample The message example array
 * @returns Formatted message example string
 */
function formatMessageExample(messageExample: string[][] | undefined): string {
  if (!messageExample)
    return ''

  return messageExample
    .map(arr => `<START>\n${arr.join('\n')}`)
    .join('\n')
}

/**
 * Creates the extensions object with default values and user extensions
 * @param data Source card data
 * @returns Extensions object
 */
function createExtensions(data: Card): Record<string, any> {
  return {
    depth_prompt: {
      depth: 4,
      prompt: '',
      role: 'system',
    },
    fav: false,
    talkativeness: 0.5,
    ...data.extensions,
  }
}
