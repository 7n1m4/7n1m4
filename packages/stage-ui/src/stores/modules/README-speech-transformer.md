# Universal Speech Transformer (UST) — source of truth

The Universal Speech Transformer is the text-cleanup middleware that runs before any TTS
dispatch. It removes roleplay markup and visual-only symbols so cloud providers (OpenAI, AWS,
Azure) that lack character-aware processing don't vocalize asterisks, emoji or kaomoji. The
implementation is `applyUSTTransformations` in `stores/modules/speech.ts`; this file is the
behavioral spec.

Migrated from `docs/blueprint-tts-universal-speech-transformer.md` (now an architecture
pointer).

## Core constraints

- **Universality** — only transforms valid for every TTS engine.
- **No vendor-locked syntax** — no `<break/>`-style mappings.
- **Separation of concerns** — ACT tokens and Thought/Think tags are handled downstream and
  are strictly excluded here.
- **Display vs. spoken** — only the string sent to TTS changes; chat display text is untouched.

## UI placement

Not a standalone page: a checkbox-list panel in the **left column of the existing Speech
Module** (`packages/stage-pages/src/pages/settings/modules/speech.vue`, "Universal
Transformers" section, `FieldCheckbox` toggles + `FieldInput` for the tilde replacement).

## Rule catalog

### A. Narrative handling
- **Mute asterisks** — drop `*smiles*` / `**asides**` entirely (voice-only experience).
- **Flatten asterisks** — remove the `*` markers, speak the interior.
- **Groups/brackets** — same mute/flatten choice for `(parentheses)`, `[brackets]`,
  `<angle brackets>` and a user-defined custom bracket pair. The `token` action rewrites
  the bracketed payload to `<|content|>` behind `__UST_TOKEN_<n>__` placeholders and
  restores it after bracket processing (before tilde substitution), so orchestration tags
  like `<|ACTOR:…|>` survive muting.

### B. Visual symbols
- **Strip emojis** — remove Unicode pictographs, keep alphanumerics.
- **Strip kaomojis** — remove Japanese-style emoticons (`(≧▽≦)`, `(¬_¬)`) via the
  "Healer" pattern matchers (the `healMozibake` helper in `packages/stage-shared/src/text.ts`).
- **Tilde replacement** — toggle + replacement string (`~` → ` nyan`); empty ⇒ remove.

### C. Sanitization & optimization
- **Alphanumeric guard** — skip the TTS request when nothing speakable survives
  (`...`, `!!!`); prevents artifacts and wasted API cost.
- **URL purge** — strip/replace `https://…` so the engine doesn't spell URLs
  (`verbalizeWebAddressesAndLinks`).
- **Markdown cleaner** — strip code blocks, bold/italics, table separators, image embeds,
  raw HTML; normalize headers/quotes/lists into line pauses; links → label text.

## Pipeline (order matters)

1. Strip markdown image embeds `![caption](url)`.
2. Code blocks — mute (default) or pass through.
3. Strip raw HTML tags (default on).
4. Markdown links — `extract_text` (default) or `mute`.
5. Normalize block boundaries (headers, quotes, lists) into line pauses.
6. Chemical notation `\ce{…}` — mute / verbalize / pass through.
7. Currency verbalization (`$19.99` → "nineteen dollars and ninety-nine cents").
8. Web addresses / file paths / Obsidian wiki-links verbalization.
9. Math — mute / verbalize (inline `$…$`, `\(…\)`, display `$$…$$`, `\[…\]`, bare LaTeX) /
   pass through. Bare numerals like `$19.99` are never treated as math.
10. Protect arithmetic operators (`2 * 3`, `2**10`, `x**2`) with placeholders so bracket
    muting can't eat them; restored after bracket processing.
11. Bracket actions per type (`mute` / `flatten` / `token` → `<|content|>` / `passThrough`),
    with legacy `mode` migration for old profiles and a legacy custom-strip-char fallback.
12. Strip emojis (with ZWJ cleanup), then strip symbols/kaomoji (extreme clean).
13. Restore protected math + token placeholders.
14. Tilde substitution.
15. Custom user replacement rules (regex or literal, optional whole-word/case-sensitivity).
16. Whitespace normalization: collapse runs, trim, drop empty lines, trim result.

## State & wiring

- `stores/modules/speech.ts` — `applyUSTTransformations(text, ust, language?)` is the pure
  transformer; `transformTextForSpeech(text, providerId, voiceProfileId?)` resolves the active
  `VoiceProfile.ust` (per-profile, `settings/speech/voice-profiles`, via
  `useLocalStorageManualReset`) and picks the formula language
  (`ust.formulaLanguage` → voice language → `settings/speech/language`). Providers
  `chatterbox` and `airi-audio-server` bypass the transformer.
- `speech()` action — the "mythical hook": its first statements resolve
  `{ transformedInput, isSpeakable }` and bail out (return an empty `ArrayBuffer`) when
  nothing speakable survives; every downstream `generateSpeech` consumes
  `transformedInput`, so no other call site knows about transformers.

```typescript
function resolveSpeechInput(input: string, transformerSettings: TransformerSettings) {
  const transformedInput = transformTextForSpeech(input, transformerSettings)
  const isSpeakable = !transformerSettings.alphanumericGuard || hasAlphaChars(transformedInput)
  return { transformedInput, isSpeakable }
}
```
