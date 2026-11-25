# `<|ACTOR:|>` Token Sync — diagnostics journal (pointer)

**Status:** historical root-cause journal; the verified fixes shipped, the technical content moved into code.

The `<|ACTOR:actor_id|>` swap-token pipeline — global `speechStore` clock skew, the
generation vs. playback vs. watcher writers, the missing playback barrier, the
chunker text-swallowing bug, single-flight model sync, and the current scoped
resolution/prefetch/handoff implementation — is documented in
[`packages/stage-ui/src/components/scenes/README-actor-token-pipeline.md`](../packages/stage-ui/src/components/scenes/README-actor-token-pipeline.md).

Independent line-by-line validation of the original diagnosis:
[`docs/archive/design-actor-token-sync-postmortem.md`](./archive/design-actor-token-sync-postmortem.md).

Skill: `airi-acting-cue-act-tokens`.