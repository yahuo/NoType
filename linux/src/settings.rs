//! `notype settings`: the backend of the Omarchy settings page, which mirrors the macOS Settings
//! window. It runs in the CLI process and edits `config.toml` in place; the daemon reads the file
//! again for every session, so only the provider shown in the status needs a reload.
//!
//! Drafts arrive as one JSON line on stdin so the Doubao access token never appears in argv.

use std::io::Write;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::process::Command;
use toml_edit::{DocumentMut, Item, TableLike, Value};

use crate::checks::{self, Check};
use crate::codex_auth::CodexAuthStore;
use crate::codex_transcription::CodexTranscriptionService;
use crate::config::{self, Config, SECRET_ACCOUNT, SECRET_APPLICATION};
use crate::control::{self, ControlRequest};
use crate::doubao::{self, DoubaoConfig};
use crate::paths;
use crate::rewrite::AiRewriteService;
use crate::status::SpeechProvider;

/// Written when no config exists yet, so a first save keeps the documented layout.
const TEMPLATE: &str = include_str!("../../integrations/omarchy/config.example.toml");
const MAX_DRAFT_BYTES: u64 = 64 * 1024;
/// A locked keyring shows a password prompt; give the user time to answer it.
const KEYRING_TIMEOUT: Duration = Duration::from_secs(60);
const HYPRCTL_TIMEOUT: Duration = Duration::from_secs(2);

/// Everything the settings page shows. The access token itself never leaves the CLI.
#[derive(Debug, Serialize)]
pub struct Snapshot {
    pub version: &'static str,
    pub config_path: String,
    pub config_error: Option<String>,
    pub speech_provider: SpeechProvider,
    pub language: String,
    pub ai_rewrite: bool,
    pub app_id: String,
    pub resource_id: String,
    pub access_token: TokenSource,
    pub codex_logged_in: bool,
    /// `hasASRCredentials` on macOS: the selected speech provider can be used.
    pub speech_ready: bool,
    pub hotkeys: Hotkeys,
    pub checks: Vec<Check>,
    /// Every required check passed (`permissionSnapshot.ready` on macOS).
    pub ready: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum TokenSource {
    Keyring,
    Config,
    None,
}

/// Display names such as `Alt + Shift + Space`; `None` when the binding is missing.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
pub struct Hotkeys {
    pub dictation: Option<String>,
    pub translation: Option<String>,
    pub selection: Option<String>,
    pub cancel: Option<String>,
    pub agent: Option<String>,
}

impl Default for Hotkeys {
    /// The bindings in `integrations/omarchy/hyprland.lua`.
    fn default() -> Self {
        Self {
            dictation: Some("Alt + Space".into()),
            translation: Some("Alt + Shift + Space".into()),
            selection: Some("Alt + Ctrl + Space".into()),
            cancel: Some("Alt + Esc".into()),
            agent: Some("Alt + Shift + T".into()),
        }
    }
}

/// Unsaved values from the settings page. Missing fields keep their saved value.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(default, deny_unknown_fields)]
pub struct Draft {
    pub speech_provider: Option<SpeechProvider>,
    pub language: Option<String>,
    pub ai_rewrite: Option<bool>,
    pub app_id: Option<String>,
    pub resource_id: Option<String>,
    /// Sent only after the user edits the field. An empty string removes the stored token.
    pub access_token: Option<String>,
}

/// Result of a save or a connection test, printed as one JSON line.
#[derive(Debug, PartialEq, Eq, Serialize)]
pub struct Outcome {
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub message: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub warning: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

impl Outcome {
    pub fn passed(message: String) -> Self {
        Self {
            ok: true,
            message: Some(message),
            warning: None,
            error: None,
        }
    }

