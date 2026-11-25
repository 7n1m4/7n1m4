<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# anima-mmd

MMD (MikuMikuDance) parsers for AIRI's stage — the P10 **M0 (parser)** milestone.
Pure Rust, no toolkit dependency; decodes **PMX 2.0** models and **VMD** motions
into typed Rust structures.

The crate contract — what parses, what is deliberately unsupported (PMD, PMX 2.1,
QDEF, physics/IK evaluation, CP932), the allocation caps, the env-gated live
tests and the verification commands — lives in the rustdoc for
[`src/lib.rs`](src/lib.rs) and the per-module docs (`pmx`, `vmd`, `rest_pose`)
(`cargo doc -p anima-mmd --open`).
