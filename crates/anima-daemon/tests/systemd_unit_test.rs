// SPDX-License-Identifier: GPL-3.0-or-later

//! The packaged user unit must keep both legacy and current data dirs writable
//! under ProtectHome=read-only.

#[test]
fn read_write_paths_covers_both_data_dirs() {
    let unit = include_str!("../../../packaging/systemd/airi-daemon.service");
    let line = unit
        .lines()
        .find(|line| line.starts_with("ReadWritePaths="))
        .expect("ReadWritePaths line");
    assert!(line.contains("%h/.local/share/airi-slint"));
    assert!(line.contains("%h/.local/share/anima-daemon"));
}
