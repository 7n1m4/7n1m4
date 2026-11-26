<!-- SPDX-License-Identifier: GPL-3.0-or-later -->
# Packaging

No dev-release artifacts ship from this directory after the Slint cutover
(`airi-wxp.1.7`). The daemon ships via `packaging/systemd/airi-daemon.service`
and the supervisor via `packaging/systemd/anima-supervisor.service`.

## Linux release install (daemon + supervisor)

The Linux desktop release workflow builds the real `anima-daemon` and
`anima-supervisor` Rust crates for x64 and arm64 and uploads the binaries as
release assets named `*-linux-<arch>-anima-daemon` and
`*-linux-<arch>-anima-supervisor`. Download both binaries for your architecture
into a directory (default: `dist-daemon/` in a checkout), then run:

```sh
ANIMA_BIN_DIR=dist-daemon ANIMA_ARTIFACT=linux-x64 \
  bash packaging/scripts/install-user-services.sh
```

The installer copies the binaries into `~/.local/bin`, installs both systemd
user units into `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user`, installs the
D-Bus activation file into `${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services`,
and reloads the user systemd manager. Start the services with:

```sh
systemctl --user enable --now anima-daemon.service anima-supervisor.service
```

Both D-Bus activation (`org.moeru.airi.Daemon1`) and `systemctl --user start
anima-daemon.service` then resolve the same `~/.local/bin/anima-daemon` path.
Without this installer the units fail with `status=203/EXEC` because the
binaries are not present.

## Determination: deleted Slint packaging files are intentional (domain migration complete)

The port removed `packaging/airi-slint.desktop`, `packaging/build-deb.sh`, and
`packaging/airi-qt.png` in commit `fae2ee2b`. This is **not** a premature deletion:
the ADR's Wave 6 gate (`docs/design-flutter-godot-pivot.md:390-399`) requires the
big-bang Slint deletion to happen **after** domain migration, and that migration
is complete. Evidence:

- All domain-migration beads are **CLOSED**: epic `airi-wxp.1` and its children
  (`airi-wxp.1.1`–`.8`), plus `airi-wes.1`–`.8` (settings, providers, STMM/journal,
  cards/sessions, and `airi-wes.8` "Delete crates/airi-slint after domain migration").
- `crates/anima-slint` no longer exists in the tree; all Slint business logic was
  absorbed into `anima-daemon`.
- The deletions were staged under bead `airi-wxp.1.7` ("Delete crates/airi-slint
  from workspace/CI/docs/packaging") — packaging cleanup was part of the gated
  cutover, not an early removal.
- `packaging/systemd/airi-daemon.service` was retargeted from `anima-slint` data
  paths to `anima-daemon` in the same commit.

The files were therefore **not restored**. Remaining mentions of them live only
under `docs/archive/qt-port/`; the ADR explicitly preserves audit archives
("no deletion path"), so those are expected and are not broken live links.
