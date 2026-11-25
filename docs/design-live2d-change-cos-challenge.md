# `change_cos` Dependency Bottleneck — Architecture

Architecture-level pointer. This was the open design question blocking the Live2D DSL
interpreter: creator packs swap costumes via `change_cos <manifest>.json`, but AIRI has no
Cubism 1/2 support and its importer splits multi-`.moc3` archives into standalone models, so
hit areas, motion files and menu gating all desynchronize when the swap fails.

Source of truth for the conflict analysis, both candidate architectures (actor-token lookup
bridge vs. unified multi-skeleton imports) and the chosen direction now lives in
`packages/stage-ui-live2d/src/runtime/README.md` §change_cos bottleneck.

Historical status: resolved in favor of the lookup/actor-swap direction; the adapter keeps
`onCostumeWillSwap` as a render hint no-op and `changeCostume` as a stub until the ingestion
work lands. Heap and intimacy already survive a swap by construction.

## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
