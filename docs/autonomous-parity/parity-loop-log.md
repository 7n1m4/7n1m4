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
- Landed at `5615bcba` (`fix(flutter): consume presence events and align card state with Vue`); round-3 capabilities are indexed in `docs/feature-parity-checklist.md` and `docs/data-catalog.md` (bead `airi-li15`).
- Integrated verification: full Flutter suite **481/481 passed**; daemon serial suite and channel tests PASS; stage-ui typecheck PASS; `git diff --check` clean.

## 2026-11-26 — round 4 (scan → improve → verify)

- Scan at `5615bcba` rejected three scout false positives (`runtime.status` already in `anima-channel`; `display-model.resolve` already called by Flutter; control-strip extras are intentional). Verified gaps filed as `airi-wtp2` (Flutter had no bundled backgrounds) and `airi-li15` (docs missing round-3 rows/log commit).
- `airi-wtp2` landed: Flutter seeds the same two Vue builtin background ids/labels with JPEG visual exports of the Vue AVIF assets (the bundled Flutter engine rejects AVIF with `Invalid image data`), with direct fresh-store, reload-idempotence, image-codec and widget tests. Tombstones were rejected because Vue re-seeds builtins after removal and `scenes.json` has no such field.
- Round-4 docs rows added for presence/status chip, canonical `active_state`, VFX cue, keyset cursors, `stmm.upsert`, and bundled backgrounds; data catalog records wire-only presence/cursor values and the Flutter client-local scene library.
- Integrated verification: full Flutter suite **482 passed / 1 skipped** (a single flaky timing retry in `daemon_client_test.dart` passed in isolation and on a clean re-run); `cargo test --locked -p anima-channel -p anima-daemon -- --test-threads=1` PASS; `@proj-anima/stage-ui` typecheck PASS.

### Round 5 (scan → verify)

- `airi-msyk` fixed the pre-auth transport retry test race with a `Completer` on second transport creation (2s guard). Three isolated worker runs and a coordinator full-suite run pass; bead closed.
- Round-5 scans produced no new qualifying parity gaps. Rejected with source evidence: `lip_sync.rms` is client-local by `docs/decision-bridge-scope.md` and the daemon publisher has no production caller; TS `head` captions are a separate Live2D-only renderer (`HeadTetheredCaption.vue`, not the `docking=head` enum); TS parses VFX cues but has no visual aura consumer; journal/selfie and control-strip panel dispatch remain ratified deferred/intentional lanes.

### Round 6 (scan → verify)

- Two read-only scans covered settings/provider editors and chat/sessions/cards/provider flows. No new qualifying gaps: missing non-general settings editors are already recorded as partial parity (`feature-parity-checklist.md` settings rows); the general editor's extra daemon booleans are an intentionally narrow editor improvement, not a broken path; and the provider save form's free-text model field still writes the same daemon value as the discovered-model picker. Chat/cards/sessions already exercise the same daemon verbs as the TS references.

### Round 7 (scan → improve → verify)

- Wave dispatched at 18:50 UTC (round-7 checkpoints in `airi-jdic`): six read-only researchers, five disjoint implementers, six lane reviewers, five fix workers and five fix re-reviews; all Must/Should fixes applied.
- Landed: `758e1308` (Lane A — shell session id into stage captions, `airi-j1o5`; settings search, `airi-x9h6`; per-profile UST settings read, `airi-ye1p`), `db694b8d` (Lane B — bounded `chat.send` attachment ingest and pure pacing core, `airi-x46r.5` / `airi-hnoe`), `52efa2d6` (docs refresh).
- Verification: full Flutter suite **661 pass / 1 skip**; `cargo test --workspace --locked -- --test-threads=1` green; fmt, wire-type and golden-fixture drift checks clean. Follow-ups filed: `airi-jri8`, `airi-u5yb`, `airi-a9ga`, `airi-f2xw`, `airi-lg1c`, `airi-i18j`, `airi-hffd`, `airi-lwft`, `airi-eefo`, `airi-6ou4`.

### Round 8 (scan → improve → verify)

- Wave dispatched at 19:31 UTC (ownership matrix in `airi-dl69`): 24 read-only researchers and 10 disjoint implementers across eight active lanes; rust-protocol and ts-client stayed dormant (`wire.rs` single writer, TS reference-only). Retro (`airi-dl69`) records 82 subagents, no ownership collisions, and safety reviewers catching the Discord raw-read leak, caption unsubscribe race and speech regex DoS.
- Landed: `8bebf33e` (About links, `airi-dt2b`), `c0fcf0fe` (ordered UST rules + live speech settings reload, `airi-f2xw` / `airi-a9ga`), `73a2ca32` (settings keywords, encoded deep links, structured hearing editors, `airi-i18j` / `airi-hffd` / `airi-jyr6`), `046b5cb1` (unsubscribe-before-await, `airi-eefo`), `daf0c712` (scroll pinning, generation/session guards, composer drafts, `airi-zojh` / `airi-h2kj` / `airi-krhu`), `6fabad14` (pure `apply_outfit` transition, `airi-386n`), `1bbe6942` (token-safe Discord settings, `airi-bav5`), `5bb6e1ad` (docs refresh).
- Verification: full Flutter suite **705 pass / 1 skip**; targeted suites 549 Discord, 35+ UST, 21 card, 13 hearing tests; negative controls confirm the unsubscribe race, generation guard, startup race and token preservation tests are non-vacuous. Live Discord verbs remain open (`airi-ro6o`); outfit verb/cue/mesh remains `airi-e4r2`.

