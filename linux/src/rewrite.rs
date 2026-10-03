//! Codex Responses (SSE) rewrite and translation.
//! OWNER: agent A. Port of AIRewriteService.swift.

use crate::PartialCallback;
use crate::codex_auth::CodexAuthStore;
use crate::protocol::TranslationItem;

#[derive(Debug, thiserror::Error)]
pub enum AiError {
    #[error("Codex OAuth is not configured. Run `codex login` in Terminal first.")]
    MissingCodexAuth,
}

pub struct AiRewriteService {
    pub auth: CodexAuthStore,
}

impl AiRewriteService {
    pub fn new(auth: CodexAuthStore) -> Self {
        Self { auth }
    }

    pub fn has_credentials(&self) -> bool {
        self.auth.has_credentials()
    }

    pub async fn prewarm(&self) {}

    pub async fn rewrite(&self, _text: &str, _on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        todo!()
    }

    pub async fn translate_to_english(&self, _text: &str, _on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        todo!()
    }

    pub async fn translate_to_chinese(&self, _text: &str, _on_partial: Option<PartialCallback>) -> Result<String, AiError> {
        todo!()
    }

    pub async fn translate_browser_batch(
        &self,
        _items: &[TranslationItem],
        _on_partial: Option<PartialCallback>,
    ) -> Result<Vec<TranslationItem>, AiError> {
        todo!()
    }
}
