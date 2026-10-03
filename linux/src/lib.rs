//! NoType for Omarchy: a Hyprland/Wayland port of the macOS menu bar app.

pub mod agent_editor;
pub mod app;
pub mod audio;
pub mod bridge;
pub mod codex_auth;
pub mod codex_transcription;
pub mod config;
pub mod control;
pub mod doubao;
pub mod editor;
pub mod hyprland;
pub mod insertion;
pub mod paths;
pub mod protocol;
pub mod rewrite;
pub mod status;
pub mod transcript;

/// Receives the accumulated streaming output of a rewrite or translation.
pub type PartialCallback = std::sync::Arc<dyn Fn(String) + Send + Sync>;
