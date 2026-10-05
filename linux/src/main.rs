//! `notype`: the Omarchy daemon and the CLI that Hyprland bindings and the shell plugin call.

use std::os::unix::fs::PermissionsExt;
use std::path::Path;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::Result;
use clap::{Parser, Subcommand};
use notype::agent_editor::AgentEditorTriggers;
use notype::app::App;
use notype::bridge::{BridgeHandler, BridgeServer};
use notype::codex_auth::CodexAuthStore;
use notype::codex_transcription::CodexTranscriptionService;
use notype::config::{self, Config};
use notype::control::{self, ControlRequest, ControlServer, DaemonLock};
use notype::paths;
use notype::rewrite::AiRewriteService;
use notype::status::{SpeechProvider, StatusEvent};
use tokio::signal::unix::{SignalKind, signal};

/// Needed by wl-clipboard and hyprctl.
const SESSION_VARIABLES: [&str; 2] = ["WAYLAND_DISPLAY", "HYPRLAND_INSTANCE_SIGNATURE"];

#[derive(Parser)]
#[command(name = "notype", version, about = "NoType voice input for Omarchy")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Run the background service (normally started by `systemctl --user start notype`).
    Daemon,
    /// Dictation: `toggle` matches the Alt+Space hotkey.
    Record {
        #[command(subcommand)]
        action: RecordAction,
    },
    /// Replace the selection with English, or dictate and paste English.
    Translate,
    /// Cancel the current session and close the selection panel.
    Cancel,
    /// Translate the draft of Pi, Claude Code or Codex in the focused terminal.
    AgentTranslate,
    /// Translate the selection to Chinese in a floating panel.
    SelectionChinese,
    /// Close the Chinese translation panel.
    SelectionHide,
    /// Copy the finished Chinese translation.
    SelectionCopy,
    /// Print status as JSON Lines; `--follow` keeps streaming changes.
    Status {
        #[arg(long)]
        follow: bool,
    },
    /// Check dependencies, configuration, credentials and the daemon.
    Doctor,
}

#[derive(Subcommand)]
enum RecordAction {
    Toggle,
    Start,
    Stop,
}

#[tokio::main]
async fn main() -> ExitCode {
    let cli = Cli::parse();
    let result = match cli.command {
        Command::Daemon => run_daemon().await,
        Command::Status { follow } => control::copy_status(follow, &mut tokio::io::stdout()).await,
        Command::Doctor => doctor().await,
        command => control::send(&request(command)).await,
    };
    match result {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("notype: {error:#}");
            ExitCode::FAILURE
        }
    }
}

fn request(command: Command) -> ControlRequest {
    match command {
        Command::Record { action: RecordAction::Toggle } => ControlRequest::RecordToggle,
        Command::Record { action: RecordAction::Start } => ControlRequest::RecordStart,
        Command::Record { action: RecordAction::Stop } => ControlRequest::RecordStop,
        Command::Translate => ControlRequest::Translate,
        Command::Cancel => ControlRequest::Cancel,
        Command::AgentTranslate => ControlRequest::AgentTranslate,
        Command::SelectionChinese => ControlRequest::SelectionChinese,
        Command::SelectionHide => ControlRequest::SelectionHide,
        Command::SelectionCopy => ControlRequest::SelectionCopy,
        Command::Daemon | Command::Status { .. } | Command::Doctor => unreachable!("handled in main"),
    }
}

