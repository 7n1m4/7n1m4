---
title: Guide to Desktop version
description: Architecture and operational pointers for the desktop Anima client.
---

# Guide to Desktop Version

The desktop client is a renderer for the Anima daemon. The daemon owns core state and the local authenticated gateway; the client supplies presentation, view state, and client-local audio or rendering features.

For the accepted architecture, see the code-collected [Daemon client contract](https://github.com/7n1m4/AnimA/blob/main/docs/design-daemon-client.md) and [Flutter client README](https://github.com/7n1m4/AnimA/blob/main/apps/flutter/README.md). For setup and interaction details, use the [Settings Overview](../config/settings-overview), [Desktop Controls & Shortcuts](../desktop-controls), and [Gateway Security](../config/gateway) guides.

The legacy Electrobun/Vue desktop implementation is a behaviour reference while Flutter parity is incomplete; it is not a second state owner. No retired renderer or deprecated image-generation workflow is presented as an active capability.