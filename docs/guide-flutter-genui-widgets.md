# Flutter GenUI widgets

The Flutter companion can render dynamic A2UI widgets streamed through
`token.delta`. Dynamic UI is opt-in per message and never executes Dart,
JavaScript, or arbitrary code from model output.

## Enabling dynamic widgets

`ChatScreen` sends `chat.send` with:

```json
{
  "sessionId": "<session or empty for a new one>",
  "content": "<user message>",
  "genUi": true
}
```

`genUi: true` makes the daemon include the A2UI system prompt for that turn.
Without it the daemon does not prompt for dynamic widgets; the Flutter client
still parses and renders any A2UI it receives.

## Supported A2UI shape

Flutter uses the GenUI 0.10.4 SDK (A2UI `v0.9`) and the **no-asset basic
catalog**: cards, text, buttons, rows/columns, lists, tabs, dividers, icons,
checkboxes, sliders, text/date-time inputs, choice pickers, and modals. Audio,
image, and video items are excluded. The catalog also excludes the
`openUrl` client function, so a generated widget cannot launch an external URL.

A model emits fenced or raw JSON messages, for example:

````text
```json
{"version":"v0.9","createSurface":{"surfaceId":"answer-card","catalogId":"https://a2ui.org/specification/v0_9/catalogs/basic/catalog.json"}}
```
```json
{"version":"v0.9","updateComponents":{"surfaceId":"answer-card","components":[{"id":"root","component":"Card","children":["title"]},{"id":"title","component":"Text","text":"Airi widget"}]}}
```
````

`SurfaceController` applies messages in order; `A2uiTransportAdapter` separates
ordinary assistant text from A2UI messages even when JSON is split across
several streamed deltas. The client feeds the **complete accumulated turn** to
the parser on the final delta, renders each new surface in its own keyed card,
and avoids duplicating surfaces across later turns.

When a persisted session is opened, the same parser rehydrates assistant
history: stored A2UI JSON becomes a live surface again rather than raw text in
the bubble.

## Failure behavior

- Malformed JSON is handled by the SDK parser and remains ordinary text; it
  never crashes the chat screen.
- Components outside the allowlisted catalog are not built. A turn whose only
  dynamic widget is unsupported shows: “A dynamic widget could not be
  displayed.”
- Controller, parser, and surface construction errors are contained locally;
  the assistant text stream and chat session continue normally.
- There is no arbitrary-code execution and no external URL launching from
  generated components. Only the curated catalog's local Flutter widgets can
  be constructed; actions not implemented by the catalog are ignored.
