//! Codex OAuth credentials read from `$CODEX_HOME/auth.json` (default `~/.codex/auth.json`).
//! Port of `CodexOAuthCredentials`, `CodexAuthStore` and `CodexModelResolver` in AIRewriteService.swift.

use std::ffi::OsString;
use std::fmt;
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use base64::Engine as _;
use serde::Deserialize;
use serde_json::{Map, Value};

use crate::rewrite::AiError;

#[derive(Clone, PartialEq, Eq)]
pub struct CodexCredentials {
    pub access_token: String,
    pub account_id: Option<String>,
    pub expires_at: Option<SystemTime>,
}

impl CodexCredentials {
    pub fn is_expired(&self) -> bool {
        self.expires_at.is_some_and(|expires_at| expires_at <= SystemTime::now())
    }
}

// Never print the bearer token.
impl fmt::Debug for CodexCredentials {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("CodexCredentials")
            .field("access_token", &"<redacted>")
            .field("account_id", &self.account_id)
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

#[derive(Clone, Debug, Default)]
pub struct CodexAuthStore {
    pub codex_home: Option<PathBuf>,
}

#[derive(Deserialize)]
struct CodexAuthFile {
    tokens: CodexAuthTokens,
}

#[derive(Deserialize)]
struct CodexAuthTokens {
    access_token: String,
}

impl CodexAuthStore {
    pub fn new(codex_home: Option<PathBuf>) -> Self {
        Self { codex_home }
    }

    pub fn load(&self) -> Result<CodexCredentials, AiError> {
        let auth_path = self.auth_file_path();
        if !auth_path.exists() {
            return Err(AiError::MissingCodexAuth);
        }

        let data = std::fs::read(&auth_path)?;
        // Swift surfaces the raw DecodingError here; a malformed file is reported as invalid auth.
        let decoded: CodexAuthFile = serde_json::from_slice(&data).map_err(|_| AiError::InvalidCodexAuth)?;
        let access_token = decoded.tokens.access_token.trim().to_owned();
        if access_token.is_empty() {
            return Err(AiError::InvalidCodexAuth);
        }

        let claims = decode_jwt_payload(&access_token);
        let account_id = claims
            .as_ref()
            .and_then(|claims| claims.get("https://api.openai.com/auth"))
            .and_then(|auth| auth.get("chatgpt_account_id"))
            .and_then(Value::as_str)
            .map(str::to_owned);
        let expires_at = claims
            .as_ref()
            .and_then(|claims| claims.get("exp"))
            .and_then(Value::as_f64)
            .and_then(unix_time);

        Ok(CodexCredentials { access_token, account_id, expires_at })
    }

    pub fn has_credentials(&self) -> bool {
        self.load().is_ok()
    }

    pub fn auth_file_path(&self) -> PathBuf {
        codex_home_dir(self.codex_home.as_deref()).join("auth.json")
    }
}

fn codex_home_dir(explicit: Option<&Path>) -> PathBuf {
    resolve_codex_home(explicit, std::env::var_os("CODEX_HOME"), &crate::paths::home_dir())
}

/// Explicit home, then a non-blank `CODEX_HOME`, then `~/.codex`.
fn resolve_codex_home(explicit: Option<&Path>, env: Option<OsString>, user_home: &Path) -> PathBuf {
    if let Some(explicit) = explicit {
        return explicit.to_path_buf();
    }
    if let Some(env) = env.filter(|value| !value.to_string_lossy().trim().is_empty()) {
        return PathBuf::from(env);
    }
    user_home.join(".codex")
}

fn unix_time(seconds: f64) -> Option<SystemTime> {
    if !seconds.is_finite() {
        return None;
    }
    if seconds >= 0.0 {
        // An unrepresentably distant expiry behaves like no expiry.
        Duration::try_from_secs_f64(seconds).ok().and_then(|offset| UNIX_EPOCH.checked_add(offset))
    } else {
        Some(
            Duration::try_from_secs_f64(-seconds)
                .ok()
                .and_then(|offset| UNIX_EPOCH.checked_sub(offset))
                .unwrap_or(UNIX_EPOCH),
        )
    }
}

/// Decodes the JWT claims without verifying the signature.
pub fn decode_jwt_payload(token: &str) -> Option<Map<String, Value>> {
    // Swift's `split` drops empty segments.
    let parts: Vec<&str> = token.split('.').filter(|part| !part.is_empty()).collect();
    if parts.len() < 2 {
        return None;
    }

    let mut base64 = parts[1].replace('-', "+").replace('_', "/");
    let padding = base64.len() % 4;
    if padding > 0 {
        base64.push_str(&"=".repeat(4 - padding));
    }

    let data = base64::engine::general_purpose::STANDARD.decode(base64).ok()?;
    serde_json::from_slice(&data).ok()
}

/// Model used when a request does not pin one: `model = ...` in `$CODEX_HOME/config.toml`.
#[derive(Clone, Debug, Default)]
pub struct CodexModelResolver {
    pub codex_home: Option<PathBuf>,
}

impl CodexModelResolver {
    pub fn new(codex_home: Option<PathBuf>) -> Self {
        Self { codex_home }
    }

    pub fn resolve_model(&self) -> String {
        self.configured_model().unwrap_or_else(|| "gpt-5.5".to_owned())
    }

