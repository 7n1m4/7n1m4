# Storage Architecture (pointer)

**Status:** historical dev-troubleshooting note; the technical content moved into code.

Renderer persistence — the `unstorage` topology (`local:` → IndexedDB `airi-local`,
`outbox:` → IndexedDB `airi-sync-queue`), the remote-sync enqueue exclusions, the
per-domain repository key table and the origin-scoped "dev port switch" effect (Electron
`userData` `app-config.json` vs. per-origin LocalStorage/IndexedDB, `start_airi.bat`) —
is documented in [`packages/stage-ui/src/database/README.md`](../packages/stage-ui/src/database/README.md).
Persisted-key inventory: [`docs/data-catalog.md`](./data-catalog.md).

Skills: `airi-data-persistence`, `airi-binary-safety`.