// SPDX-License-Identifier: GPL-3.0-or-later
//! anima-supervisor — owns the system tray and the client process lifecycle.
//!
//! Invariants (docs/design-daemon-process-lifecycle.md §2-§3):
//!   * The daemon exclusively owns port 6121. This process never binds a socket.
//!   * The daemon is never started/stopped/restarted here except via
//!     `systemctl --user start anima-daemon` ("Start core" convenience) —
//!     systemd remains the single restart authority.
//!   * Launch/stop/restart applies to the Flutter client process only.

mod logging;

use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::Duration;

use tray_item::TrayItem;

static FLUTTER: Mutex<Option<Child>> = Mutex::new(None);

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn reap_child_slot(slot: &Mutex<Option<Child>>) {
    if let Ok(mut guard) = slot.lock() {
        if let Some(child) = guard.as_mut() {
            if let Ok(Some(_)) = child.try_wait() {
                let pid = child.id();
                *guard = None;
                eprintln!("anima-supervisor: reaped child pid {pid}");
            }
        }
    }
}

fn child_slot_is_running(slot: &mut Option<Child>) -> bool {
    match slot {
        None => false,
        Some(child) => child.try_wait().ok().flatten().is_none(),
    }
}

fn spawn_flutter() -> Result<(), String> {
    let mut guard = FLUTTER.lock().map_err(|e| e.to_string())?;
    if child_slot_is_running(&mut guard) {
        return Ok(());
    }
    let bin = env_or("ANIMA_FLUTTER_BIN", "flutter");
    let dir = env_or("ANIMA_FLUTTER_DIR", "apps/flutter");
    let args: Vec<String> = env_or("ANIMA_FLUTTER_ARGS", "run -d linux")
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let child = Command::new(&bin)
        .args(&args)
        .current_dir(&dir)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("flutter spawn failed: {e}"))?;
    eprintln!("anima-supervisor: started flutter (pid {})", child.id());
    *guard = Some(child);
    Ok(())
}

fn stop_flutter() {
    if let Ok(mut guard) = FLUTTER.lock() {
        if let Some(mut c) = guard.take() {
            let _ = c.kill();
            let _ = c.wait();
            eprintln!("anima-supervisor: stopped flutter");
        }
    }
}

fn restart_flutter() {
    stop_flutter();
    let _ = spawn_flutter();
}

fn start_core() {
    // Still systemd's child — never a direct daemon spawn.
    let _ = Command::new("systemctl")
        .args(["--user", "start", "anima-daemon"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn();
    eprintln!("anima-supervisor: requested systemctl --user start anima-daemon");
}

fn quit() {
    stop_flutter();
    std::process::exit(0);
}

fn main() {
    logging::init();
    tracing::info!("anima-supervisor starting (tray owner; daemon owns port 6121)");
    // Audit retention: supervisor never handles audit data; anima-daemon owns the
    // audit log and its .cleared-* archive retention (forever; no GUI deletion).
    // See docs/decision-audit-archive-retention.md.
    let icon = tray_item::IconSource::Resource("system-run");
    let mut tray = match TrayItem::new("AIRI", icon) {
        Ok(t) => t,
        Err(e) => {
            eprintln!("anima-supervisor: tray init failed: {e}; exiting");
            return;
        }
    };
    let result = (|| -> Result<(), tray_item::TIError> {
        tray.add_menu_item("Start Flutter", || {
            let _ = spawn_flutter();
        })?;
        tray.add_menu_item("Stop Flutter", || stop_flutter())?;
        tray.add_menu_item("Restart Flutter", || restart_flutter())?;
        tray.add_menu_item("Start Core (systemd)", || start_core())?;
        tray.add_menu_item("Quit", || quit())?;
        Ok(())
    })();
    match result {
        Ok(()) => {
            eprintln!("anima-supervisor: tray registered");
            // Keep the process alive.
            loop {
                reap_child_slot(&FLUTTER);
                std::thread::sleep(Duration::from_secs(1));
            }
        }
        Err(e) => eprintln!("anima-supervisor: tray menu build failed: {e}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Mutex;

    static TEST_SLOT: Mutex<Option<Child>> = Mutex::new(None);

    #[test]
    fn reap_and_running() {
        // exited child
        let mut child = Command::new(std::env::current_exe().unwrap())
            .arg("--help")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let _ = child.wait();
        {
            let mut g = TEST_SLOT.lock().unwrap();
            *g = Some(child);
        }
        reap_child_slot(&TEST_SLOT);
        assert!(TEST_SLOT.lock().unwrap().is_none());

        // live child
        let child = Command::new("sleep")
            .arg("2")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut slot = Some(child);
        assert!(child_slot_is_running(&mut slot));
        if let Some(mut c) = slot.take() {
            let _ = c.kill();
            let _ = c.wait();
        }
        assert!(!child_slot_is_running(&mut slot));
    }
}
