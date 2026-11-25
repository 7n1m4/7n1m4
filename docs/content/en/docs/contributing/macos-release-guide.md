---
title: macOS Build & Release
description: Contribute to Project Anima
---

# macOS Desktop Build & Release

There is currently **no macOS CI packaging lane** and no working macOS release script. Desktop
releases of the Vue/Electrobun reference app are produced locally with the Hutch/Electrobun build
and published by hand; the Flutter app (`apps/flutter`) is the shipping renderer and has its own
build. The Capacitor iOS app (`apps/stage-pocket`) was purged on 2026-11-13; mobile distribution
belongs to the Flutter app (`docs/decision-mobile-distribution-and-code-signing.md`).

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

- `.github/workflows/release-linux-desktop.yml` — the only desktop release automation.
- `apps/stage-tamagotchi/electrobun.config.ts` and `hutch.config.ts` — build definition.
- `docs/design-electrobun-port.md` — port status and remaining packaging gaps for the Electrobun
  reference app.
- `apps/flutter/README.md` and `docs/decision-mobile-distribution-and-code-signing.md` — the
  Flutter build and its Android/iOS signing lanes.
- `docs/content/en/docs/contributing/windows-release-guide.md` — shared build/release lessons.