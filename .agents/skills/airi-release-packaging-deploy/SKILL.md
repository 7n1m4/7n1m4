---
name: airi-release-packaging-deploy
description: >-
  Package/release/deploy AIRI: Hutch/Electrobun desktop artifacts, Linux CI, static Web Stage Pages deployment, versioning, tags, release notes, edge-worker publishing. Cloud relay implementation uses airi-cloud-relay-infrastructure.
---

# AIRI Release, Packaging & Deploy

Deployment surface map for shipping AIRI. Desktop releases are built by Hutch/Electrobun and published from `apps/stage-tamagotchi/artifacts/`; Linux has a GitHub Actions release workflow, while Windows/macOS are local release operations. Mobile ships through the Flutter app (`apps/flutter`), which has no separate release channel yet. Web Stage deploys as a static GitHub Pages frontend; edge workers deploy per-user via Cloudflare.

## 1. Surface Map

| Surface | App | Artifacts | Ship path |
|---|---|---|---|
| Linux desktop | `stage-tamagotchi` | Hutch/Electrobun tarball and `*-update.json` sidecars under `apps/stage-tamagotchi/artifacts/` | `.github/workflows/release-linux-desktop.yml` |
| Windows/macOS desktop | `stage-tamagotchi` | Platform artifacts emitted by `pnpm -F @proj-anima/stage-tamagotchi run build` under `apps/stage-tamagotchi/artifacts/` | Local/manual release flow; verify generated files before publishing |
| Mobile | `apps/flutter` | Flutter app ships to Android/iOS; no packaging channel yet | Flutter app ships to Android/iOS; no packaging channel yet (`apps/stage-pocket` and Capacitor tooling were purged 2026-11-13) |
| Web Stage | `stage-web` | `apps/stage-web/dist/` | `.github/workflows/deploy-frontends.yml` → GitHub Pages at `/airi/web-stage/` |
| Edge relay | `apps/stage-edge` | Cloudflare Worker (per-user) | Built into users' accounts via OAuth PKCE during onboarding; see `airi-cloud-relay-infrastructure` |

## 2. Desktop Build & Release

Canonical build entrypoints:

- `pnpm -F @proj-anima/stage-tamagotchi run dev` — Hutch development runner.
- `pnpm -F @proj-anima/stage-tamagotchi run build` — `hutch run build`; prepares Electrobun, builds the Vite renderer, and writes release artifacts under `apps/stage-tamagotchi/artifacts/`.
- `apps/stage-tamagotchi/electrobun.config.ts` — app identity, Bun main-process entrypoint, CEF renderer settings, icons, and platform build options.
- `apps/stage-tamagotchi/hutch.config.ts` — Hutch commands, including renderer Vite build and typecheck wrappers.

Release workflow:

1. **Release notes first.** Inspect commits since the previous tag and draft user-facing notes. Group product updates, developer/contributor notes, and upgrade notes separately. Keep notes user-centric and avoid raw commit SHAs in the narrative.
2. **Version stamp.** Update `apps/stage-tamagotchi/package.json` and commit the version change through the normal repository workflow.
3. **Tag.** Create and push `v<version>` only when the user or release policy authorizes it.
4. **Build.** Run `pnpm -F @proj-anima/stage-tamagotchi run build`.
5. **Inspect artifacts.** Publish only files actually emitted under `apps/stage-tamagotchi/artifacts/`; do not assume `.exe`, `.dmg`, `.deb`, `.rpm`, `.flatpak`, `app.asar`, or `dist/win-unpacked` paths unless a current build produced them.
6. **Upload.** For manual GitHub releases, use `gh release upload <tag> <artifact> --repo dasilva333/airi --clobber` only after artifact inspection.

> [!CAUTION]
> Root `release:win` / `release:mac` wrappers still exist, but `scripts/release/publish-win.js` and `publish-mac.js` inspect obsolete electron-builder paths. Do not treat them as authoritative until they are ported to Hutch/Electrobun artifact discovery.

