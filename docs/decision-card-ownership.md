<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Character/card ownership in the daemon world

- **Status:** accepted (2026-11-25)
- **Bead:** `airi-2ll` (parity criterion 2 ADR path)
- **Scope:** who owns character cards (the `AiriCard` document and its display-model/voice/background references), how the current split is allowed to persist, what a future daemon implementation must do, and what tests must prove. This is an ownership decision, **not** an implementation and **not** a claim that card parity is green.

## Context (source-verified)

The architecture is "one core, many surfaces": a Rust daemon owns state; Flutter/Godot/Vue are thin WS clients (`docs/decision-server-endpoints.md:11-13`). The fork is local-first, zero-account, BYOS (`docs/decision-byos-identity.md:10`, `docs/decision-server-endpoints.md:11`): one owner, their own devices, their own storage. Hosted multi-user card custody is not an architecture requirement.

Current card reality:

- **Daemon card CRUD is an explicit, honest stub.** `cards.list`, `cards.get`, `cards.import` are registered handlers that return a "not implemented … card management is out of scope for the daemon port" error (`crates/anima-daemon/src/gateway.rs:1179-1205`). `card_verbs_report_not_implemented` (`gateway.rs:3207-3219`) locks that contract: the three verbs must stay registered and must never claim success. Only `cards.metadata` / `cards.metadata.set` persist per-card flags (`gateway.rs:1206-1218`).
- **Flutter says so out loud.** The cards screen renders "Card management is not available on the local daemon." and never shows a false import-success state (`apps/flutter/lib/features/cards/cards_screen.dart:105-113`).
- **Godot advertises verbs it cannot use.** `DaemonRpc.cs:31-35` declares `CardsList`/`CardsGet`/`CardsImport` and lists them in `AllActions` (`DaemonRpc.cs:41-48`), so the Godot client claims support for verbs that only ever return the stub error.
- **Vue/TS still owns card business logic.** The card store, import/export, and CRUD live in TypeScript (`packages/stage-ui/src/stores/modules/airi-card.ts`, `packages/stage-pages/src/pages/settings/airi-card/`, `packages/stage-ui/src/stores/characters.ts:138,171,198,236,261`); the parity checklist records this as **TS-core-remaining** (`docs/feature-parity-checklist.md:25,60`).
- **No ADR defined ownership.** `docs/design-flutter-godot-pivot.md:292` and `docs/design-daemon-client.md:38` declare cards out of daemon scope; `docs/decision-server-endpoints.md:48` says the daemon "owns cards" while the handlers are stubs and calls the TS routes a compatibility mirror, "not the future source of truth." None of these defines where cards live, how migration happens, or what tests are owed. This doc is that missing decision.

## Decision

