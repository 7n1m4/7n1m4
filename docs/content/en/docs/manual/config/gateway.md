---
title: Configuring the Anima Gateway
description: Gateway architecture and operational security pointers.
---

# Configuring the Anima Gateway

The Anima Gateway is the authenticated local WebSocket boundary between renderer clients and the Rust backend. The daemon owns the channel configuration and core state; clients connect to the gateway rather than running a competing state writer.

The protocol, default loopback endpoint, token lifecycle, and TLS rules are collected in the code-level [gateway channel documentation](https://github.com/7n1m4/AnimA/blob/main/crates/anima-channel/src/lib.rs) and [configuration implementation](https://github.com/7n1m4/AnimA/blob/main/crates/anima-channel/src/config.rs). The client-side connection contract is documented in the [Flutter client README](https://github.com/7n1m4/AnimA/blob/main/apps/flutter/README.md).

For user-facing setup, see [Settings Overview](./settings-overview) and [System & Data Management](./system-data). Keep the default loopback binding unless a network-accessible endpoint is required; non-loopback configurations must preserve the gateway's TLS and authentication protections. The gateway configuration file contains a plaintext authentication token and must be protected by the data-directory permissions.