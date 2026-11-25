---
title: Settings Hub & The Engine Room
description: Architecture and operational entry points for Anima's settings experience.
---

# Settings Hub & The Engine Room

The Settings Hub is the renderer's entry point to daemon-owned configuration. It presents navigation and client view state; provider credentials, model selection, speech settings, memory policy, and data operations are owned by the Rust backend rather than duplicated in the renderer.

For the canonical client/daemon boundary, see the code-collected [Daemon client architecture](https://github.com/7n1m4/AnimA/blob/main/docs/design-daemon-client.md) and [Flutter client contract](https://github.com/7n1m4/AnimA/blob/main/apps/flutter/README.md).

Use the [Settings Overview](../manual/config/settings-overview) for configuration categories and the [Gateway Security](../manual/config/gateway) guide for connection and authentication operations. Image-generation settings are deprecated; existing image history remains read-only, and no generation capability is claimed here.