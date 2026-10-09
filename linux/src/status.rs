//! State published to `notype status --follow` (JSON Lines) for the Omarchy shell plugin.
//!
//! Every line is a complete snapshot of one `type`; subscribers receive the current
//! `status` and `selection` snapshots on connect, then a line whenever either changes.

use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Phase {
    #[default]
    Idle,
    Recording,
    Transcribing,
    Refining,
    Failed,
    Inserted,
    CopiedToClipboard,
}

impl Phase {
    pub fn hud_visible(self) -> bool {
        !matches!(self, Phase::Idle)
    }

    pub fn is_busy(self) -> bool {
        matches!(
            self,
            Phase::Recording | Phase::Transcribing | Phase::Refining
        )
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputMode {
    #[default]
    Dictation,
    Translation,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SpeechProvider {
    #[default]
    Codex,
    Doubao,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct StatusSnapshot {
    pub phase: Phase,
    pub mode: OutputMode,
    pub provider: SpeechProvider,
    /// Live transcript, rewrite or translation preview.
    pub transcript: String,
    /// Smoothed input level in `0.0..=1.0` while recording.
    pub level: f64,
    pub error: Option<String>,
    pub warning: Option<String>,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SelectionState {
    #[default]
    Hidden,
    Translating,
    Done,
    Failed,
}

/// Selected text translated to Chinese, shown in a floating panel without touching the source.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct SelectionSnapshot {
    pub state: SelectionState,
    pub source: String,
    pub translation: String,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum StatusEvent {
    Status(StatusSnapshot),
    Selection(SelectionSnapshot),
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_line_shape() {
        let line = serde_json::to_string(&StatusEvent::Status(StatusSnapshot {
            phase: Phase::CopiedToClipboard,
            ..Default::default()
        }))
        .unwrap();
        assert_eq!(
            line,
            r#"{"type":"status","phase":"copied_to_clipboard","mode":"dictation","provider":"codex","transcript":"","level":0.0,"error":null,"warning":null}"#
        );
    }
}
