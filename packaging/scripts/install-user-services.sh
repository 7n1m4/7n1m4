#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Install the Rust daemon, supervisor, and their user-session units from a
# Linux release checkout. The binaries are release assets staged under
# dist-daemon/ by .github/workflows/release-linux-desktop.yml.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
bin_src=${ANIMA_BIN_DIR:-$root/dist-daemon}
bin_dir=${ANIMA_USER_BIN:-$HOME/.local/bin}
systemd_dir=${ANIMA_SYSTEMD_USER_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}
dbus_dir=${ANIMA_DBUS_SERVICES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/dbus-1/services}
artifact=${ANIMA_ARTIFACT:-linux-x64}

# Nightly builds use the run's ref name; stable releases use the tag. Accept
# either without guessing a version string at install time.
find_binary() {
  local suffix=$1 candidate
  for candidate in "$bin_src"/*-"$artifact"-"$suffix" "$bin_src"/"$suffix"; do
    if [[ -f $candidate ]]; then
      echo "$candidate"
      return 0
    fi
  done
  echo "Missing $suffix release binary under $bin_src (expected *-$artifact-$suffix)" >&2
  return 1
}

daemon_src=$(find_binary anima-daemon)
supervisor_src=$(find_binary anima-supervisor)

mkdir -p "$bin_dir" "$systemd_dir" "$dbus_dir"
install -m 755 "$daemon_src" "$bin_dir/anima-daemon"
install -m 755 "$supervisor_src" "$bin_dir/anima-supervisor"
install -m 644 "$root/packaging/systemd/airi-daemon.service" "$systemd_dir/anima-daemon.service"
install -m 644 "$root/packaging/systemd/anima-supervisor.service" "$systemd_dir/anima-supervisor.service"
install -m 644 "$root/packaging/dbus/org.moeru.airi.Daemon1.service" "$dbus_dir/org.moeru.airi.Daemon1.service"

printf 'Installed daemon, supervisor, systemd units, and D-Bus activation into %s\n' "$HOME"
if command -v systemctl >/dev/null 2>&1; then
  systemctl --user daemon-reload
  printf 'Run: systemctl --user enable --now anima-daemon.service anima-supervisor.service\n'
fi
