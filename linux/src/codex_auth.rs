//! Codex OAuth credentials read from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
//! OWNER: agent A. Port of `CodexOAuthCredentials` / `CodexAuthStore` in AIRewriteService.swift.

use std::path::PathBuf;
use std::time::SystemTime;

use crate::rewrite::AiError;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CodexCredentials {
    pub access_token: String,
    pub account_id: Option<String>,
    pub expires_at: Option<SystemTime>,
}

impl CodexCredentials {
    pub fn is_expired(&self) -> bool {
        todo!()
    }
}

#[derive(Clone, Debug, Default)]
pub struct CodexAuthStore {
    pub codex_home: Option<PathBuf>,
}

impl CodexAuthStore {
    pub fn new(codex_home: Option<PathBuf>) -> Self {
        Self { codex_home }
    }

    pub fn load(&self) -> Result<CodexCredentials, AiError> {
        todo!()
    }

    pub fn has_credentials(&self) -> bool {
        self.load().is_ok()
    }
}
