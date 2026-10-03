//! Doubao streaming ASR over WebSocket.
//! OWNER: agent B. Port of DoubaoStreamingASRProvider.swift.

use tokio::sync::mpsc::UnboundedSender;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DoubaoConfig {
    pub app_id: String,
    pub access_token: String,
    pub resource_id: String,
    pub user_id: String,
    /// BCP 47 tag such as `zh-CN`.
    pub language: String,
    pub workflow: String,
    pub utterance_mode: bool,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AsrEvent {
    Partial(String),
    Final(String),
    Error(String),
}

pub struct DoubaoSession {}

impl DoubaoSession {
    pub async fn start(_config: DoubaoConfig, _events: UnboundedSender<AsrEvent>) -> anyhow::Result<Self> {
        todo!()
    }

    /// `pcm` is 16 kHz mono signed 16-bit little-endian audio.
    pub async fn send_audio(&self, _pcm: Vec<u8>, _is_final: bool) -> anyhow::Result<()> {
        todo!()
    }

    pub async fn finish(&self) -> anyhow::Result<()> {
        todo!()
    }

    pub fn cancel(&self) {}
}

/// Opens and closes a session to validate credentials.
pub async fn test_connection(_config: DoubaoConfig) -> anyhow::Result<()> {
    todo!()
}
