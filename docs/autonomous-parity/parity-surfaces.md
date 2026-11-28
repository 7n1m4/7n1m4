# Parity surfaces checked each scan

## 2026-11-26

- **Wire contract:** `crates/anima-channel/src/wire.rs` (events/DTOs), generated TS in `packages/server-shared/src/types/generated/anima-channel.ts`, Dart mirror in `apps/flutter/lib/daemon_client/protocol.dart`, golden fixtures in `crates/anima-channel/fixtures/golden/`. Drift check: `cargo run -p anima-channel --example export-golden-fixtures -- --check`, `cargo test -p anima-channel`, `flutter test test/golden_fixtures_test.dart`.
- **Daemon RPC surface:** `crates/anima-daemon/src/gateway.rs` handlers vs `apps/flutter/lib/daemon_client/daemon_client.dart` typed calls vs Vue/TS stores in `packages/stage-ui/src/stores/`.
- **Stage behaviour:** Flutter stage state/screens in `apps/flutter/lib/features/stage/` against Vue references in `packages/stage-ui/src/components/scenes/` and `packages/stage-ui/src/stores/`; contract notes in `docs/feature-parity-checklist.md`.
- **Native rendering:** `packages/flutter_anima_render/` platform hosts and `crates/anima-render/` backends; legal gate in `docs/design-live2d-legal-gate.md`. Do not claim platform coverage not implemented.
- **Docs:** `docs/feature-parity-checklist.md`, `docs/data-catalog.md`, `docs/rosetta-stone.md`, `docs/design-daemon-gateway.md`; stale claims are follow-up beads, not silent edits.
- **Test-fidelity surfaces:** `crates/anima-channel/tests/interaction_*_trace.rs` against `apps/flutter/test/*_golden_trace_test.dart`. A wire or behaviour change must show the same interaction sequence in both; a missing counterpart is a parity bead, not a silent pass.
- **Unported pure TS modules:** pure-TS logic modules under `packages/` that still lack a Rust daemon or Flutter counterpart. Scan for new or additive modules each round and record each unported module as a candidate slice in the parity ledger.

Sources: `AGENTS.md` §0/§1; `docs/feature-parity-checklist.md:18-40`.