    pub fn failed(error: String) -> Self {
        Self {
            ok: false,
            message: None,
            warning: None,
            error: Some(error),
        }
    }
}

pub async fn snapshot() -> Snapshot {
    let loaded = Config::load();
    let checks = checks::run(&loaded).await;
    let (config, config_error) = match loaded {
        Ok(config) => (config, None),
        Err(error) => (Config::default(), Some(format!("{error:#}"))),
    };
    let access_token = if config::keyring_token().await.is_some() {
        TokenSource::Keyring
    } else if !config.doubao.access_token.trim().is_empty() {
        TokenSource::Config
    } else {
        TokenSource::None
    };
    let codex_logged_in = CodexAuthStore::new(None).has_credentials();
    let speech_ready = match config.speech_provider {
        SpeechProvider::Codex => codex_logged_in,
        SpeechProvider::Doubao => {
            config.has_valid_doubao_configuration() && access_token != TokenSource::None
        }
    };
    Snapshot {
        version: env!("CARGO_PKG_VERSION"),
        config_path: paths::config_file().display().to_string(),
        config_error,
        speech_provider: config.speech_provider,
        language: config.language,
        ai_rewrite: config.ai_rewrite,
        app_id: config.doubao.app_id,
        resource_id: config.doubao.resource_id,
        access_token,
        codex_logged_in,
        speech_ready,
        hotkeys: hotkeys().await,
        ready: checks::ready(&checks),
        checks,
    }
}

/// Reads one JSON line from stdin. The settings page never closes stdin, so stop at the newline.
pub async fn read_draft() -> Result<Draft> {
    let mut line = String::new();
    BufReader::new(tokio::io::stdin().take(MAX_DRAFT_BYTES))
        .read_line(&mut line)
        .await?;
    if line.trim().is_empty() {
        return Ok(Draft::default());
    }
    serde_json::from_str(line.trim()).context("invalid settings draft")
}

/// `saveSettings` on macOS: writes the draft, then stores or removes the access token.
pub async fn save(draft: Draft) -> Outcome {
    match save_inner(&draft).await {
        Ok((config, warnings)) => {
            // The daemon may be stopped; it reads the new file when it starts.
            let _ = control::send(&ControlRequest::ReloadConfig).await;
            let mut outcome = Outcome::passed(config.text("设置已保存。", "Settings saved."));
            if draft.ai_rewrite == Some(true)
                && config.speech_provider == SpeechProvider::Doubao
                && !CodexAuthStore::new(None).has_credentials()
            {
                outcome.warning = Some(config.text(
                    "AI Rewrite 已启用，但未找到 Codex 登录态，当前会继续直接使用原始转写。",
                    "AI Rewrite is enabled but Codex is not logged in, so raw transcripts will still be used.",
                ));
            } else if !warnings.is_empty() {
                outcome.warning = Some(warnings.join("\n"));
            }
            outcome
        }
        Err(error) => Outcome::failed(format!("{error:#}")),
    }
}

async fn save_inner(draft: &Draft) -> Result<(Config, Vec<String>)> {
    let path = paths::config_file();
    let current = current_text(&path)?;
    // Validate before touching the keyring so a bad draft changes nothing.
    let (mut text, mut config) = apply(&current, draft, None)?;
    let mut warnings = Vec::new();
    let file_token = match draft.access_token.as_deref().map(str::trim) {
        None => None,
        Some("") => {
            // Clear both stores, or the file fallback would keep a token the user removed.
            clear_keyring().await;
            Some(String::new())
        }
        Some(token) => match store_keyring(token).await {
            Ok(()) => Some(String::new()),
            Err(error) => {
                tracing::warn!("keyring unavailable: {error:#}");
                warnings.push(config.text(
                    "未找到可用的 keyring，Access Token 已写入 config.toml。",
                    "No keyring is available, so the Access Token was saved in config.toml.",
                ));
                Some(token.to_owned())
            }
        },
    };
    if file_token.is_some() {
        (text, config) = apply(&current, draft, file_token.as_deref())?;
    }
    write_private(&path, &text)?;
    Ok((config, warnings))
}

/// `testASRConnection` on macOS, using the draft instead of the saved values.
pub async fn test_speech(draft: Draft) -> Outcome {
    let config =
        match current_text(&paths::config_file()).and_then(|text| apply(&text, &draft, None)) {
            Ok((_, config)) => config,
            Err(error) => return Outcome::failed(format!("{error:#}")),
        };
    if config.speech_provider == SpeechProvider::Codex {
        return match CodexTranscriptionService::new(CodexAuthStore::new(None)).check_credentials() {
            Ok(()) => Outcome::passed(config.text(
                "Codex 登录有效。请录音验证语音转写。",
                "Codex login is valid. Record audio to verify transcription.",
            )),
            Err(error) => Outcome::failed(error.to_string()),
        };
    }
    let token = match draft.access_token.as_deref() {
        Some(token) => token.trim().to_owned(),
        None => config::doubao_access_token(&config).await,
    };
    if !config.has_valid_doubao_configuration() || token.is_empty() {
        return Outcome::failed(config.text(
            "请先填写 App ID、Resource ID 和 Access Token。",
            "Fill in App ID, Resource ID, and Access Token first.",
        ));
    }
    let doubao = DoubaoConfig::new(
        config.doubao.app_id.trim().to_owned(),
        token,
        config.doubao.resource_id.trim().to_owned(),
        config.language.clone(),
    );
    match doubao::test_connection(doubao).await {
        Ok(()) => {
            Outcome::passed(config.text("语音识别连接测试成功。", "Speech connection test passed."))
        }
        Err(error) => Outcome::failed(format!("{error:#}")),
    }
}

/// `testAIRewriteConnection` on macOS.
pub async fn test_ai_rewrite() -> Outcome {
    let config = Config::load().unwrap_or_default();
    match AiRewriteService::new(CodexAuthStore::new(None))
        .test_connection()
        .await
    {
        Ok(()) => Outcome::passed(config.text(
            "AI Rewrite 连接测试成功。",
            "AI Rewrite connection test passed.",
        )),
        Err(error) => Outcome::failed(error.to_string()),
    }
}

fn current_text(path: &Path) -> Result<String> {
    match std::fs::read_to_string(path) {
        Ok(text) => Ok(text),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(TEMPLATE.to_owned()),
        Err(error) => Err(error).with_context(|| format!("failed to read {}", path.display())),
    }
}

/// Applies `draft` to the config text, keeping comments and layout, and validates the result.
/// `file_token` replaces `doubao.access_token`.
fn apply(text: &str, draft: &Draft, file_token: Option<&str>) -> Result<(String, Config)> {
    let mut document: DocumentMut = text
        .parse()
        .context("config.toml is not valid TOML; fix it by hand first")?;
    let root = document.as_table_mut();
    if let Some(provider) = draft.speech_provider {
        let name = match provider {
            SpeechProvider::Codex => "codex",
            SpeechProvider::Doubao => "doubao",
        };
        set(root, "speech_provider", name);
    }
    if let Some(language) = &draft.language {
        set(root, "language", language.trim());
    }
    if let Some(enabled) = draft.ai_rewrite {
        set(root, "ai_rewrite", enabled);
    }

    let touches_doubao =
        draft.app_id.is_some() || draft.resource_id.is_some() || file_token.is_some();
    if touches_doubao {
        let doubao = document
            .entry("doubao")
            .or_insert(toml_edit::table())
            .as_table_like_mut()
            .context("[doubao] in config.toml must be a table")?;
        if let Some(app_id) = &draft.app_id {
            set(doubao, "app_id", app_id.trim());
        }
        if let Some(resource_id) = &draft.resource_id {
            set(doubao, "resource_id", resource_id.trim());
        }
        if let Some(token) = file_token
            && (!token.is_empty() || doubao.get("access_token").is_some())
        {
            set(doubao, "access_token", token);
        }
    }

    let text = document.to_string();
    let config = Config::parse(&text)?;
    Ok((text, config))
}

/// Replaces a value in place, keeping the comments above its key and after it.
/// `insert` would reset the key's formatting and drop those comments.
fn set(table: &mut dyn TableLike, key: &str, value: impl Into<Value>) {
    let mut value = value.into();
    match table.get_mut(key) {
        Some(item) => {
            if let Some(old) = item.as_value() {
                *value.decor_mut() = old.decor().clone();
            }
            *item = Item::Value(value);
        }
        None => {
            table.insert(key, Item::Value(value));
        }
    }
}

/// Replaces the file atomically with mode 0600, following a symlinked config.
fn write_private(path: &Path, text: &str) -> Result<()> {
    let path = std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf());
    let directory = path
        .parent()
        .context("config path has no parent directory")?;
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(directory)
        .with_context(|| format!("failed to create {}", directory.display()))?;
    let temporary = directory.join(format!(".config.toml.{}", std::process::id()));
    let _ = std::fs::remove_file(&temporary);
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temporary)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&temporary, &path)
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temporary);
    }
    result.with_context(|| format!("failed to write {}", path.display()))
}

