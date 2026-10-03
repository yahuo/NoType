//! Codex dictation upload (`/backend-api/transcribe`).
//! OWNER: agent A. Port of CodexTranscriptionService.swift.

use crate::codex_auth::CodexAuthStore;
use crate::rewrite::AiError;

pub struct CodexTranscriptionService {
    pub auth: CodexAuthStore,
}

impl CodexTranscriptionService {
    pub fn new(auth: CodexAuthStore) -> Self {
        Self { auth }
    }

    pub fn check_credentials(&self) -> Result<(), AiError> {
        todo!()
    }

    /// `pcm` is 16 kHz mono signed 16-bit little-endian audio.
    pub async fn transcribe(&self, _pcm: Vec<u8>) -> anyhow::Result<String> {
        todo!()
    }
}
