# `<|ACTOR:…|>` token pipeline — source of truth

How an actor swap token travels from the LLM stream to a rendered model/voice change, and
which invariants keep voice, audio and visuals in sync. Migrated from
`docs/design-journal-actor-token-sync.md` (now an architecture pointer). The independent
line-by-line validation of the original diagnosis is
`docs/archive/design-actor-token-sync-postmortem.md`.

## Token flow

1. **Capture (chat store).** `stores/chat.ts` handles `onSpecial` during streaming:
   `<|STICKER:…|>` spawns a sticker, everything else goes to `captureActorToken()`
   (`utils/chat-actor-slices.ts`) and `appendActorAwareTextSlice()` records the actor on
   the surrounding text slices. The raw token text is preserved verbatim in
   `rawContent` so history keeps the orchestration syntax.
2. **Chunking.** `packages/pipelines-audio/src/processors/tts-chunker.ts` splits on
   `TTS_SPECIAL_TOKEN` (`\u2063`, invisible separator): any pending text is flushed as its own
   `literal` chunk **before** an empty `special` chunk is emitted
   (`chunkTtsInput`, the `if (special)` branch). A segment therefore never carries both
   `text` and `special`.
3. **Pipeline.** `packages/pipelines-audio/src/speech-pipeline.ts` still splits a mixed
   segment defensively (warn + two virtual segments). Empty-text specials call `tts()`
   for side effects, then `playback.schedule({ …, audio: null, actorId })`.
4. **Generation-time resolution + prefetch.** `ControlStripHost.vue`
   `generateSpeechBuffered()` sees `request.special`, resolves the actor via
   `artistryAutonomousStore.resolveSpeechConfigForActor(actorId)` (pure
   `resolveConceptStack` + `foldConceptStack`, no store writes) and warms the display
   model/texture cache (`displayModelsStore.getDisplayModel`, `getDisplayModelTextures`
   for PMX/PMD). Text segments resolved with `request.actorId` synthesize with that
   actor's provider/model/voice — never the global `speechStore`.
5. **Playback barrier.** `playFunction()` handles `item.special`: sets
   `playbackActorId`, fires `void activateConcept(actorId)` (visual stack + model
   handoff) and mirrors the resolved provider/model/voice into `speechStore` **at
   speaking start only**. `createPlaybackManager({ maxVoices: 1, maxVoicesPerOwner: 1 })`
   serializes items, so the null-audio special completes before the next audio segment
   starts.
6. **Model handoff.** `airi-card.ts` `syncCardState()` is single-flight via
   `syncCardStateSequence` (a monotonically increasing token; stale async continuations bail
   out). The physical model only swaps when `displayModelId` actually changed
   (`modelChanged`); `force` no longer bypasses the speech gate. The gate
   (`isModelSyncPrevented`, set for the whole speech turn) is bypassed only for a
   genuinely different model or an `actorInitiated: true` handoff. The `active_concepts`
   watcher calls `syncCardState(activeCard, true)` for visuals only; `activateConcept()`
   keeps the gate true across `updateCard` and then runs one explicit un-gated
   `syncCardState` on the next microtask (`docs/design-fix-actor-stage-desync.md`, v4 Leg 2b).

## Invariants

- **One writer per clock.** Generation resolves per-segment config; playback is the only
  writer of the global `speechStore` voice mirror; the old `preloadConceptVoice()` and the
  `active_concepts` watcher speech writes are gone — the watcher only refreshes visuals.
- **No mixed segments.** Text is synthesized, specials are queued; nothing is dropped by
  `if (!audio) continue`.
- **Serialized audio.** `maxVoices: 1` + per-actor resolution means no overlapping model
  loads and no audio before the model handoff.
- **Actor readiness signal.** The actor window (`apps/stage-tamagotchi/src/renderer/pages/actor.vue`)
  and `RendererStage.vue` post `ready` on the `airi-stage-model-ready` BroadcastChannel
  once the stage reports `mounted`; `App.vue` `waitForStageModelReady()` consumes it with a
  15 s timeout fallback. A playback-side await on that promise is the remaining optional
  hardening (see open items).

## Open items / known gaps

- `playFunction()` does not yet `await` `activateConcept()` or the model-ready promise;
  the barrier is the serialized queue plus generation-time prefetch. Adding an await with
  a 5–8 s timeout is safe because the queue blocks naturally.
- The dead `speechPipeline.on('onSpecial', …)` listener was removed; the `'actor'`
  handler in `specialTokenQueue` runs at playback time only (`playbackManager.onEnd` →
  `playSpecialToken`).

## Reference map

| Concern | File |
| :--- | :--- |
| Token capture, actor-aware slices | `packages/stage-ui/src/stores/chat.ts`, `packages/stage-ui/src/utils/chat-actor-slices.ts` |
| Special chunk isolation | `packages/pipelines-audio/src/processors/tts-chunker.ts` (`chunkTtsInput`) |
| Mixed-segment split, null-audio scheduling | `packages/pipelines-audio/src/speech-pipeline.ts` |
| Playback item shape (`actorId`, `audio: null`) | `packages/pipelines-audio/src/types.ts` |
| Serialized queue | `packages/pipelines-audio/src/managers/playback-manager.ts` |
| TTS resolution, prefetch, playback effects | `packages/stage-ui/src/components/scenes/ControlStripHost.vue` |
| Concept activation / scoped speech resolution | `packages/stage-ui/src/stores/modules/artistry-autonomous.ts` |
| Single-flight model sync, speech gate | `packages/stage-ui/src/stores/modules/airi-card.ts` |
| Actor window readiness | `apps/stage-tamagotchi/src/renderer/pages/actor.vue`, `packages/stage-ui/src/components/scenes/RendererStage.vue` |

Skill: `airi-acting-cue-act-tokens`.
