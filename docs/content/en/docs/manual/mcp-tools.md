---
title: Expanding Anima with MCP & Tools
description: How to give Anima real-world powers using built-in tools and the Model Context Protocol (MCP) ecosystem.
---

# Expanding Anima with MCP & Tools

Anima's built-in tool registry and the desktop MCP client (main-process stdio server manager, renderer bridge, and card-level tool ACLs) are implemented in the stage-tamagotchi tool factory and MCP service manager.

See the code-colocated [Built-in Tools & MCP](https://github.com/7n1m4/AnimA/blob/main/packages/stage-pages/src/pages/settings/modules/MCP-TOOLS.md) document for the built-in tool table, card gating, the `mcp.json` contract, and the `mcp_list_tools` / `mcp_call_tool` flow.