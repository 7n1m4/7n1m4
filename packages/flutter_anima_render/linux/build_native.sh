#!/usr/bin/env bash
# Build the native library the Linux plugin links against.
#
# `crates/anima-render` is a staticlib; the plugin's CMake links
# `target/<profile>/libanima_render.a` plus the cc archives the crate's build
# script leaves under `target/<profile>/build/anima-render-*/out`. This script
# is the supported way to produce them before a desktop build.
set -euo pipefail

profile="${1:-debug}"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

cargo build --manifest-path "${repo_root}/Cargo.toml" -p anima-render --lib \
  $([ "${profile}" = "release" ] && echo --release)

echo "built libanima_render.a (${profile}) under ${repo_root}/target/${profile}"