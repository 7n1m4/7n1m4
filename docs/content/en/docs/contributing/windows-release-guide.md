---
title: Windows & Desktop Build
description: Contribute to Project Anima
---

# Desktop (Hutch/Electrobun) Build & Release Guide

This document captures the current desktop build and release workflow plus the environment
lessons that still apply after the Electrobun/Hutch port. The Windows process-safety rules and
the Node-shim lessons are unchanged; the old `release:win` / `electron-builder` /
`app.asar` inventory is gone.

## 1. Release Workflow

### Step 1: Generate & Review Release Notes

1. Compare commits between the previous stable tag and `HEAD`:
   ```bash
   git log [previous-tag]..HEAD --oneline
   ```
2. Draft user-facing notes (new UI, stability wins, feature additions) rather than internal refactors.
3. Present the drafted notes **inline** to the user for review and edits.
4. Once approved, save the notes to a local, uncommitted file (e.g., `release-notes.md`).

### Step 2: Version Stamping

Update the `version` in `apps/stage-tamagotchi/package.json`. Follow the format:
`[major].[minor].[patch]-stable.[YYYYMMDD]`.

### Step 3: Local Tagging (User Approval Required)

```bash
git tag v[version]
git push origin v[version]
```

Only tag and push when the user or release policy authorizes it.

### Step 4: Build

```bash
pnpm -F @proj-anima/stage-tamagotchi run build
```

`build` is `hutch run build`: it prepares Electrobun, builds the Vite renderer, and runs the
Electrobun build. Release artifacts land in `apps/stage-tamagotchi/artifacts/`.

> [!CAUTION]
> The root `release:win` wrapper is stale: `scripts/release/publish-win.js` still inspects
> electron-builder paths (`dist`, `app.asar`, DMG/ZIP discovery) that a Hutch build never
> produces. Do not treat it as authoritative until it is ported to `artifacts/`.

### Step 5: Publish

Inspect what the build actually emitted, then upload only those files:

```bash
GITHUB_TOKEN="" GH_SSL_NO_VERIFY="true" gh release upload [tag] [artifact_path] --repo dasilva333/airi --clobber
```

PowerShell equivalent:

```powershell
$env:GITHUB_TOKEN=$null; $env:GH_SSL_NO_VERIFY="true"; gh release upload [tag] [artifact_path] --repo dasilva333/airi --clobber
```

> [!IMPORTANT]
> **Authentication Scope**: `gh` needs the `workflow` scope to create releases:
> `gh auth refresh -h github.com -s workflow`.
>
> [!TIP]
> **Invalid `GITHUB_TOKEN` Override**: an invalid `GITHUB_TOKEN` in the session overrides the
> `gh` CLI keyring credentials and causes `HTTP 401`. Clearing it (as above) restores keyring auth.

### Step 6: Linux CI Inventory

`.github/workflows/release-linux-desktop.yml` is the only desktop release automation:

- Triggers: GitHub `release: prereleased`, manual `workflow_dispatch` (`build_only` /
  `artifacts_only` / `tag`), and a nightly `schedule` (cron `0 0 * * *`).
- Matrix: `ubuntu-latest` (linux-x64) and `ubuntu-24.04-arm` (linux-arm64).
- Build: `pnpm -F @proj-anima/stage-tamagotchi run build`.
- Artifacts: `apps/stage-tamagotchi/artifacts/*` — nightly/manual runs use
  `actions/upload-artifact`, release publication uses `softprops/action-gh-release`.

There is no CI lane for Windows or macOS desktop artifacts; those are local release operations.
deb/rpm/flatpak parity for the Hutch build is still open (`docs/design-electrobun-port.md`).

---

## 2. Lessons Learned: Environment Conflicts

### The `node:crypto` Renderer Error

The Electrobun renderer is a browser environment. Dependencies such as `@noble/hashes` or
`better-auth` can pull in Node-specific bundles in production builds.

**Symptoms:**
- `Uncaught Error: Module "node:crypto" has been externalized for browser compatibility.`
- `Cannot access "node:crypto.webcrypto" in client code.`

**Solution:**
1. **Aliases** in `apps/stage-tamagotchi/vite.config.ts` map `node:crypto` and `crypto` to
   `apps/stage-tamagotchi/src/renderer/shims/node-crypto.ts`.
2. **Custom Shimming**: that shim maps `node:crypto.webcrypto` to `window.crypto`.
3. **Catch-all plugin**: the `force-node-crypto-shim` plugin (`vite.config.ts:229-233`)
   redirects any remaining `node:*` / `process` / `module` / `path` / `fs` import to a virtual
   empty module.

### DuckDB / Node WASM Leakage

`@proj-anima/duckdb-wasm` can attempt to load Node-specific WASM loaders in the renderer. The
same `force-node-crypto-shim` interception keeps those imports out of the renderer bundle; when
adding another leaking dependency, extend that plugin rather than adding a second mechanism.

---

## 3. Resilient Builds

Transient network failures while downloading VRM/Live2D models or fonts are absorbed by the
`resilient(...)` wrapper around each download plugin in `apps/stage-tamagotchi/vite.config.ts`
(defined at the top of that file, applied at `:347-351`). Keep new build-time downloads wrapped
in it so a single failed asset does not abort the build.

---

## 4. Troubleshooting

- **Alias Conflicts**: if an alias does not apply, resolution may be happening through a
  relative path inside `node_modules`; use a regex alias or the `force-node-crypto-shim`
  `resolveId` hook to catch all variants.
- **Typecheck Failures**: `pnpm -F @proj-anima/stage-tamagotchi run typecheck` localizes TS6133
  unused-symbol failures and Vue template errors before a build.
- **Renderer OOM**: the renderer Vite build needs a large heap; `hutch.config.ts` restates
  `NODE_OPTIONS=--max-old-space-size=12288` for `build:renderer`.
- **File Locks**: if a build fails because a file cannot be replaced, an Anima instance or file
  watcher is holding it. Follow the process-safety rules below.

---

## 5. Build Safety & Process Management

> [!CAUTION]
> **Strict Process Guidelines**:
> - **Never autonomously run `taskkill`** or similar commands without explicitly pausing and
>   obtaining permission from the user.
> - `taskkill` is **not** part of the release process and is a last resort only after manual
>   coordination with the user fails.
> - If a file is locked, ask the user to stop the relevant process; they will stop and restart
>   it to unblock the build.
> - **"Nuking" all `node.exe` / `bun.exe` processes is never acceptable**, as it can cause data
>   loss or terminate essential background services.

---

## 6. Windows Application Control & Code Signing Action Items

When users open Windows release binaries they may hit:
> **`An Application Control policy has blocked this file.`**

### Root Cause

1. **Unsigned executables**: WDAC, AppLocker, or SmartScreen blocks unsigned or self-signed
   binaries downloaded from the internet.
2. **Strict machine policies**: some Windows installations block non-whitelisted installers in
   user/download directories.

### Action Items

1. **Code Signing**: sign Windows release binaries with a valid Code Signing Certificate, or
   document how to trust the release certificate.
2. **Portable Archives**: ship an archive alongside any installer so users with restricted
   installer policies can extract and run without administrator setup.
3. **Document the User Workaround**: unblock via **Properties → General → Unblock** (or
   PowerShell `Unblock-File`), run as administrator, or use the portable archive.