async fn store_keyring(token: &str) -> Result<()> {
    let mut child = Command::new("secret-tool")
        .args([
            "store",
            "--label=NoType Doubao",
            "application",
            SECRET_APPLICATION,
            "account",
            SECRET_ACCOUNT,
        ])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .context("failed to run secret-tool")?;
    let mut stdin = child.stdin.take().context("secret-tool has no stdin")?;
    // secret-tool stores stdin verbatim, so no trailing newline.
    stdin.write_all(token.as_bytes()).await?;
    drop(stdin);
    let output = tokio::time::timeout(KEYRING_TIMEOUT, child.wait_with_output())
        .await
        .context("secret-tool timed out")??;
    if !output.status.success() {
        bail!(
            "secret-tool store failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }
    Ok(())
}

async fn clear_keyring() {
    let child = Command::new("secret-tool")
        .args([
            "clear",
            "application",
            SECRET_APPLICATION,
            "account",
            SECRET_ACCOUNT,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn();
    if let Ok(mut child) = child {
        let _ = tokio::time::timeout(KEYRING_TIMEOUT, child.wait()).await;
    }
}

/// Reads the NoType bindings from Hyprland, or the defaults when hyprctl is unavailable.
async fn hotkeys() -> Hotkeys {
    let output = Command::new("hyprctl")
        .args(["binds", "-j"])
        .stdin(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(HYPRCTL_TIMEOUT, output).await {
        Ok(Ok(output)) if output.status.success() => {
            parse_hotkeys(&output.stdout).unwrap_or_default()
        }
        _ => Hotkeys::default(),
    }
}

#[derive(Deserialize)]
struct Bind {
    #[serde(default)]
    description: String,
    #[serde(default)]
    modmask: u32,
    #[serde(default)]
    key: String,
    #[serde(default)]
    submap: String,
}

fn parse_hotkeys(json: &[u8]) -> Option<Hotkeys> {
    let binds: Vec<Bind> = serde_json::from_slice(json).ok()?;
    let find = |description: &str| {
        binds
            .iter()
            .find(|bind| bind.submap.is_empty() && bind.description == description)
            .map(|bind| shortcut_name(bind.modmask, &bind.key))
    };
    Some(Hotkeys {
        dictation: find("NoType dictation"),
        translation: find("NoType English translation"),
        selection: find("NoType selection to Chinese"),
        cancel: find("NoType cancel"),
        agent: find("NoType translate agent draft"),
    })
}

fn shortcut_name(modmask: u32, key: &str) -> String {
    let mut parts: Vec<String> = [(64, "Super"), (8, "Alt"), (4, "Ctrl"), (1, "Shift")]
        .into_iter()
        .filter(|(bit, _)| modmask & bit != 0)
        .map(|(_, name)| name.to_owned())
        .collect();
    let key = match key.to_ascii_uppercase().as_str() {
        "SPACE" => "Space".to_owned(),
        "ESCAPE" | "ESC" => "Esc".to_owned(),
        "RETURN" | "ENTER" => "Enter".to_owned(),
        upper if upper.chars().count() == 1 => upper.to_owned(),
        // Bindings written in capitals such as TAB; keep names like XF86AudioMute as written.
        upper if upper == key => {
            let mut chars = key.chars();
            chars
                .next()
                .map(|first| first.to_string() + &chars.as_str().to_ascii_lowercase())
                .unwrap_or_default()
        }
        _ => key.to_owned(),
    };
    parts.push(key);
    parts.join(" + ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn apply_keeps_comments_and_validates() {
        let draft = Draft {
            speech_provider: Some(SpeechProvider::Doubao),
            language: Some("en-US".into()),
            ai_rewrite: Some(true),
            app_id: Some(" 123 ".into()),
            ..Default::default()
        };
        let (text, config) = apply(TEMPLATE, &draft, None).unwrap();
        assert!(
            text.contains("# \"codex\" uses the Codex CLI login"),
            "{text}"
        );
        assert!(text.contains("speech_provider = \"doubao\"\n"), "{text}");
        assert!(text.contains("app_id = \"123\"\n"), "{text}");
        assert!(text.contains("# Prefer the keyring:"), "{text}");
        assert_eq!(config.language, "en-US");
        assert!(config.should_rewrite_dictation());

        let bad = Draft {
            language: Some("fr-FR".into()),
            ..Default::default()
        };
        assert!(apply(TEMPLATE, &bad, None).is_err());
        assert!(apply("speech_provider = ", &Draft::default(), None).is_err());
    }

    #[test]
    fn file_token_is_written_only_when_needed() {
        let (text, config) = apply("", &Draft::default(), Some("secret")).unwrap();
        assert_eq!(config.doubao.access_token, "secret");
        assert!(text.contains("[doubao]"), "{text}");

        // A token moved to the keyring blanks an existing fallback but never adds an empty key.
        let (text, _) = apply(
            "[doubao]\naccess_token = \"old\"\n",
            &Draft::default(),
            Some(""),
        )
        .unwrap();
        assert_eq!(text, "[doubao]\naccess_token = \"\"\n");
        let (text, _) = apply("language = \"zh-CN\"\n", &Draft::default(), Some("")).unwrap();
        assert!(!text.contains("access_token"), "{text}");
    }

    #[test]
    fn drafts_reject_unknown_fields() {
        let draft: Draft =
            serde_json::from_str(r#"{"speech_provider":"doubao","access_token":"t"}"#).unwrap();
        assert_eq!(draft.speech_provider, Some(SpeechProvider::Doubao));
        assert!(serde_json::from_str::<Draft>(r#"{"token":"t"}"#).is_err());
    }

    #[test]
    fn hotkeys_come_from_hyprctl_binds() {
        let json = br#"[
            {"modmask": 8, "submap": "", "key": "SPACE", "description": "NoType dictation"},
            {"modmask": 9, "submap": "", "key": "SPACE", "description": "NoType English translation"},
            {"modmask": 8, "submap": "", "key": "ESCAPE", "description": "NoType cancel"},
            {"modmask": 12, "submap": "", "key": "SPACE", "description": "NoType selection to Chinese"},
            {"modmask": 9, "submap": "", "key": "T", "description": "NoType translate agent draft"},
            {"modmask": 64, "submap": "", "key": "RETURN", "description": "Terminal"}
        ]"#;
        assert_eq!(parse_hotkeys(json).unwrap(), Hotkeys::default());
        let missing = parse_hotkeys(
            br#"[{"modmask": 72, "submap": "", "key": "F12", "description": "NoType dictation"}]"#,
        )
        .unwrap();
        assert_eq!(missing.dictation.as_deref(), Some("Super + Alt + F12"));
        assert_eq!(missing.translation, None);
        assert_eq!(shortcut_name(0, "TAB"), "Tab");
        assert_eq!(shortcut_name(0, "XF86AudioMute"), "XF86AudioMute");
    }
}
