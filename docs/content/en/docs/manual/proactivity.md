---
title: Proactivity & Idle Behaviors
description: Learn how Anima senses your environment, decides when to speak spontaneously, and how to configure autonomous heartbeats.
---

# Proactivity & Idle Behaviors

Anima's autonomous Proactivity Engine (the periodic heartbeat loop, environmental telemetry, and `NO_REPLY` decision) is implemented in the nan0-runtime heartbeat engine.

See the code-colocated [Proactivity Engine](https://github.com/7n1m4/AnimA/blob/main/packages/nan0-runtime/src/heartbeat/README.md) document for the heartbeat flow, privacy model, configuration modes, and spontaneous reflection.