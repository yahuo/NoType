//! `~/.config/notype/config.toml`, mirroring the macOS `AppSettings` that apply on Linux.
//!
//! The Doubao access token is read from the Secret Service first:
//! `secret-tool store --label='NoType Doubao' application notype account doubao.access-token`.
//! `doubao.access_token` in the file is a fallback for systems without a keyring.

use std::path::Path;

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::paths;
use crate::status::SpeechProvider;

pub const DEFAULT_RESOURCE_ID: &str = "volc.seedasr.sauc.duration";
pub const SECRET_APPLICATION: &str = "notype";
pub const SECRET_ACCOUNT: &str = "doubao.access-token";
const LANGUAGES: [&str; 5] = ["zh-CN", "en-US", "zh-TW", "ja-JP", "ko-KR"];
const KEYRING_LOOKUP_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub speech_provider: SpeechProvider,
    /// BCP 47 dictation language: zh-CN, en-US, zh-TW, ja-JP or ko-KR.
    pub language: String,
    /// Rewrite Doubao transcripts with Codex before pasting (`llmRefinementEnabled`).
    pub ai_rewrite: bool,
    pub doubao: DoubaoSettings,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct DoubaoSettings {
    pub app_id: String,
    pub resource_id: String,
    pub access_token: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            speech_provider: SpeechProvider::Codex,
            language: "zh-CN".into(),
            ai_rewrite: false,
            doubao: DoubaoSettings::default(),
        }
    }
}

impl Default for DoubaoSettings {
    fn default() -> Self {
        Self {
            app_id: String::new(),
            resource_id: DEFAULT_RESOURCE_ID.into(),
            access_token: String::new(),
        }
    }
}

impl Config {
    pub fn load() -> Result<Self> {
        Self::load_from(&paths::config_file())
    }

    /// A missing file means defaults; an unreadable or invalid one is an error.
    pub fn load_from(path: &Path) -> Result<Self> {
        let text = match std::fs::read_to_string(path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Self::default()),
            Err(error) => return Err(error).with_context(|| format!("failed to read {}", path.display())),
        };
        Self::parse(&text).with_context(|| format!("invalid {}", path.display()))
    }

    pub fn parse(text: &str) -> Result<Self> {
        let mut config: Config = toml::from_str(text)?;
        if !LANGUAGES.contains(&config.language.as_str()) {
            anyhow::bail!("unsupported language {:?}; use one of {}", config.language, LANGUAGES.join(", "));
        }
        if config.doubao.resource_id.trim().is_empty() {
            config.doubao.resource_id = DEFAULT_RESOURCE_ID.into();
        }
        Ok(config)
    }

    pub fn uses_chinese_copy(&self) -> bool {
        matches!(self.language.as_str(), "zh-CN" | "zh-TW")
    }

    pub fn has_valid_doubao_configuration(&self) -> bool {
        !self.doubao.app_id.trim().is_empty() && !self.doubao.resource_id.trim().is_empty()
    }

    pub fn should_rewrite_dictation(&self) -> bool {
        self.speech_provider == SpeechProvider::Doubao && self.ai_rewrite
    }

    pub fn text(&self, zh: &str, en: &str) -> String {
        if self.uses_chinese_copy() { zh.into() } else { en.into() }
    }
}

/// Keyring token first, then the config fallback. Returns an empty string when neither is set.
pub async fn doubao_access_token(config: &Config) -> String {
    match keyring_token().await {
        Some(token) => token,
        None => config.doubao.access_token.trim().to_owned(),
    }
}

/// The Doubao token stored in the Secret Service, if any.
/// A locked keyring shows an unlock prompt; give up if nobody answers it.
pub async fn keyring_token() -> Option<String> {
    let lookup = tokio::process::Command::new("secret-tool")
        .args(["lookup", "application", SECRET_APPLICATION, "account", SECRET_ACCOUNT])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let output = tokio::time::timeout(KEYRING_LOOKUP_TIMEOUT, lookup).await.ok()?.ok()?;
    let token = String::from_utf8_lossy(&output.stdout).trim().to_owned();
    (output.status.success() && !token.is_empty()).then_some(token)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_file_uses_macos_defaults() {
        let config = Config::parse("").unwrap();
        assert_eq!(config, Config::default());
        assert_eq!(config.speech_provider, SpeechProvider::Codex);
        assert!(!config.should_rewrite_dictation());
        assert!(config.uses_chinese_copy());
    }

    #[test]
    fn rewrite_applies_only_to_doubao() {
        let config = Config::parse("speech_provider = \"codex\"\nai_rewrite = true").unwrap();
        assert!(!config.should_rewrite_dictation());
        let config = Config::parse("speech_provider = \"doubao\"\nai_rewrite = true\n[doubao]\napp_id = \"1\"").unwrap();
        assert!(config.should_rewrite_dictation());
        assert!(config.has_valid_doubao_configuration());
    }

    #[test]
    fn blank_resource_id_falls_back_and_bad_values_fail() {
        let config = Config::parse("[doubao]\nresource_id = \" \"").unwrap();
        assert_eq!(config.doubao.resource_id, DEFAULT_RESOURCE_ID);
        assert!(Config::parse("language = \"fr-FR\"").is_err());
        assert!(Config::parse("speech_provider = \"whisper\"").is_err());
        assert!(Config::parse("unknown = 1").is_err());
    }
}
