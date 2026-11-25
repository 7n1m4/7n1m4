---
name: airi-docs-site-maintenance
description: >-
  Maintain the in-app Markdown viewer and shared sidebar: docs/content/en/**/*.md, Markdown frontmatter, asset resolution, public manual versus technical docs. Application translation keys use airi-i18n-localization.
---

# AIRI Docs Site Maintenance

## Key Files/Locations

- `docs/content/en/**/*.md` — English source documentation rendered by the in-app viewer.
- `docs/shared-sidebar.ts` — Canonical single-source-of-truth sidebar definition consumed by the in-app documentation viewer (relative links as-is).
- `apps/stage-tamagotchi/src/renderer/pages/settings/docs/[...path].vue` — In-app Markdown viewer route.
- `docs/*.md` (Root) — Technical developer documentation: internal RFCs, architectural deep dives, state machine specs, and maintainer checklists.

## Separation Contract: Technical vs. User-Facing Docs

- **Root `docs/*.md`**: Internal engineering assets. Contains implementation details, raw research papers, data schemas, and PR planning documents. These live flat in `docs/` so coding agents and maintainers can locate them without recursive folder traversal.
- **`docs/content/`**: Public user-facing documentation. Explains *how to use* AIRI, configure settings, import models, and connect tools without overwhelming the user with internal store schemas or implementation blueprints.

## Content & Asset Conventions

1. **Frontmatter Standards**:
   ```yaml
   ---
   title: Page Title
   description: Brief description for the in-app Markdown viewer.
   ---
   ```
2. **Asset Resolution Rules**:
   - Store images in an `assets/` subfolder next to the markdown file (e.g., `./assets/screenshot.avif`).
   - Use `.avif`, `.webp`, or `.png` for static images.
   - **Avoid Uncommitted Local Video/GIF Imports**: Vite's rollup bundler resolves relative image/video links at build time. Never reference local `.mp4` or `.gif` files that are not checked into git; host large videos on CDN or use static image fallbacks.
   - In blog frontmatter `preview-cover`, use `@assets('./assets/image.avif')` with existing files.
3. **Sidebar Updates**:
   - Whenever adding or moving a page in `docs/content/`, update `docs/shared-sidebar.ts`.
   - Never add dead links to `shared-sidebar.ts`—the in-app viewer resolves links at runtime.

## Common Pitfalls

- **Broken Internal Links**: Relative markdown links must match actual files in `docs/content/`. If a document was moved to root `docs/`, link to the corresponding public manual guide or feature showcase instead.
- **Shared Sidebar Navigation**: `shared-sidebar.ts` provides English-only viewer navigation. Ensure section IDs and paths match expected English document structures.
- **Duplicate Architecture Files**: Do not duplicate internal design docs inside `docs/content/en/docs/advanced/`. Keep technical specs in root `docs/` and summarize user-facing functionality in `docs/manual/`.

## Verification

- Verify that all cross-references in `docs/shared-sidebar.ts` resolve to existing markdown files under `docs/content/en/`.
- Verify the desktop docs viewer route `apps/stage-tamagotchi/src/renderer/pages/settings/docs/[...path].vue` renders the linked pages.

## Related Skills & References

- **Key Documents**: [[interacting]], [[proactivity]], [[vision]], [[comfyui]], [[memory]], [[mcp-tools]], [[custom-models]], [[desktop-controls]]
