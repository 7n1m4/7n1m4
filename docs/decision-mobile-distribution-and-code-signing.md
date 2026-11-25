<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Decision: Android and iOS distribution routes, code signing, and packaging lanes

- **Status:** accepted (2026-11-21, ponytail)
- **Bead:** `airi-u71.7` (child of epic `airi-wxp.3`)
- **Scope:** Flutter full stage-UI app (`apps/flutter`) mobile targets only. Desktop release (`release-linux-desktop.yml`) unchanged.

## Decision

1. **Android — Play Store (internal → closed → open testing) is the primary route; signed APK sideload is the fallback.**
   - Play Store track progression: internal testing (CI-uploaded AAB) → closed testing → open/production.
   - Sideload: signed release APK published as a GitHub Release asset for users who cannot use Play (region, device, or policy). APK is the same build, signed with the same keystore.
2. **iOS — App Store via TestFlight is the primary route; sideload is dev-only.**
   - TestFlight internal/external groups for beta; App Store release for production.
   - Sideload (AltStore / Sideloadly / enterprise profile) is supported only for development and internal QA; it is **not** a public distribution channel. No public IPA hosting.
3. **Signing owners and secrets.**
   - Android: a single release keystore owned by the project maintainer, stored as GitHub Actions secrets (`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`). Keystore file also backed up offline (encrypted) by the maintainer; loss is unrecoverable for Play Store identity.
   - iOS: Apple Developer Program account owned by the maintainer; signing certificate + provisioning profile stored as GitHub Actions secrets (`IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_TEAM_ID`, `APP_STORE_CONNECT_API_KEY_*`). Rotated on expiry; renewal is a manual maintainer task.
   - No signing material is committed to the repo. `.gitignore` already excludes keystores/profiles; CI decodes from secrets into a temp keychain/profile dir and deletes after the job.
4. **CI vs manual.**
   - CI (GitHub Actions) automates: checkout, Flutter build (`flutter build appbundle` / `flutter build ipa`), signing with secrets, artifact upload to GitHub Releases (sideload APK) and (for iOS) TestFlight upload via `altool`/Fastlane using the App Store Connect API key. Triggered on `workflow_dispatch` and on release tags.
   - Manual runbook (maintainer): Play Console track promotion and store listing changes; App Store Connect submission review responses and release scheduling; keystore/certificate creation and renewal; secret rotation. Documented in `docs/contributing/mobile-release-guide.md` (to be written when the first mobile release ships).
5. **Not signed / not shipped:** debug builds, emulator-only artifacts, and any build without the release keystore/profile.

## Consequences

- Requires adding mobile build workflows; deferred until `apps/flutter` reaches a releasable state (E3 waves). This decision unblocks naming owners and secret slots now.
- Sideload APK keeps a non-store escape hatch; no public iOS sideload to avoid Apple policy risk.

## Rejected alternatives

- F-Droid / third-party Android stores: deferred; Play + sideload covers the need.
- Embedded core on mobile (flutter_rust_bridge): already rejected (D10); mobile stays a remote client, so signing is app-only.