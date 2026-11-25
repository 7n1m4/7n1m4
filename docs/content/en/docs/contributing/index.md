---
title: Contributing
description: Contributor architecture and workflow entry points.
---

# Contributing

Project Anima's contributor workflow is code-collected in the repository's [contributing guide](https://github.com/7n1m4/AnimA/blob/main/.github/CONTRIBUTING.md). Start there for prerequisites, development commands, and pull-request workflow.

The [architecture overview](https://github.com/7n1m4/AnimA/blob/main/docs/README.md) is the source of truth for the Rust daemon, gateway, renderer ownership, and migration rules. Use the [documentation maintenance guide](./docs) for the public-docs contract and [Desktop Development](./tamagotchi) for the legacy reference client's development command.

Do not add a second business-logic owner in a renderer. New cross-boundary work starts with the daemon/gateway contract and follows the architecture and parity rules in the code-collected documents.