# AI Producer & Reply Suggestions (source of truth)

The Producer is a secondary LLM loop that runs alongside the conversation and offers
reply suggestions. **The in-code composables are the source of truth**; this doc maps
them.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Suggestion generation (prompt build, cache-aligned context, provider call) | [`composables/use-producer.ts`](use-producer.ts) |
| Auto-suggestion trigger on turn completion | [`composables/use-auto-suggestions.ts`](use-auto-suggestions.ts) |
| Suggestion chips UI | [`ProducerChoiceBubble.vue`](\.\./components/scenarios/chat/ProducerChoiceBubble.vue), [`WhisperComposerBar.vue`](\.\./components/scenarios/chat/WhisperComposerBar.vue) |
| Guidance modal | [`ProducerGuidanceModal.vue`](\.\./components/scenarios/chat/ProducerGuidanceModal.vue) |
| Role taxonomy background | `docs/design-director-producer-roles.md` |

## 1. How it works

While the primary model streams the character's reply, the Producer independently
generates 2–3 things *the user* could say next, written in the user's own voice. It is
asynchronous: it adds no latency to character speech.

- **Cache-aligned mode** (`airi:producer:cache-aligned`, default on) replicates the chat
  context injections (system message, grounding/sensor payload, module contexts) so the
  suggestion call reuses the same prompt prefix as the main call.
- **Context depth** (`airi:producer:context-depth`, default 6) bounds how many recent
  turns the Producer sees.
- **Custom template** — per-card
  `airi:producer:system-prompt-template:{cardId}` overrides
  `DEFAULT_SYSTEM_PROMPT_TEMPLATE`; the template is tokenized on `{count}`,
  `{characterName}`, `{guidance}`, and `{lengthRule}`.

## 2. Using suggestions in chat

Above the composer, suggestion chips appear after a turn completes:

- **Playful / banter**, **inquisitive**, and **narrative action** flavours.
- **Click** sends the suggestion immediately.
- **Shift-click** (or the chip edit icon) loads it into the composer for editing.
- The **reroll** control in the composer toolbar asks the Producer for a fresh set.
- **Auto-suggestions** (`airi:producer:auto-suggestions-enabled`) chains turns without
  manual input, triggered by `useAutoSuggestions` on turn completion.

## 3. Configuration

The Producer reuses the active consciousness provider/model by default. To keep suggestion
cost off the main reasoning model, point it at a fast, cheap model (or a local one) from
the module settings. Creativity is temperature-driven; the prompt template is the lever
for tone and length (`shortReplies` toggles the sub-two-sentence rule).

The Producer is a *suggestion* surface only — it never speaks as the character and never
writes to the concept stack. Scene direction is the Director's (deprecated) job, not the
Producer's.
