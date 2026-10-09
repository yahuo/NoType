//! `notype`: the Omarchy daemon and the CLI that Hyprland bindings and the shell plugin call.

use std::io::IsTerminal;
use std::process::ExitCode;
use std::sync::Arc;

use anyhow::Result;
use clap::{Parser, Subcommand, ValueEnum};
use notype::agent_editor::AgentEditorTriggers;
use notype::app::App;
use notype::bridge::{BridgeHandler, BridgeServer};
use notype::checks::{self, SESSION_VARIABLES};
use notype::codex_auth::CodexAuthStore;
use notype::codex_transcription::CodexTranscriptionService;
use notype::config::Config;
use notype::control::{self, ControlRequest, ControlServer, DaemonLock};
use notype::paths;
use notype::rewrite::AiRewriteService;
use notype::settings::{self, Outcome};
use tokio::signal::unix::{SignalKind, signal};

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
    /// Backend of the Omarchy settings page; prints JSON.
    Settings {
        #[command(subcommand)]
        action: SettingsAction,
    },
}

#[derive(Subcommand)]
enum SettingsAction {
    /// Print settings, credential state, hotkeys and checks.
    Get,
    /// Save one JSON line read from stdin, so the access token stays out of argv.
    Set,
    /// Test a connection with the draft settings read as one JSON line from stdin.
    Test { target: TestTarget },
}

#[derive(Clone, Copy, ValueEnum)]
enum TestTarget {
    Speech,
    AiRewrite,
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
        Command::Settings { action } => settings_command(action).await,
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
        Command::Record {
            action: RecordAction::Toggle,
        } => ControlRequest::RecordToggle,
        Command::Record {
            action: RecordAction::Start,
        } => ControlRequest::RecordStart,
        Command::Record {
            action: RecordAction::Stop,
        } => ControlRequest::RecordStop,
        Command::Translate => ControlRequest::Translate,
        Command::Cancel => ControlRequest::Cancel,
        Command::AgentTranslate => ControlRequest::AgentTranslate,
        Command::SelectionChinese => ControlRequest::SelectionChinese,
        Command::SelectionHide => ControlRequest::SelectionHide,
        Command::SelectionCopy => ControlRequest::SelectionCopy,
        Command::Daemon | Command::Status { .. } | Command::Doctor | Command::Settings { .. } => {
            unreachable!("handled in main")
        }
    }
}

async fn run_daemon() -> Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "notype=info".into()),
        )
        .with_writer(std::io::stderr)
        // journald stores escape codes verbatim.
        .with_ansi(std::io::stderr().is_terminal())
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
    let bridge = match BridgeServer::start(Arc::new(BridgeHandler::new(
        ai,
        editor.clone(),
        app.clone(),
    ))) {
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
    let checks = checks::run(&Config::load()).await;
    for check in &checks {
        let mark = if check.ok {
            "ok  "
        } else if check.required {
            "FAIL"
        } else {
            "warn"
        };
        println!("{mark} {}: {}", check.label, check.detail);
    }
    if checks::ready(&checks) {
        Ok(())
    } else {
        anyhow::bail!("some required checks failed")
    }
}

async fn settings_command(action: SettingsAction) -> Result<()> {
    let outcome = match action {
        SettingsAction::Get => {
            println!("{}", serde_json::to_string(&settings::snapshot().await)?);
            return Ok(());
        }
        SettingsAction::Set => match settings::read_draft().await {
            Ok(draft) => settings::save(draft).await,
            Err(error) => Outcome::failed(format!("{error:#}")),
        },
        SettingsAction::Test {
            target: TestTarget::Speech,
        } => match settings::read_draft().await {
            Ok(draft) => settings::test_speech(draft).await,
            Err(error) => Outcome::failed(format!("{error:#}")),
        },
        SettingsAction::Test {
            target: TestTarget::AiRewrite,
        } => settings::test_ai_rewrite().await,
    };
    println!("{}", serde_json::to_string(&outcome)?);
    match outcome.error {
        Some(error) if !outcome.ok => anyhow::bail!(error),
        _ => Ok(()),
    }
}