## 3. Linux CI / CD

`.github/workflows/release-linux-desktop.yml` is the current desktop release automation.

- Triggers: GitHub `release: prereleased`, manual `workflow_dispatch`, and nightly schedule.
- Matrix: `ubuntu-latest` for linux-x64 and `ubuntu-24.04-arm` for linux-arm64.
- Build command: `pnpm -F @proj-anima/stage-tamagotchi run build`.
- Artifact path: `apps/stage-tamagotchi/artifacts/*`.
- Uploads use `actions/upload-artifact` for nightly/manual artifact runs and `softprops/action-gh-release` for release publication.

## 4. Mobile

Mobile is the Flutter app (`apps/flutter`) — the same primary, sole active renderer used on desktop — as a remote thin client of the desktop `anima-daemon` (`docs/design-flutter-godot-pivot.md`). The Capacitor app and `packages/cap-vite` were purged (2026-11-13), and the proposed unified Rust native (Slint) app was superseded 2026-11-25 (`proposal-unified-rust-native-app.md`, historical record). No Flutter packaging/release channel exists yet; do not document Android/iOS installers as shipping until one is added.

## 5. Web Stage / GitHub Pages / Edge

- `.github/workflows/deploy-frontends.yml` builds `apps/stage-web` with `BASE_URL=/airi/web-stage/` and uploads `apps/stage-web/dist` to GitHub Pages.
- Root `pnpm run build:pages` builds packages and Web Stage for the Pages subpath.
- Root `pnpm run build:web:pages` builds only Web Stage for the Pages subpath.
- Web Stage uses Vite's `BASE_URL` and Vue Router history base; do not reintroduce a separate VitePress/docs Pages build.
- `apps/stage-edge` is not centrally deployed; each user provisions their own Cloudflare Worker + KV + R2 through onboarding.

## 6. Common Pitfalls

- **Stale electron-builder assumptions:** old scripts/docs may mention `dist`, `win-unpacked`, `app.asar`, DMG/ZIP discovery, or deb/rpm/flatpak packaging. Treat those as historical unless a current Hutch/Electrobun build emitted the file.
- **Renderer heap:** Hutch drops some Node heap flags; `hutch.config.ts` restates `NODE_OPTIONS=--max-old-space-size=12288` for the Vite renderer build.
- **Release auth:** clear invalid `GITHUB_TOKEN` overrides for `gh` commands and ensure `gh` has `workflow` scope when dispatching workflows.
- **Fork vs upstream asymmetry:** release scripts and workflows target `dasilva333/airi`; do not assume upstream CI parity.
- **Mobile release:** mobile is the Flutter app (`apps/flutter`); no packaging channel exists yet. Redirect Android/iOS release requests to the Flutter client scope, not the superseded unified Rust native app.

## Verification

- Desktop build: `pnpm -F @proj-anima/stage-tamagotchi run build`.
- Narrow typecheck: `pnpm -F @proj-anima/stage-tamagotchi typecheck`.
- CI interpretation: inspect `.github/workflows/release-linux-desktop.yml` and upload paths under `apps/stage-tamagotchi/artifacts/`.
- Pages build: `pnpm run build:web:pages`.
- After release edits, report changed files and any remaining stale release wrappers rather than claiming unsupported installers exist.

### Authoritative Documents

- `.github/workflows/release-linux-desktop.yml` — current desktop release automation.
- `.github/workflows/deploy-frontends.yml` — current static Web Stage Pages deployment.
- [docs/design-electrobun-port.md](../../../docs/design-electrobun-port.md) — Electrobun/Hutch port status and remaining gaps.
- [docs/rosetta-stone.md](../../../docs/rosetta-stone.md) — repo layout and path index.

## Related Skills & References

- **Peer Skills**: [[airi-cloud-relay-infrastructure]], [[airi-codebase-verification]]
- **Key Documents**: [[design-electrobun-port]], [[rosetta-stone]]
