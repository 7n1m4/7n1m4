---
title: System & Data Management
description: Managing local persistence, IndexedDB storage, cloud backup sync (BYOS), and data lifecycles.
---

# System & Data Management

Anima's local persistence topology, the offline-first BYOS outbox sync queue, and the export/reset data lifecycle are implemented in the stage-ui database layer, the sync engine, and the stage-pages data settings page.

See the code-colocated [System & Data Management](https://github.com/7n1m4/AnimA/blob/main/packages/stage-pages/src/pages/settings/data/README.md) document for the storage topology, BYOS adapters and merge rules, export/import, and the reset danger zone.