# `change_cos` Dependency Bottleneck — Architecture

Architecture-level pointer. This was the open design question blocking the Live2D DSL
interpreter: creator packs swap costumes via `change_cos <manifest>.json`, but AIRI has no
Cubism 1/2 support and its importer splits multi-`.moc3` archives into standalone models, so
hit areas, motion files and menu gating all desynchronize when the swap fails.

For background details on the interactive DSL triggers and original creator structures, refer to:
*   [Live2D DSL Interpreter Specification](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/design-live2d-dsl-interpreter-spec.md)
*   [Live2D Custom Animation & Expression Insights (Special Sauce)](file:///Users/richardpinedo/Projects.nosync/airi/airi_dasilva333/docs/research-live2d-special-sauce.md)

Historical status: resolved in favor of the lookup/actor-swap direction; the adapter keeps
`onCostumeWillSwap` as a render hint no-op and `changeCostume` as a stub until the ingestion
work lands. Heap and intimacy already survive a swap by construction.

## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
