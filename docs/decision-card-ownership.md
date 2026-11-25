<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Character/card ownership in the daemon world

- **Status:** accepted (2026-11-25)
- **Bead:** `airi-2ll` (parity criterion 2 ADR path)
- **Scope:** who owns character cards (the `AiriCard` document and its display-model/voice/background references), how the current split is allowed to persist, what a future daemon implementation must do, and what tests must prove. This is an ownership decision, **not** an implementation and **not** a claim that card parity is green.

## Context (source-verified)

The architecture is "one core, many surfaces": a Rust daemon owns state; Flutter is the thin WS client/renderer on desktop and mobile, and the Vue app is the behaviour reference (`docs/decision-server-endpoints.md:11-13`; Godot is retired). The fork is local-first, zero-account, BYOS (`docs/decision-byos-identity.md:10`, `docs/decision-server-endpoints.md:11`): one owner, their own devices, their own storage. Hosted multi-user card custody is not an architecture requirement.

Current card reality:

- **Daemon card CRUD is implemented.** `cards.list` (~1302), `cards.get` (~1316), `cards.import` (~1331), `cards.create` (~1347), `cards.update` (~1363), `cards.delete` (~1379) are registered handlers backed by `CoreService` (`crates/anima-daemon/src/gateway.rs:1301-1391`). Only `cards.metadata` / `cards.metadata.set` persist per-card flags (`gateway.rs:1395/1409`).
- **Flutter says so out loud.** The cards screen renders "Card management is not available on the local daemon." and never shows a false import-success state (`apps/flutter/lib/features/cards/cards_screen.dart:105-113`).
- **Vue/TS still owns card business logic.** The card store, import/export, and CRUD live in TypeScript (`packages/stage-ui/src/stores/modules/airi-card.ts`, `packages/stage-pages/src/pages/settings/airi-card/`, `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`); the parity checklist records this as **TS-core-remaining** (`docs/feature-parity-checklist.md:25,60`).
- **No ADR defined ownership.** `docs/design-flutter-godot-pivot.md` (Wave 1 deviation) and `docs/design-daemon-client.md:38` declare cards out of daemon scope; `docs/decision-server-endpoints.md:48` says the daemon "owns cards" while the handlers are stubs and calls the TS routes a compatibility mirror, "not the future source of truth." None of these defines where cards live, how migration happens, or what tests are owed. This doc is that missing decision.

## Decision

1. **Cards are a local, user-owned artifact. The canonical store is the user's device, not a hosted service and not (yet) the daemon's database.** A card is the portable `AiriCard` document defined in `docs/design-airi-card.md` (CCv2/CCv3 base fields plus `extensions.airi`), exchanged as AIRI JSON, `chara_card_v2` PNG, or the ZIP package (`docs/design-character-card-import-export.md`). There is no account, no hosted card registry, and no cloud-community card table. This is the card-side consequence of `docs/decision-byos-identity.md` (identity is device-and-token, never an account) and `docs/decision-server-endpoints.md:48` (do not expand characters into a hosted registry).
2. **Ownership today is split, and the split is deliberate and temporary.** Daemon card CRUD is implemented; the TypeScript store is the legacy writer pending retirement; Flutter card CRUD is the remaining client gap. This is allowed to persist **only** while the opt-in TS mirror / Electrobun shell window is live (`docs/decision-server-endpoints.md:59`, follow-up `airi-3mp`). It is not a resting state and not parity.
3. **Daemon `cards.*` handlers are the canonical CRUD.** `cards.list` / `cards.get` / `cards.import` / `cards.create` / `cards.update` / `cards.delete` are registered and functional. The TS card CRUD is retired, not mirrored, per item 4.
4. **When daemon card CRUD is implemented, the daemon becomes the single writer for card state, and the TS card CRUD is retired, not mirrored.** The implementation must (a) store the full-fidelity `AiriCard` (unknown/extension fields preserved, per the round-trip rule in `packages/stage-ui/src/types/card.schema.ts` — `AiriCardSchema` is loose, so unknown keys survive round-trips, per `docs/design-airi-card.md` "Shape" section), (b) keep the real `cards.list` / `cards.get` / `cards.import` / `cards.create` / `cards.update` / `cards.delete` handlers as the single writer, (c) route Flutter card CRUD through daemon RPC only; Vue remains the reference while it is still read, and (d) remove the TS card CRUD callers (`packages/stage-ui/src/stores/characters.ts` remote branches; the `airi-card` store's CRUD) so there is exactly one writer (`docs/design-daemon-core-rpc.md:119`). `cards.metadata` / `cards.metadata.set` remain as-is: they are metadata, not card CRUD.
5. **No client may advertise a verb it cannot use.** The retired Godot client's `CardsImport`/`CardsList`/`CardsGet` declarations died with it (2026-11-25); the rule stands for Flutter: a verb that only errors must not be listed as supported. Advertising a verb that only errors is a client-side lie of the same kind `gateway.rs:1299-1301` was written to prevent.
6. **Multi-device card movement is BYOS file exchange, not daemon sync.** Cards move between the user's devices as portable files (AIRI JSON / PNG / ZIP) or through the user's own storage target, consistent with `docs/decision-byos-identity.md:32` and `docs/design-character-card-import-export.md`. No hosted sync endpoint is added.

## Migration

- **Now → daemon implementation:** no data migration. The daemon card store is seeded from the user's existing local card data.
- **At daemon implementation:** the daemon store is seeded from the user's existing local card data (the `local:airi-cards` IndexedDB document set the TS store writes today, documented in `docs/data-catalog.md` §1.1) exactly once, idempotently; re-importing the same card must not duplicate or silently overwrite (import already auto-renames duplicates, `docs/design-character-card-import-export.md:96-98`). The TS card CRUD is deleted in the same change, not left as a second writer.
- **No account migration.** Nothing in this decision creates users, accounts, or a hosted card table; the BYOS identity contract is unchanged.

## Test obligations

The implementation bead must prove, at minimum:

1. Daemon `cards.list` / `cards.get` / `cards.import` / `cards.create` / `cards.update` / `cards.delete` round-trip a real `AiriCard` with `extensions.airi` intact.
2. Success-path tests cover all six card CRUD verbs.
3. Flutter card CRUD goes through daemon RPC and renders real state — no "not available" placeholder (`apps/flutter/lib/features/cards/cards_screen.dart`).
4. The TS card CRUD callers are gone; exactly one writer exists for card state.
5. Import idempotence: importing the same card twice yields one card (auto-rename), and a round-trip export→import preserves the card.

Until the TS retirement lands, the daemon card CRUD tests and the Flutter card screen are the correct guardrails.

## Consequences

- Parity criterion 2 is **not** satisfied by this doc alone. Criterion 2 stays FAIL until the TS card business logic is retired; this doc only supplies the ownership/migration/test contract the criterion's ADR path requires.
- The daemon owns card CRUD; the Flutter client renders real card state.
- No hosted card custody, no account, no second writer is introduced. The BYOS identity decision is untouched.
- Follow-up (report, not filed by this doc): the TS card-CRUD retirement is the remaining work item; `airi-3mp`'s retirement gate already tracks the TS-mirror window this rides on.

## Verification

- Source-verified the card CRUD handlers, the Flutter card screen, and the TS card callers at the line numbers above (2026-11-25). The Godot verb list cited in earlier revisions is retired with that client.
- Confirmed no prior `docs/decision-*.md` defines card ownership, migration, or test obligations; this doc fills that gap.
- No code changed; no build or tests run (documentation-only change).