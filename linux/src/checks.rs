//! Environment checks shared by `notype doctor` and the setup page of the Omarchy plugin.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;

use serde::Serialize;

use crate::codex_auth::CodexAuthStore;
use crate::config::{self, Config};
use crate::control;
use crate::paths;
use crate::status::{SpeechProvider, StatusEvent};

/// Needed by wl-clipboard and hyprctl.
pub const SESSION_VARIABLES: [&str; 2] = ["WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"];

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Check {
    pub label: String,
    pub ok: bool,
    /// A failed required check keeps NoType from working; a failed optional one only limits it.
    pub required: bool,
    pub detail: String,
}

impl Check {
    fn new(ok: bool, required: bool, label: &str, detail: impl Into<String>) -> Self {
        Self { label: label.into(), ok, required, detail: detail.into() }
    }
}

pub fn ready(checks: &[Check]) -> bool {
    checks.iter().all(|check| check.ok || !check.required)
}

/// Runs every check in a fixed order. `config` is the result of `Config::load`.
pub async fn run(config: &anyhow::Result<Config>) -> Vec<Check> {
    let mut checks = Vec::new();
    for (program, package, required) in [
        ("pw-record", "pipewire", true),
        ("wl-copy", "wl-clipboard", true),
        ("wl-paste", "wl-clipboard", true),
        ("hyprctl", "hyprland", true),
        ("secret-tool", "libsecret (Doubao token in the keyring)", false),
    ] {
        let found = on_path(program);
        checks.push(Check::new(found, required, program, if found { "found".into() } else { format!("missing; install {package}") }));
    }
    for variable in SESSION_VARIABLES {
        let value = std::env::var(variable).unwrap_or_default();
        checks.push(Check::new(!value.is_empty(), true, variable, if value.is_empty() { "not set".into() } else { value }));
    }

    let path = paths::config_file();
    let config = match config {
        Ok(config) => {
            let detail = if path.exists() {
                path.display().to_string()
            } else {
                format!("{} not found, using defaults", path.display())
            };
            checks.push(Check::new(true, true, "config", detail));
            config.clone()
        }
        Err(error) => {
            checks.push(Check::new(false, true, "config", format!("{error:#}")));
            Config::default()
        }
    };
    let codex = CodexAuthStore::new(None).load();
    checks.push(Check::new(
        codex.is_ok(),
        config.speech_provider == SpeechProvider::Codex,
        "codex login",
        codex.map(|_| "credentials found".into()).unwrap_or_else(|error| error.to_string()),
    ));
    if config.speech_provider == SpeechProvider::Doubao {
        let token = config::doubao_access_token(&config).await;
        let complete = config.has_valid_doubao_configuration() && !token.is_empty();
        checks.push(Check::new(complete, true, "doubao", if complete { "configured" } else { "set app_id and the access token" }));
    }

    // The service may run with a different environment than this process, so ask it directly.
    let mut lines = Vec::new();
    checks.push(match control::copy_status(false, &mut lines).await {
        Ok(()) => {
            let warning = String::from_utf8_lossy(&lines)
                .lines()
                .filter_map(|line| serde_json::from_str::<StatusEvent>(line).ok())
                .find_map(|event| match event {
                    StatusEvent::Status(status) => status.warning,
                    StatusEvent::Selection(_) => None,
                });
            match warning {
                Some(warning) => Check::new(false, true, "daemon", warning),
                None => Check::new(true, false, "daemon", paths::control_socket().display().to_string()),
            }
        }
        Err(error) => Check::new(false, false, "daemon", format!("{error:#}")),
    });
    checks
}

pub fn on_path(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| is_executable(&dir.join(program)))
    })
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}