async fn run_daemon() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "notype=info".into()),
        )
        .with_writer(std::io::stderr)
        .init();

    let _lock = DaemonLock::acquire()?;
    let auth = CodexAuthStore::new(None);
    let ai = Arc::new(AiRewriteService::new(auth.clone()));
    let transcription = Arc::new(CodexTranscriptionService::new(auth));
    let editor = Arc::new(AgentEditorTriggers::new());
    let app = App::new(ai.clone(), transcription, editor.clone());

    let mut warnings = Vec::new();
    // A systemd user service only sees these after the session imports them.
    let missing: Vec<_> = SESSION_VARIABLES
        .into_iter()
        .filter(|variable| std::env::var_os(variable).is_none_or(|value| value.is_empty()))
        .collect();
    if !missing.is_empty() {
        let missing = missing.join(" ");
        tracing::warn!("session environment is missing {missing}");
        warnings.push(format!(
            "NoType cannot reach Hyprland: {missing} not set. Run `systemctl --user import-environment {missing}` and restart notype."
        ));
    }
    let bridge = match BridgeServer::start(Arc::new(BridgeHandler::new(ai, editor.clone(), app.clone()))) {
        Ok(bridge) => Some(bridge),
        Err(error) => {
            tracing::warn!("bridge unavailable: {error:#}");
            warnings.push(format!("NoType bridge is unavailable: {error:#}"));
            None
        }
    };
    if !warnings.is_empty() {
        app.set_warning(Some(warnings.join("\n")));
    }
    let control = ControlServer::bind(app.clone())?;
    tracing::info!(socket = %paths::control_socket().display(), "NoType ready");

    let mut terminate = signal(SignalKind::terminate())?;
    let mut interrupt = signal(SignalKind::interrupt())?;
    tokio::select! {
        _ = terminate.recv() => {}
        _ = interrupt.recv() => {}
    }

    control.shutdown();
    app.shutdown();
    if let Some(bridge) = bridge {
        bridge.shutdown();
    }
    editor.shutdown();
    Ok(())
}

async fn doctor() -> Result<()> {
    let mut healthy = true;
    let mut report = |ok: bool, required: bool, label: &str, detail: String| {
        let mark = if ok { "ok  " } else if required { "FAIL" } else { "warn" };
        println!("{mark} {label}: {detail}");
        healthy &= ok || !required;
    };

    for (program, package, required) in [
        ("pw-record", "pipewire", true),
        ("wl-copy", "wl-clipboard", true),
        ("wl-paste", "wl-clipboard", true),
        ("hyprctl", "hyprland", true),
        ("secret-tool", "libsecret (Doubao token in the keyring)", false),
    ] {
        let found = on_path(program);
        report(found, required, program, if found { "found".into() } else { format!("missing; install {package}") });
    }
    for variable in SESSION_VARIABLES {
        let value = std::env::var(variable).unwrap_or_default();
        report(!value.is_empty(), true, variable, if value.is_empty() { "not set".into() } else { value });
    }

    let config = match Config::load() {
        Ok(config) => {
            let path = paths::config_file();
            let detail = if path.exists() {
                path.display().to_string()
            } else {
                format!("{} not found, using defaults", path.display())
            };
            report(true, true, "config", detail);
            config
        }
        Err(error) => {
            report(false, true, "config", format!("{error:#}"));
            Config::default()
        }
    };
    let codex = CodexAuthStore::new(None).load();
    report(
        codex.is_ok(),
        config.speech_provider == SpeechProvider::Codex,
        "codex login",
        codex.map(|_| "credentials found".into()).unwrap_or_else(|error| error.to_string()),
    );
    if config.speech_provider == SpeechProvider::Doubao {
        let token = config::doubao_access_token(&config).await;
        let complete = config.has_valid_doubao_configuration() && !token.is_empty();
        report(complete, true, "doubao", if complete { "configured".into() } else { "set app_id and the access token".into() });
    }

    // The service may run with a different environment than this shell, so ask it directly.
    let mut lines = Vec::new();
    match control::copy_status(false, &mut lines).await {
        Ok(()) => {
            let warning = String::from_utf8_lossy(&lines)
                .lines()
                .filter_map(|line| serde_json::from_str::<StatusEvent>(line).ok())
                .find_map(|event| match event {
                    StatusEvent::Status(status) => status.warning,
                    StatusEvent::Selection(_) => None,
                });
            match warning {
                Some(warning) => report(false, true, "daemon", warning),
                None => report(true, false, "daemon", paths::control_socket().display().to_string()),
            }
        }
        Err(error) => report(false, false, "daemon", format!("{error:#}")),
    }

    if healthy { Ok(()) } else { anyhow::bail!("some required checks failed") }
}

fn on_path(program: &str) -> bool {
    std::env::var_os("PATH").is_some_and(|path| {
        std::env::split_paths(&path).any(|dir| is_executable(&dir.join(program)))
    })
}

fn is_executable(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}
