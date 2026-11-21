<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Mobile release guide (Flutter control/chat app)

Scope: `apps/flutter` mobile targets only. Desktop release is `release-linux-desktop.yml`.

## Build lanes (CI)

Workflow: `.github/workflows/release-flutter-mobile.yml`.

- **Android:** `flutter build appbundle` (Play) + `flutter build apk` (sideload).
- **iOS:** `flutter build ipa`.

Triggered on `workflow_dispatch` and release prerelease.

## Signing

Secrets (GitHub Actions):

- Android: `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`, `ANDROID_KEY_PASSWORD`.
- iOS: `IOS_CERTIFICATE_BASE64`, `IOS_CERTIFICATE_PASSWORD`, `IOS_PROVISIONING_PROFILE_BASE64`, `IOS_TEAM_ID`.

No signing material committed. CI decodes into temp paths and deletes after job.

## Manual runbook

- Play Console track promotion and store listing.
- App Store Connect submission review and release scheduling.
- Keystore/certificate creation and renewal; secret rotation.

## Not signed/shipped

Debug builds, emulator-only artifacts, builds without release keystore/profile.
