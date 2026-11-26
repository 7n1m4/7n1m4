// SPDX-License-Identifier: GPL-3.0-or-later
//! Compiles the vendored spine-cpp line into the crate.
//!
//! spine-cpp exports its symbols under the single `spine` C++ namespace and
//! carries no per-version namespacing, so only one runtime line can be linked
//! into a single binary. The default line is 4.2 (matches the Vue package's
//! `^4.2.0` main dependency). Set `AIRI_SPINE_RUNTIME=4.1.00` (or `4.0.64`)
//! at build time to compile a different vendored line instead.

use std::env;
use std::path::{Path, PathBuf};

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").expect("CARGO_MANIFEST_DIR"));
    let vendor_root = manifest_dir.join("../../third-party/spine-runtimes");

    let runtime = env::var("AIRI_SPINE_RUNTIME").unwrap_or_else(|_| "4.2".to_string());
    let runtime_dir = vendor_root.join(&runtime);
    let spine_root = runtime_dir.join("spine-cpp");
    let include_dir = spine_root.join("include");
    let src_dir = spine_root.join("src");

    assert!(
        include_dir.is_dir() && src_dir.is_dir(),
        "vendored spine-cpp not found at {} — expected include/ and src/ (see third-party/spine-runtimes/VERSIONS.md)",
        spine_root.display()
    );

    // Header of the selected line, only used for the #if in the shell.
    let is_4_2 = runtime.starts_with("4.2");

    let mut build = cc::Build::new();
    build
        .cpp(true)
        .std("c++17")
        .include(&include_dir)
        .include(manifest_dir.join("cpp"))
        .define(
            if is_4_2 {
                "AIRI_SPINE_42"
            } else {
                "AIRI_SPINE_PRE_42"
            },
            None,
        )
        .flag_if_supported("-Wno-unused-parameter")
        .flag_if_supported("-Wno-unused-variable")
        .flag_if_supported("-w"); // vendored third-party code; keep our warnings for our code

    for entry in walk_cpp(&src_dir) {
        build.file(entry);
    }
    // Native backends, compiled into their own archive so the linker pulls the
    // Rust-side entry points they reference (cc archives are scanned once, in
    // order, so a backend that references the rlib must sit *after* it).
    let mut backends = cc::Build::new();
    backends
        .cpp(true)
        .std("c++17")
        .include(&include_dir)
        .include(manifest_dir.join("cpp"))
        .define(
            if is_4_2 {
                "AIRI_SPINE_42"
            } else {
                "AIRI_SPINE_PRE_42"
            },
            None,
        )
        .flag_if_supported("-Wno-unused-parameter")
        .flag_if_supported("-Wno-unused-variable")
        .flag_if_supported("-w");
    backends.file(manifest_dir.join("cpp/spine_shell.cpp"));
    backends.file(manifest_dir.join("cpp/render_contract.cpp"));
    backends.file(manifest_dir.join("cpp/vrm_backend.cpp"));
    backends.file(manifest_dir.join("cpp/mmd_backend.cpp"));
    backends.compile("airi_render_backends");

    build.compile("airi_spine_cpp");

    println!("cargo:rerun-if-env-changed=AIRI_SPINE_RUNTIME");
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/spine_shell.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/spine_shell.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/render_contract.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/render_contract.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/render_contract_internal.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/vrm_backend.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/vrm_backend.h").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/mmd_backend.cpp").display()
    );
    println!(
        "cargo:rerun-if-changed={}",
        manifest_dir.join("cpp/mmd_backend.h").display()
    );
    emit_rerun_if_changed(&src_dir);
    emit_rerun_if_changed(&include_dir);
}

fn walk_cpp(dir: &Path) -> Vec<PathBuf> {
    let mut out = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        for entry in std::fs::read_dir(&dir).expect("read spine-cpp src dir") {
            let path = entry.expect("dir entry").path();
            if path.is_dir() {
                stack.push(path);
            } else if path.extension().is_some_and(|ext| ext == "cpp") {
                out.push(path);
            }
        }
    }
    out.sort();
    out
}

fn emit_rerun_if_changed(root: &Path) {
    for entry in std::fs::read_dir(root).expect("read spine-cpp dir") {
        let path = entry.expect("dir entry").path();
        if path.is_dir() {
            emit_rerun_if_changed(&path);
        } else {
            println!("cargo:rerun-if-changed={}", path.display());
        }
    }
}
