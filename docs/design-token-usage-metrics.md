# Token Usage Metrics (pointer)

**Status:** proposal, not applied (the key rename to `settings/usage/*` is still open);
the technical content moved into code.

Persisted token keys, the misleading `settings/gemini/*` namespace, the read-migration
snippet, `recordInferenceUsage()` as the single writer (including silent background
turns), the absent lifetime-metrics UI, and the chatbox-toolbar / Control Strip stats
display plan are documented in
[`packages/stage-ui/src/stores/modules/live-session.ts`](../packages/stage-ui/src/stores/modules/live-session.ts)
(module header, "Token usage metrics").

Key inventory: [`docs/data-catalog.md`](./data-catalog.md) §4 (localStorage settings, `settings/gemini/*` rows).

Skills: `airi-prefix-cache-alignment`.