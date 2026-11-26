# Decision: session-scoped cues and caption bindings

Status: ratified by implementation (commits `5500cf54`, `758e1308`, `046b5cb1`; beads `airi-9exf`, `airi-j1o5`, `airi-eefo`, `airi-lg1c`, all closed 2026-11-26).

## Decision

`emotion.tag` and `token.delta` stay daemon-published. Session filtering is client-local: the daemon gains no per-client cue queue, and a session switch never tears down the event lane.

1. **The wire carries an optional session id.** `EmotionTagData.session_id` is `Option<String>` with `skip_serializing_if` (`crates/anima-channel/src/wire.rs:1026-1030`, generated TS). Cues published outside a chat turn omit it, and older daemons omit it entirely.
2. **Foreign-session `token.delta` frames are dropped.** Chat checks `session_id` against its active session (`apps/flutter/lib/features/chat/chat_screen.dart:183-192`). `StageRenderStateBinding` mirrors that rule for captions: an explicit binding wins, a session-less frame is still accepted for older daemons, and only a disagreeing id is dropped (`apps/flutter/lib/features/stage/stage_overlay_state.dart:600-617`). The shell passes the active session id into `StageScreen`; `setBoundSessionId` clears the learned id and stale captions and retargets the filter in place (`stage_overlay_state.dart:562-576`, `airi-j1o5`). A terminal/cancelled/error frame releases a self-learned binding so a foreign stream cannot hold the caption lane (`stage_overlay_state.dart:624-626`, `airi-lg1c`).
3. **Unsubscribe is queued before any await.** `dispose()` clears the local event callback and issues `event.unsubscribe` before its first await (`stage_overlay_state.dart:632-638`). A replacement binding constructed while disposal is suspended cannot then be undone by a late unsubscribe on the shared daemon topic (`airi-eefo`; the negative-control test at `apps/flutter/test/stage_caption_overlay_test.dart:849-881` reverts the fix to zero active subscriptions).

No framing gap becomes a fabricated caption or presence value. The parity row and source anchors are in `docs/feature-parity-checklist.md` (`emotion.tag` cues, stage caption session binding).
