//! Thin Hyprland IPC helpers built on `hyprctl`.
//!
//! Shortcuts are sent the same way Omarchy's universal clipboard bindings do: an explicit-mods
//! `send_key_state` down, then up after 50 ms. A virtual keyboard (wtype) would merge physically
//! held modifiers into the chord, and the split works around stuck synthetic key state.

use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::Deserialize;
use tokio::process::Command;

#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
pub struct ActiveWindow {
    #[serde(default)]
    pub address: String,
    #[serde(default)]
    pub pid: i32,
    #[serde(default)]
    pub class: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub tags: Vec<String>,
}

impl ActiveWindow {
    /// Omarchy tags terminals in `default/hypr/apps/terminals.lua`; dynamic tags end in `*`.
    pub fn is_terminal(&self) -> bool {
        self.tags
            .iter()
            .any(|tag| tag.trim_end_matches('*') == "terminal")
    }

    /// Same window instance, not just the same application.
    pub fn same_window(&self, other: &ActiveWindow) -> bool {
        !self.address.is_empty() && self.address == other.address && self.pid == other.pid
    }
}

/// The focused window, or `None` when nothing has focus (for example an empty workspace).
pub async fn active_window() -> Result<Option<ActiveWindow>> {
    let output = Command::new("hyprctl")
        .args(["activewindow", "-j"])
        .output()
        .await
        .context("failed to run hyprctl")?;
    if !output.status.success() {
        bail!(
            "hyprctl activewindow failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    parse_active_window(&output.stdout)
}

fn parse_active_window(json: &[u8]) -> Result<Option<ActiveWindow>> {
    let window: ActiveWindow =
        serde_json::from_slice(json).context("invalid hyprctl activewindow JSON")?;
    Ok((!window.address.is_empty()).then_some(window))
}

/// Sends `mods + key` to the focused surface, e.g. `send_shortcut("CTRL", "V")`.
/// Returns after the key-up has been scheduled and delivered.
pub async fn send_shortcut(mods: &str, key: &str) -> Result<()> {
    let lua = shortcut_lua(mods, key)?;
    let output = Command::new("hyprctl")
        .args(["eval", &lua])
        .output()
        .await
        .context("failed to run hyprctl")?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    if !output.status.success() || !stdout.trim().eq_ignore_ascii_case("ok") {
        bail!(
            "hyprctl eval failed: {}{}",
            stdout.trim(),
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    // The key-up fires from a 50 ms Hyprland timer; let it land before callers continue.
    tokio::time::sleep(Duration::from_millis(80)).await;
    Ok(())
}

fn shortcut_lua(mods: &str, key: &str) -> Result<String> {
    let safe = |value: &str| {
        value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b' ' || byte == b'_')
    };
    if key.is_empty() || !safe(mods) || !safe(key) {
        bail!("unsupported shortcut {mods:?} + {key:?}");
    }
    Ok(format!(
        "hl.dispatch(hl.dsp.send_key_state({{ mods = \"{mods}\", key = \"{key}\", state = \"down\" }})) \
         hl.timer(function() hl.dispatch(hl.dsp.send_key_state({{ mods = \"{mods}\", key = \"{key}\", state = \"up\" }})) end, \
         {{ timeout = 50, type = \"oneshot\" }})"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_terminal_window() {
        let json = br#"{"address":"0x61","pid":42,"class":"com.mitchellh.ghostty","title":"t","tags":["default-opacity*","terminal*"]}"#;
        let window = parse_active_window(json).unwrap().unwrap();
        assert!(window.is_terminal());
        assert!(window.same_window(&window.clone()));
    }

    #[test]
    fn empty_object_means_no_focus() {
        assert!(parse_active_window(b"{}").unwrap().is_none());
    }

    #[test]
    fn rejects_lua_injection() {
        assert!(shortcut_lua("CTRL", "V").is_ok());
        assert!(shortcut_lua("CTRL\"", "V").is_err());
        assert!(shortcut_lua("CTRL", "V) os.exit(").is_err());
    }
}