1. **Cards are a local, user-owned artifact. The canonical store is the user's device, not a hosted service and not (yet) the daemon's database.** A card is the portable `AiriCard` document defined in `docs/design-airi-card.md` (CCv2/CCv3 base fields plus `extensions.airi`), exchanged as AIRI JSON, `chara_card_v2` PNG, or the ZIP package (`docs/design-character-card-import-export.md`). There is no account, no hosted card registry, and no cloud-community card table. This is the card-side consequence of `docs/decision-byos-identity.md` (identity is device-and-token, never an account) and `docs/decision-server-endpoints.md:48` (do not expand characters into a hosted registry).
2. **Ownership today is split, and the split is deliberate and temporary.** The TypeScript store is the only working card CRUD implementation; the daemon owns only per-card metadata flags; Flutter/Godot have no working card CRUD. This is allowed to persist **only** while the opt-in TS mirror / Electrobun shell window is live (`docs/decision-server-endpoints.md:59`, follow-up `airi-3mp`). It is not a resting state and not parity.
3. **The daemon `cards.*` stubs stay, and stay honest, until a future implementation bead.** `cards.list` / `cards.get` / `cards.import` continue to return the explicit not-implemented error and `card_verbs_report_not_implemented` continues to enforce it. No client may treat the stub error as "no cards" or as success. A future bead — not this doc — implements daemon card CRUD; until it lands, the stubs are the correct behavior and this decision does not authorize changing them.
4. **When daemon card CRUD is implemented, the daemon becomes the single writer for card state, and the TS card CRUD is retired, not mirrored.** The implementation must (a) store the full-fidelity `AiriCard` (unknown/extension fields preserved, per the round-trip rule in `docs/design-airi-card.md` §4.3), (b) register real `cards.list` / `cards.get` / `cards.import` handlers and delete the stub branch plus `card_verbs_report_not_implemented`, (c) route Flutter/Godot/Vue card CRUD through daemon RPC, and (d) remove the TS card CRUD callers (`packages/stage-ui/src/stores/characters.ts` remote branches; the `airi-card` store's CRUD) so there is exactly one writer (`docs/design-daemon-core-rpc.md:119`). `cards.metadata` / `cards.metadata.set` remain as-is: they are metadata, not card CRUD.
5. **Godot's advertised `CardsImport`/`CardsList`/`CardsGet` must be reconciled in that same bead** — either wired to the real handlers or removed from `DaemonRpc.AllActions` (`godot/scripts/Net/DaemonRpc.cs:31-48`). Advertising a verb that only errors is a client-side lie of the same kind `gateway.rs:1180-1181` was written to prevent.
6. **Multi-device card movement is BYOS file exchange, not daemon sync.** Cards move between the user's devices as portable files (AIRI JSON / PNG / ZIP) or through the user's own storage target, consistent with `docs/decision-byos-identity.md:32` and `docs/design-character-card-import-export.md`. No hosted sync endpoint is added.

## Migration

- **Now → daemon implementation:** no data migration. The TS store remains the working store; the daemon gains no card table until the implementation bead.
- **At daemon implementation:** the daemon store is seeded from the user's existing local card data (the `local:airi-cards` IndexedDB document set the TS store writes today, `docs/design-airi-card.md` §1) exactly once, idempotently; re-importing the same card must not duplicate or silently overwrite (import already auto-renames duplicates, `docs/design-character-card-import-export.md:96-98`). The TS card CRUD is deleted in the same change, not left as a second writer.
- **No account migration.** Nothing in this decision creates users, accounts, or a hosted card table; the BYOS identity contract is unchanged.

## Test obligations

The implementation bead must prove, at minimum:

1. Daemon `cards.list` / `cards.get` / `cards.import` round-trip a real `AiriCard` with `extensions.airi` intact (full-fidelity, unknown fields preserved).
2. `card_verbs_report_not_implemented` is removed and replaced by success-path tests; the stub branch is gone (a grep for "out of scope for the daemon port" in `crates/anima-daemon/src/gateway.rs` returns nothing).
3. Flutter and Godot card CRUD go through daemon RPC and render real state — no "not available" placeholder (`apps/flutter/lib/features/cards/cards_screen.dart`), and Godot's `AllActions` matches implemented handlers.
4. The TS card CRUD callers are gone; exactly one writer exists for card state.
5. Import idempotence: importing the same card twice yields one card (auto-rename), and a round-trip export→import preserves the card.

Until that bead lands, the current tests (`card_verbs_report_not_implemented`, the Flutter placeholder) are the correct guardrails and must keep passing.

## Consequences

- Parity criterion 2 is **not** satisfied by this doc alone. Criterion 2 stays FAIL until daemon card CRUD ships and the TS card business logic is retired; this doc only supplies the ownership/migration/test contract the criterion's ADR path requires.
- The daemon keeps an honest "not implemented" for card CRUD; clients keep telling the truth about it (Flutter) or must be fixed to (Godot).
- No hosted card custody, no account, no second writer is introduced. The BYOS identity decision is untouched.
- Follow-up (report, not filed by this doc): the daemon card CRUD implementation bead, the Godot `AllActions` reconciliation, and the TS card-CRUD retirement are separate work items that must land together; `airi-3mp`'s retirement gate already tracks the TS-mirror window this rides on.

## Verification

- Source-verified the stub handlers, the enforcing test, the Flutter placeholder, the Godot verb list, and the TS card callers at the line numbers above (2026-11-25).
- Confirmed no prior `docs/decision-*.md` defines card ownership, migration, or test obligations; this doc fills that gap.
- No code changed; no build or tests run (documentation-only change).