// SPDX-License-Identifier: GPL-3.0-or-later
//! anima-supervisor — owns the system tray and the client process lifecycle.
//!
//! Invariants (docs/design-daemon-process-lifecycle.md §2-§3):
//!   * The daemon exclusively owns port 6121. This process never binds a socket.
//!   * The daemon is never started/stopped/restarted here except via
//!     `systemctl --user start anima-daemon` ("Start core" convenience) —
//!     systemd remains the single restart authority.
//!   * Launch/stop/restart applies to client processes only (Flutter, Godot).

use std::process::{Child, Command, Stdio};
use std::sync::Mutex;

use tray_item::TrayItem;

static FLUTTER: Mutex<Option<Child>> = Mutex::new(None);
static GODOT: Mutex<Option<Child>> = Mutex::new(None);

fn env_or(key: &str, default: &str) -> String {
    std::env::var(key).unwrap_or_else(|_| default.to_string())
}

fn spawn_flutter() -> Result<(), String> {
    let mut guard = FLUTTER.lock().map_err(|e| e.to_string())?;
    if guard.as_mut().map_or(false, |c| c.try_wait().ok().flatten().is_none()) {
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

fn spawn_godot() -> Result<(), String> {
    let mut guard = GODOT.lock().map_err(|e| e.to_string())?;
    if guard.as_mut().map_or(false, |c| c.try_wait().ok().flatten().is_none()) {
        return Ok(());
    }
    let bin = env_or("ANIMA_GODOT_BIN", "godot");
    let dir = env_or("ANIMA_GODOT_DIR", "godot");
    let args: Vec<String> = env_or("ANIMA_GODOT_ARGS", "")
        .split_whitespace()
        .map(str::to_string)
        .collect();
    let mut cmd = Command::new(&bin);
    if args.is_empty() {
        cmd.arg("--path").arg(&dir);
    } else {
        cmd.args(&args);
    }
    let child = cmd
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| format!("godot spawn failed: {e}"))?;
    eprintln!("anima-supervisor: started godot (pid {})", child.id());
    *guard = Some(child);
    Ok(())
}

fn stop_godot() {
    if let Ok(mut guard) = GODOT.lock() {
        if let Some(mut c) = guard.take() {
            let _ = c.kill();
            let _ = c.wait();
            eprintln!("anima-supervisor: stopped godot");
        }
    }
}

fn restart_godot() {
    stop_godot();
    let _ = spawn_godot();
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
    stop_godot();
    std::process::exit(0);
}

fn main() {
    eprintln!("anima-supervisor: starting (tray owner; daemon owns port 6121)");
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
        tray.add_menu_item("Start Godot Pet", || {
            let _ = spawn_godot();
        })?;
        tray.add_menu_item("Stop Godot Pet", || stop_godot())?;
        tray.add_menu_item("Restart Godot Pet", || restart_godot())?;
        tray.add_menu_item("Start Core (systemd)", || start_core())?;
        tray.add_menu_item("Quit", || quit())?;
        Ok(())
    })();
    match result {
        Ok(()) => {
            eprintln!("anima-supervisor: tray registered");
            // Keep the process alive.
            loop {
                std::thread::sleep(std::time::Duration::from_secs(3600));
            }
        }
        Err(e) => eprintln!("anima-supervisor: tray menu build failed: {e}"),
    }
}
