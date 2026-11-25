# Built-in Tools & MCP (source of truth)

Two registries decide what the model can *do*: the built-in tool factory and the MCP
bridge. **The in-code registries are the source of truth**; this doc maps them.

## Where the truth lives

| Concern | Canonical source |
| :--- | :--- |
| Built-in tool factory (`builtinTools()`) | [`apps/stage-tamagotchi/src/renderer/stores/tools/builtin/index.ts`](../../../../../../apps/stage-tamagotchi/src/renderer/stores/tools/builtin/index.ts) |
| `image_journal` / `text_journal` / `generate_motion` / `stickers` / `mcp_*` tools | sibling files in the same directory |
| MCP stdio manager (main process, `mcp.json` lifecycle) | [`apps/stage-tamagotchi/src/main/services/airi/mcp-servers/index.ts`](../../../../../../apps/stage-tamagotchi/src/main/services/airi/mcp-servers/index.ts) |
| Renderer bridge + card ACL filter | [`stores/mcp-tool-bridge.ts`](../../../../../stage-ui/src/stores/mcp-tool-bridge.ts) |
| MCP settings UI | [`settings/modules/mcp.vue`](./mcp.vue) |
| Architecture | `docs/arch-mcp-integration.md` |

## 1. Built-in tools

`builtinTools()` resolves lazily per request (chat) or once per resolve
(proactivity / Gemini Live). Registration is conditional:

| Tool | Registered when | Card gate |
| :--- | :--- | :--- |
| `text_journal` | always | `text_journal` |
| `generate_motion` | always (filtered at the gateway by default) | `generate_motion` |
| `image_journal` | only if `artistry.configured` | `image_journal` |
| `stickers` | only if the sticker library has content | pass-through |
| `mcp_list_tools`, `mcp_call_tool` | only if the MCP bridge exists and ≥1 server is connected | `mcp` |

`image_journal.create` is deprecated and gated off (`stores/modules/artistry.ts`
`ARTISTRY_GENERATION_ENABLED = false`); it returns the deprecation notice. `apply` and
`set_as_background` still work on the existing journal history.

Per-card gating is `extensions.airi.generation.known.allowedTools` on the card
(`web_search`, `filesystem`, `mcp`, …). Tools are strictly opt-in: a card without the
matching entry has every tool schema stripped before the request, which protects small
local models from context bloat.

## 2. Model Context Protocol

MCP is the open standard for connecting a model to external data sources and tools over
local subprocesses. In Anima, stdio (and streamable-HTTP) servers run **only in the
desktop main process**; the renderer reaches them through typed eventa IPC and the bridge
— it never spawns a child process itself.

Config lives in `mcp.json` at `join(Utils.paths.appData, 'airi', 'mcp.json')`:

```json
{
  "mcpServers": {
    "filesystem": {
      "command": "npx",
      "args": ["-y", "@modelcontextprotocol/server-filesystem", "/path/to/project"]
    },
    "weather": {
      "command": "python",
      "args": ["-m", "mcp_server_weather"],
      "env": { "WEATHER_API_KEY": "…" }
    }
  }
}
```

Add servers from **Settings &rarr; Modules &rarr; MCP Server & Tools** (folder-path
manager with filesystem presets, raw-JSON editor, runtime status, apply-and-restart) or by
editing the file directly.

The LLM sees two meta-tools rather than the raw server tools:

1. `mcp_list_tools` — discovery, filtered by the card ACL.
2. `mcp_call_tool` — execution; the tool name must be the qualified `server::tool` form
   (separator `::`). Calls are capped at 15 s total; surface `lastError` rather than
   swallowing it.

## 3. How a tool call runs in chat

1. You ask for something that needs a tool.
2. The model emits a call for a registered tool (or `mcp_call_tool`).
3. The tool executes locally with your user account's permissions; output lands in the
   chat ledger.
4. The model reads the output and answers.

Only connect servers and grant directory access to sources you trust — there is no
sandbox beyond your own OS permissions.