    fn configured_model(&self) -> Option<String> {
        let config = codex_home_dir(self.codex_home.as_deref()).join("config.toml");
        model_from_config(&std::fs::read_to_string(config).ok()?)
    }
}

// A line scan like the Swift version, not a TOML parse: the first `model = ...` line wins.
fn model_from_config(contents: &str) -> Option<String> {
    let blank = |c: char| c == ' ' || c == '\t';
    for raw_line in contents.split('\n') {
        let Some((key, value)) = raw_line.trim_matches(blank).split_once('=') else { continue };
        if key.is_empty() || value.is_empty() || key.trim_matches(blank) != "model" {
            continue;
        }
        let value = value.trim_matches(blank).trim_matches(|c: char| c == '"' || c == '\'');
        return (!value.is_empty()).then(|| value.to_owned());
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base64_url(text: &str) -> String {
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(text)
    }

    fn temp_home() -> PathBuf {
        let home = std::env::temp_dir().join(format!("notype-auth-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&home).unwrap();
        home
    }

    #[test]
    fn reads_access_token_and_account_id() {
        let home = temp_home();
        let payload = r#"{"https://api.openai.com/auth":{"chatgpt_account_id":"acct-123"},"exp":4102444800}"#;
        let token = format!("header.{}.signature", base64_url(payload));
        let auth = format!(r#"{{"tokens":{{"access_token":"{token}"}}}}"#);
        std::fs::write(home.join("auth.json"), auth).unwrap();

        let credentials = CodexAuthStore::new(Some(home.clone())).load().unwrap();
        std::fs::remove_dir_all(&home).ok();

        assert_eq!(credentials.access_token, token);
        assert_eq!(credentials.account_id.as_deref(), Some("acct-123"));
        assert_eq!(credentials.expires_at, Some(UNIX_EPOCH + Duration::from_secs(4_102_444_800)));
        assert!(!credentials.is_expired());
        assert!(!format!("{credentials:?}").contains("signature"));
    }

    #[test]
    fn missing_blank_malformed_and_expired_auth() {
        let home = temp_home();
        let store = CodexAuthStore::new(Some(home.clone()));
        assert!(matches!(store.load(), Err(AiError::MissingCodexAuth)));
        assert!(!store.has_credentials());

        std::fs::write(home.join("auth.json"), r#"{"tokens":{"access_token":"  "}}"#).unwrap();
        assert!(matches!(store.load(), Err(AiError::InvalidCodexAuth)));

        std::fs::write(home.join("auth.json"), r#"{"OPENAI_API_KEY":"sk"}"#).unwrap();
        assert!(matches!(store.load(), Err(AiError::InvalidCodexAuth)));

        // A token that is not a JWT is still usable and never expires.
        std::fs::write(home.join("auth.json"), r#"{"tokens":{"access_token":" opaque "}}"#).unwrap();
        let opaque = store.load().unwrap();
        assert_eq!(opaque.access_token, "opaque");
        assert_eq!(opaque.account_id, None);
        assert!(!opaque.is_expired());

        let expired = format!(r#"{{"tokens":{{"access_token":"header.{}.signature"}}}}"#, base64_url(r#"{"exp":1}"#));
        std::fs::write(home.join("auth.json"), expired).unwrap();
        assert!(store.load().unwrap().is_expired());
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn jwt_payload_accepts_unpadded_url_safe_segments() {
        let claims = r#"{"k":"??>>~~"}"#;
        let encoded = base64_url(claims);
        assert!(encoded.contains('-') || encoded.contains('_'));
        assert_eq!(decode_jwt_payload(&format!("h.{encoded}.s")).unwrap()["k"], "??>>~~");
        assert!(decode_jwt_payload("only-one-part").is_none());
        assert!(decode_jwt_payload("h.!!!.s").is_none());
        // Empty segments are skipped like Swift's `split`.
        assert!(decode_jwt_payload(&format!(".{}", base64_url(r#"{"a":1}"#))).is_none());
    }

    #[test]
    fn codex_home_prefers_explicit_then_env_then_user_home() {
        let user = Path::new("/home/me");
        assert_eq!(resolve_codex_home(Some(Path::new("/x")), Some("/env".into()), user), PathBuf::from("/x"));
        assert_eq!(resolve_codex_home(None, Some("/env".into()), user), PathBuf::from("/env"));
        assert_eq!(resolve_codex_home(None, Some("  ".into()), user), PathBuf::from("/home/me/.codex"));
        assert_eq!(resolve_codex_home(None, None, user), PathBuf::from("/home/me/.codex"));
    }

    #[test]
    fn model_resolver_ignores_reasoning_effort_config() {
        let home = temp_home();
        let config = "model_reasoning_effort = \"high\"\nplan_mode_reasoning_effort = \"high\"\nmodel = \"gpt-5.5\"\n";
        std::fs::write(home.join("config.toml"), config).unwrap();
        assert_eq!(CodexModelResolver::new(Some(home.clone())).resolve_model(), "gpt-5.5");
        std::fs::write(home.join("config.toml"), "model = 'custom'\n").unwrap();
        assert_eq!(CodexModelResolver::new(Some(home.clone())).resolve_model(), "custom");
        std::fs::remove_dir_all(&home).ok();
        assert_eq!(model_from_config("model = \"\""), None);
    }
}
