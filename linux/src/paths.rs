//! Runtime and configuration locations shared by the daemon, CLI and bridge clients.

use std::fs;
use std::io;
use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
use std::path::PathBuf;

const APP_DIR: &str = "notype";

/// `$XDG_RUNTIME_DIR/notype`, falling back to a per-user directory under `/tmp`.
pub fn runtime_dir() -> PathBuf {
    match std::env::var_os("XDG_RUNTIME_DIR").filter(|value| !value.is_empty()) {
        Some(base) => PathBuf::from(base).join(APP_DIR),
        None => std::env::temp_dir().join(format!("{APP_DIR}-{}", unsafe { libc::geteuid() })),
    }
}

/// Creates the runtime directory with mode `0700` and rejects one owned by another user.
pub fn ensure_private_runtime_dir() -> io::Result<PathBuf> {
    let dir = runtime_dir();
    fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    let metadata = fs::symlink_metadata(&dir)?;
    if !metadata.is_dir() || std::os::unix::fs::MetadataExt::uid(&metadata) != unsafe { libc::geteuid() } {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!("{} is not a directory owned by the current user", dir.display()),
        ));
    }
    fs::set_permissions(&dir, fs::Permissions::from_mode(0o700))?;
    Ok(dir)
}

/// Bridge socket for Pi, the editor proxy and the browser host. `NOTYPE_BRIDGE_SOCKET` wins.
pub fn bridge_socket() -> PathBuf {
    match std::env::var_os("NOTYPE_BRIDGE_SOCKET").filter(|value| !value.is_empty()) {
        Some(path) => PathBuf::from(path),
        None => runtime_dir().join("bridge.sock"),
    }
}

/// Lock file that keeps a second daemon from unlinking the active bridge socket.
pub fn bridge_lock() -> PathBuf {
    runtime_dir().join("bridge.lock")
}

/// Held by the running daemon for its whole lifetime.
pub fn daemon_lock() -> PathBuf {
    runtime_dir().join("daemon.lock")
}

/// Control socket used by the `notype` CLI, Hyprland bindings and the shell plugin.
pub fn control_socket() -> PathBuf {
    runtime_dir().join("control.sock")
}

/// Single-use trigger written before the daemon asks a terminal agent to open `$VISUAL`.
pub fn editor_trigger_file() -> PathBuf {
    runtime_dir().join("editor-trigger.json")
}

/// `$XDG_CONFIG_HOME/notype/config.toml`, defaulting to `~/.config`.
pub fn config_file() -> PathBuf {
    config_home().join(APP_DIR).join("config.toml")
}

fn config_home() -> PathBuf {
    if let Some(base) = std::env::var_os("XDG_CONFIG_HOME").filter(|value| !value.is_empty()) {
        return PathBuf::from(base);
    }
    home_dir().join(".config")
}

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/"))
}
