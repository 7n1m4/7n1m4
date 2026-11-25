# Image Journal Storage

> Architecture pointer. The **in-code types are the source of truth** for the
> journal record shape; this doc only maps the parts. The `ImageJournalEntry`
> fields live verbatim in the JSDoc of the type file.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Entry types (`ImageJournalEntry`, `CreateImageJournalEntryInput`) | [`packages/stage-ui/src/types/image-journal.ts`](packages/stage-ui/src/types/image-journal.ts) |
| Live gallery / persistence (`type: 'journal'` entries, per-character scoping) | [`packages/stage-ui/src/stores/background.ts`](packages/stage-ui/src/stores/background.ts) |
| LLM tool (`image_journal` `create` / `apply` / `set_as_background`) | [`apps/stage-tamagotchi/src/renderer/stores/tools/builtin/image-journal.ts`](apps/stage-tamagotchi/src/renderer/stores/tools/builtin/image-journal.ts) |
| Card flag (`extensions.airi.imageJournal.selfie`) | [`packages/stage-ui/src/types/card.schema.ts`](packages/stage-ui/src/types/card.schema.ts) |

## Model

The image journal is a durable, append-only, per-character (`activeCardId`) art
history; the on-screen widget is a **viewport** into it, not the source of truth.
Entries are stored as background-store `journal` entries (blob-backed);
`image_journal.create` appends a new entry and `image_journal.apply` /
`set_as_background` promotes one to the stage background (surfacing the active
background back into the proactivity/sensor layer as ambient self-context).

> Note: in-code `image_journal.create` image generation is currently gated off
> (deprecated); existing journal images remain and `apply` still switches to
> them. See `stores/modules/artistry.ts`.

## Related

- Card schema (`extensions.airi.imageJournal`): [`design-airi-card.md`](./design-airi-card.md)

## Relevant Skills

- [[airi-data-persistence]]
- [[airi-memory-image-journal]]
- [[airi-scenes-backgrounds]]