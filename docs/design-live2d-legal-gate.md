# Design: Live2D legal/release gate and Cubism user-fetch consent

Status: accepted gate record, 2026-11-25 (bead `airi-l4qa`). Scope: the policy
that keeps Live2D out of shipping builds until the maintainer approves it, and
the consent flow a user must complete before a Cubism Core exists on their
machine. This document records policy only; it grants no permission to vendor,
download or commit any Live2D artifact.

## 1. Decisions (maintainer, accepted 2026-11-25)

- **Owner.** The maintainer owns legal/release approval for Live2D and owns the
  Cubism user-fetch consent flow. No agent, build script or runtime path may
  grant that approval or synthesize that consent.
- **3D ships before Live2D.** Spine, VRM and MMD (the 3D kinds, plus Spine) may
  ship without Live2D. A release that contains Live2D before 3D has shipped is
  invalid regardless of the state of the gate.
- **Hard-blocked until review.** Live2D stays hard-blocked in this client until
  the maintainer records the legal review as resolved. The block is a build-time
  fact, not a runtime preference: there is no flag, setting or fallback that
  turns it off.
- **User-fetched Core after terms acceptance.** The proprietary Cubism Core is
  fetched by the user from Live2D after the user accepts the Live2D terms. The
  client never downloads it, never bundles it and never guesses a path to it.
- **Never committed.** No Cubism Core binary, and no build output containing one,
  is ever committed to this repository. The only in-tree precedent is the
  git-ignored `.cache/` (`/.gitignore`, `**/.cache/`), which is a local
  developer cache and not a distribution source.

## 2. Why the block is loud

A silent fallback would paint a fabricated or wrong character, which is worse
than showing nothing. The client therefore states the reason:

- `ModelRuntimeInfo.blocker` for `ModelKind.live2d` is
  `ModelRuntimeBlocker.cubismLicense`, and `isAvailable` is false.
- `ModelBackendRegistry.fromRuntimes` turns that blocker into an
  `UnavailableModelBackend` whose `load` throws
  `ModelBackendException('runtime-unavailable', …)` mentioning the user-fetched
  Cubism Core. The stage surfaces the failure; it never renders a substitute.
- `apps/flutter/test/model_runtime_test.dart` locks this in: the kind is
  unavailable, every other kind is not blocked by licensing, and a load attempt
  fails with the typed error instead of producing a handle.

Resolving the gate is a deliberate edit to `model_runtime.dart` plus this
document, reviewed by the maintainer. Nothing else in the tree can resolve it.

## 3. Consent flow (user-fetched Cubism Core)

The flow is a sequence of user actions, each of which is mandatory:

1. **Terms.** The client shows the Live2D terms and the user accepts them. There
   is no pre-accepted default and no acceptance recorded on the user's behalf.
2. **Fetch.** Only after acceptance does the client offer the official Live2D
   download location. The user performs the fetch; the client does not proxy,
   mirror or automate it.
3. **Placement.** The user places the Core where the local build looks for it,
   under the git-ignored `.cache/` path already used by the web stage. Placement
   is a user action on the user's machine.
4. **Verification.** The native backend verifies the Core is present and loads
   it. Absent or invalid Core is a loud failure, identical in kind to the gate
   failure, never a silent no-render.
5. **Release approval.** Shipping a Live2D-capable build additionally requires
   the maintainer's recorded legal review (SDK Release License and the
   redistribution analysis in `docs/research-godot-renderer-spike.md` §1). The
   user's consent does not substitute for it.

## 4. Non-goals

- Vendoring, downloading or committing Cubism Core, the Cubism Native Framework
  or any Live2D sample model.
- Porting the retired Godot/GDCubism path; that research is historical
  (`docs/research-godot-renderer-spike.md`).
- Reopening the accepted plan decisions in
  `docs/plan-flutter-native-model-rendering.md` (implementation order Spine →
  VRM → MMD, 3D before Live2D). This document records the gate those decisions
  assume.

## 5. Cross-links

- `docs/plan-flutter-native-model-rendering.md` — Phase 6 and gate C6; the
  maintainer-decision list this gate implements.
- `docs/design-flutter-godot-pivot.md` — legal review before release, 3D first.
- `docs/research-godot-renderer-spike.md` §1 — the three-layer licensing stack
  and the absolute no-commit rule for the Core binary.
- `apps/flutter/lib/features/stage/model_runtime.dart` — the executable form of
  this policy.