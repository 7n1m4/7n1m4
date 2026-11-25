---
title: macOS Build & Release
description: Contribute to Project Anima
---

# macOS Desktop Build & Release

> **[2026-11-13] iOS half superseded**: the Capacitor `apps/stage-pocket` app was purged — web tech on mobile was rejected in favor of a unified Rust native app (desktop + mobile from one screen-size-reactive Slint codebase). See `docs/proposal-unified-rust-native-app.md`. The macOS `.dmg` sections remain valid; the iOS `.ipa` sections are historical until the Rust native app has a packaging lane.

## 1. Build

```bash
pnpm -F @proj-anima/stage-tamagotchi run build
```

`build` is `hutch run build`: it prepares Electrobun, builds the Vite renderer, and runs the
Electrobun build for the host platform. Inspect `apps/stage-tamagotchi/artifacts/` for what was
actually emitted; do not assume `.dmg`, `.app`, or `dist/` paths unless this build produced them.

Platform build options live in `apps/stage-tamagotchi/electrobun.config.ts`:

- `build.mac` — `bundleCEF: true`, `defaultRenderer: 'cef'`, `chromiumFlags`, icon `build/icon.icon`.
- Hardened-runtime entitlements: `apps/stage-tamagotchi/build/entitlements.mac.plist`
  (JIT, unsigned executable memory, dyld environment variables, camera/microphone/audio-input).
- Architecture: the build targets the host architecture; there is no separate `--arm64` / `--x64`
  packaging flag in the Hutch flow.

## 2. Publish

1. Draft release notes and get them reviewed (see the Windows guide, step 1).
2. Stamp `apps/stage-tamagotchi/package.json` and tag `v[version]` only with user authorization.
3. Build as above.
4. Upload the emitted artifacts:

```bash
GITHUB_TOKEN="" GH_SSL_NO_VERIFY="true" gh release upload v[version] <artifact_path> --repo dasilva333/airi --clobber
```

> [!CAUTION]
> The root `release:mac` wrapper is stale: `scripts/release/publish-mac.js` still inspects
> electron-builder outputs (`dist`, DMG/ZIP discovery) that a Hutch build never writes. Do not
> run it as the release path until it is ported to `apps/stage-tamagotchi/artifacts/`.

## 3. Notarization

Notarization is not wired into the current build. Local macOS builds require an Apple Developer
Certificate in the Keychain for any codesigning step you add; CI notarization secrets
(`CSC_CONTENT`, `APPLE_ID`) are not consumed by any current workflow. Treat notarized macOS
releases as an open action item, not an existing capability.

## 4. Troubleshooting

- **Node engine mismatch**: root `package.json` requires Node `>=20.14.0 <28.0.0`; a mismatch
  surfaces as engine warnings or lockfile churn during pnpm operations.
- **TS6133 unused symbols**: run `pnpm -F @proj-anima/stage-tamagotchi run typecheck` before a
  release build.
- **Vue template errors**: `[unplugin-vue-named-template-pre] Element is missing end tag` —
  `pnpm -F @proj-anima/stage-tamagotchi run typecheck` localizes the file.
- **Renderer OOM**: the renderer Vite build needs the heap bump restated in `hutch.config.ts`
  (`NODE_OPTIONS=--max-old-space-size=12288`).

## 5. Authoritative Documents

### Step 7: Manual Desktop Alternative / Verification
If you need to run macOS desktop packaging manually:
1. **Build macOS Executable**:
   ```bash
   pnpm -F @proj-anima/stage-tamagotchi run build:mac
   ```
2. **Publish to GitHub Releases**:
   ```bash
   GITHUB_TOKEN="" GH_SSL_NO_VERIFY="true" gh release upload v[version] apps/stage-tamagotchi/dist/Anima-[version]-darwin-arm64.dmg --repo dasilva333/airi --clobber
   ```

---

## 2. Platform Specific Considerations

### Notarization & Entitlements
- **macOS Desktop**: Entitlements are specified in `build/entitlements.mac.plist`. CI notarizes via `CSC_CONTENT` and `APPLE_ID`. Local builds require an Apple Developer certificate in your macOS Keychain.
- **iOS Mobile**: Automatic code signing is set up via Xcode. Headless `xcodebuild` uses `-allowProvisioningUpdates CODE_SIGN_STYLE=Automatic`.

### Dynamic Hardware Permissions
- **macOS (`apps/stage-tamagotchi/electron-builder.config.ts`)**: `extendInfo` must keep `NSMicrophoneUsageDescription` and `NSCameraUsageDescription`.
- **iOS (`apps/stage-pocket/ios/App/App/Info.plist`)**: Must include `NSMicrophoneUsageDescription` and `NSSpeechRecognitionUsageDescription` for audio pipelines and local transcription, along with `NSAllowsArbitraryLoads: true` for LAN HTTP access to local model runtimes.

### Architecture Support
- **macOS**: Supports `arm64` (Apple Silicon, default) and `x64` (Intel). Flags: `electron-builder --mac --arm64` or `--x64`.
- **iOS**: Targets 64-bit ARM iOS devices (`generic/platform=iOS`, minimum deployment target iOS 18.0).

---

## 3. Troubleshooting & Past Roadblocks

### Node Version Mismatch
- **Symptoms**: Engine check warnings or lockfile discrepancies during pnpm operations.
- **Cause**: Strict `engines` requirement in root `package.json` (`>=20.14.0 <28.0.0`).
- **Resolution**: Ensure the system Node.js version satisfies the declared range.

### Strict TypeScript Errors (TS6133)
- **Symptoms**: `pnpm run typecheck` or pre-build step crashes on unused imports or variables.
- **Resolution**: Run `pnpm -F @proj-anima/stage-tamagotchi run typecheck` prior to release to identify and clean up any unused symbols.

### Vue Template Compilation Errors
- **Symptoms**: `[unplugin-vue-named-template-pre] Element is missing end tag.`
- **Resolution**: Run `pnpm run typecheck:web` locally to locate and correct unmatched Vue template tags.

### Xcode SPM Dependency or CoreAI Failures
- **Symptoms**: `xcodebuild archive` fails resolving Swift Package Manager packages or complains about missing `CoreLLMKit`.
- **Resolution**: Run `pnpm -F @proj-anima/stage-pocket run ios:resolve` to refresh SPM dependencies, or verify that `apps/stage-pocket/scripts/build-ipa.ts` successfully executed `patchSpmPackageForCoreAI()`.

### iOS Simulator Blank White Screen (Missing `index.html`)
- **Symptoms**: Simulator or device launches into a blank screen with error: `[DevBridge] Navigation failed: The file “index.html” couldn’t be opened because there is no such file.`
- **Cause**: The Vite web bundle was never compiled into `apps/stage-pocket/dist` or synced to `apps/stage-pocket/ios/App/App/public`.
- **Resolution**: Run `pnpm -F @proj-anima/stage-pocket run build && pnpm -F @proj-anima/stage-pocket exec cap sync ios` (or `pnpm run open:ios`), then re-run the scheme in Xcode.

