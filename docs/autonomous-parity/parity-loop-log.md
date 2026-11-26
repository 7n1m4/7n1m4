# Parity loop log

## 2026-11-26 — round 1 (review-triggered fixes)

- Baseline: WIP work committed at `baeb4bb3` after eight parallel reviewers audited 60 changed files. Review ledger: bead `airi-h3au` (closed), 20 follow-up beads filed.
- Fixes dispatched to eight disjoint worker slices; worker evidence comments are on the individual beads.
- Completed and verified so far:
  - CI scripts: `node --test` harnesses pass; workflow YAML parsed (beads `airi-kjs0`, `airi-bjck`).
  - Wire contract: `cargo test -p anima-channel --locked` (all suites pass), `cargo fmt -p anima-channel -- --check` clean, exporter `--check` 43 fixtures current, `flutter test test/golden_fixtures_test.dart` 25 tests pass (`airi-h5ke`, `airi-5vwm`).
  - Daemon settings: `cargo test -p anima-daemon --locked` all targets pass; `cargo fmt -p anima-daemon -- --check` clean (`airi-b87w`, `airi-5w9q`).
  - Flutter client: `flutter test test/daemon_client_test.dart test/daemon_tls_test.dart` 35 + 9 tests pass (`airi-at07`, `airi-ohcx`).
  - Stage model: `flutter test test/stage_native_surface_test.dart` 6/6 pass with non-vacuity check (`airi-mn6w`).
- Review backlog fixes have all landed and been verified (see below).
- All fix workers landed. Integrated verification: `cargo test -p anima-channel --locked` PASS; `cargo fmt -p anima-channel -- --check` + daemon fmt PASS; exporter `--check` 43 fixtures current; `cargo test -p anima-daemon --locked` PASS on rerun (first parallel run hit known chat-test flakiness; serial run 227/227 passed); Flutter focused 10-file run 143/143 PASS; CI harnesses 6/6 + 1/1 PASS; stage-ui typecheck + provider-catalog vitest 11/11 PASS.
- Pre-existing, out of scope: `settings_screen_test.dart` has an ambiguous `DropdownButtonFormField` tap at HEAD that fails intermittently in combined Flutter runs; no changes were made to that file.
- Next scan: compare the integrated daemon handler inventory and Flutter typed calls against Vue behaviour references; file gaps as beads before implementing.

## 2026-11-26 — round 2 (scan → improve → verify)

- Scan at `57eff076` by four read-only scouts: RPC coverage, event lane, stage parity, docs/tests. Findings filed as `airi-dib9`, `airi-sxin`, `airi-ag24`, `airi-bmt5`, `airi-pntk`, `airi-kke4`; all implemented by disjoint workers and closed after focused verification.
- Implemented: Flutter forwards daemon keyset cursors verbatim (cards/sessions/chat); VFX emotion cues parse and route; daemon-backed active card + per-card backdrop restore; typed `stmm.upsert` wrapper + explicit summary form; typed presence/status event hooks with sequence dedupe; `daemonKind` documented as TS-local metadata.
- Verification: focused cursor 59/59, VFX 39/39, card-state 54/54, memory 38+7/7, presence 35/35; daemon serial suite 227/227; stage-ui typecheck PASS; `git diff --check` clean. Full Flutter suite: 459 tests, 5 failures — three provider-screen and one settings-screen failure reproduce with implementation and tests byte-identical to HEAD; one scene-management failure is intermittent and passed in focused runs.
- Next scan: re-audit RPC/event/stage surfaces at the new commit for remaining gaps; consider the pre-existing provider/settings test failures as a separate test-hygiene bead (test files unchanged from HEAD, so not a parity regression).

## 2026-11-26 — round 3 (scan → improve → verify)

- Scan at `628a996a` by three read-only scouts. Rejected one false positive: `runtime.status` is built into `anima-channel`'s `RpcRegistry` and already served by the daemon's session dispatcher; no handler is missing.
- Verified gaps filed as `airi-rs74` (typed presence/status hooks had no lib/ consumer), `airi-2wew` (Flutter card restore ignored Vue's canonical `extensions.airi.active_state`), and `airi-l0u2` (pre-existing provider/settings test failures).
- `airi-l0u2` fixed at the harness level: lazy-ListView tests now reveal widgets before interaction; the settings dropdown finder is scoped and its stale catalog expectation matches the intentionally supported two-button catalog. Focused suite 19/19 passed 3x plus coordinator re-run; production untouched.
- `airi-rs74`: a stage `PresenceStatusChip` now consumes the typed hooks and renders only daemon-supplied presence/health, clearing stale values on disconnect. `airi-2wew`: Flutter reads Vue's canonical `active_state` card fields first and writes both `active_state` and `modules` mirrors.
- Integrated verification: full Flutter suite **481/481 passed**; daemon serial suite and channel tests PASS; stage-ui typecheck PASS; `git diff --check` clean.