### Round 9 (scan → improve → verify)

- Wave dispatched at 20:09 UTC (ownership matrix in `airi-8rcd`): 80 subagents — 24 read-only researchers, 8 disjoint implementers, 27 reviewers, 12 fix workers and 9 focused re-reviews; shortfall from 100 because only eight disjoint ready slices existed. Active lanes: flutter-settings, flutter-speech, flutter-shell, flutter-stage/onboarding, rust-core, rust-daemon, docs-parity. Dormant: flutter-chat (stale `airi-362h.5`), rust-protocol (`wire.rs` single writer), ts-client (reference-only). No ownership collisions; a cross-slice compile break in `settings_screen.dart` was caught and corrected mid-wave.
- Landed (all seven SHAs verified with `git log -1`):
  - `4a0b2b45` — platform-aware settings search shortcuts: `SettingsScreen._handleSettingsKey` (Ctrl/Cmd+K focus, Enter/Escape handling) plus keyword/deep-link search tests (`airi-hew0`; 163 + 56 tests). Screen-wide scope only; app-global shortcut without hidden-tab focus theft stays open as `airi-5ne3`.
  - `8b54f4fe` — pure Dart `generateSSML` / `SsmlVoice` builder with `toSignedPercent`, xast-util-to-xml-verified escaping and the large-number fix (`airi-y86u`; 11 tests).
  - `183564d0` — Dart mirror of the Rust quick-start rules: `starterCompanions`, `normalizeSpeechProviderId`, `companionVoice`, `initialLlmProvider`, `PacingPreset` (`airi-x3zq`; 9 parity tests).
  - `2f5fcd4e` — `AboutBuildInfoCard` with `_resolveBuildInfo` and an honest `_bundledBuildInfo` fallback (no fabricated stamps; `airi-dny3`; 5 tests).
  - `da76987b` — frozen `STORYLINE_PRESETS` / `storyline_preset` Rust asset (`airi-dnyh`; 3 non-tautological tests) and provider credential migration helpers `migrate_legacy_provider_credential_keys` / `merge_config_preserving_secrets` with TS alias parity (`airi-s8pl`; 28 tests).
  - `0585ce1a` — `sessions.export` reply bounded below the WS frame cap via `SESSION_EXPORT_ENVELOPE_BYTES`, `SESSION_EXPORT_MAX_DATA_BYTES` and `session_export_reply` (`airi-q0xq`; 319 daemon tests, non-vacuous boundary test).
  - `6debfc42` — parity inventory, data catalog and round-log refresh plus the session-scoped-cues and token-safe-settings ADRs (`airi-i88z`).
- Key closed beads from `airi-8rcd` (parent closed): `airi-i88z`, `airi-y86u`, `airi-dny3`, `airi-x3zq`, `airi-dnyh`, `airi-s8pl`, `airi-q0xq`. Still open: `airi-hew0` / `airi-5ne3` (app-global shortcut) and `airi-1d8l` (test-first TDD adoption from the next wave).
- Verification recorded in `airi-8rcd`: full Flutter suite **736 pass / 736**; `cargo test --workspace --locked` green; fmt, wire-type and golden-fixture drift checks clean on the seven scoped commits (round-9 record: 44 golden fixtures). Retro: 82 subagents logged in `airi-dl69` for round 8 and 80 in `airi-8rcd` for round 9; researchers/implementers and tests/safety reviewers ranked highest (9/10), correctness 7/10, coordinator 7/10 (one rejected dispatch schema).
- Coordinator re-verification in the shared tree (2026-11-26, after other lanes resumed): `export-golden-fixtures --check` still green (44 fixtures). `export-wire-types --check` and `cargo fmt --check` are red only because concurrent out-of-scope lanes added `DiscordStatusReply` to `crates/anima-channel/src/wire.rs` (generated TS not yet regenerated) and an unformatted `crates/anima-core/src/dating_sim.rs`; those owners own the fixes, this docs slice touched neither.
- Docs drift follow-up: `airi-ijfc` added `scripts/tests/audit-doc-citations.mjs`, wired as `pnpm test:doc-citations` in the unit-test CI job. RED run flagged three stale `path:line` anchors to files deleted by the TS cutover (`libs/auth.ts`, `stores/auth.ts`, `use-local-first.ts` in the gate-evidence row); converted to historical prose, then GREEN (54 citations across `docs/feature-parity-checklist.md` and `docs/data-catalog.md`). Symbol names are preferred over bare line numbers in new anchors.
