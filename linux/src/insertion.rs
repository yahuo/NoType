//! Clipboard-based text insertion and selection capture on Wayland (`wl-clipboard` + Hyprland).
//!
//! Shortcuts follow Omarchy's universal clipboard bindings: Ctrl+V / Ctrl+C in normal windows,
//! Shift+Insert / Ctrl+Insert in windows tagged as terminals.

use std::process::Stdio;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tokio::sync::Mutex;

use crate::hyprland::{self, ActiveWindow};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InsertOutcome {
    Pasted,
    /// Focus moved away from the window that started the session, or the paste shortcut could not
    /// be sent; the text stays on the clipboard.
    CopiedToClipboard,
    Skipped,
}

/// Insertion and selection capture both borrow the clipboard; never let them overlap.
static CLIPBOARD: Mutex<()> = Mutex::const_new(());

const COMMAND_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_SNAPSHOT_BYTES: usize = 32 * 1024 * 1024;
const TEXT_TYPES: [&str; 5] = ["text/plain;charset=utf-8", "UTF8_STRING", "text/plain", "STRING", "TEXT"];

pub fn should_insert(text: &str) -> bool {
    !text.trim().is_empty()
}

/// Pastes `text` into `target` when it still has focus; otherwise leaves it on the clipboard.
///
/// Clipboard work runs in its own task so cancelling the caller never skips the restore.
pub async fn insert(text: &str, target: Option<&ActiveWindow>) -> Result<InsertOutcome> {
    if !should_insert(text) {
        return Ok(InsertOutcome::Skipped);
    }
    let (text, target) = (text.to_owned(), target.cloned());
    tokio::spawn(async move { insert_now(&text, target.as_ref()).await }).await?
}

async fn insert_now(text: &str, target: Option<&ActiveWindow>) -> Result<InsertOutcome> {
    let _clipboard = CLIPBOARD.lock().await;
    let snapshot = ClipboardSnapshot::capture().await;
    set_clipboard_text(text).await?;

    let current = hyprland::active_window().await.ok().flatten();
    let Some(target) = target.filter(|target| current.as_ref().is_some_and(|current| target.same_window(current)))
    else {
        return Ok(InsertOutcome::CopiedToClipboard);
    };

    // Give wl-copy's background process a moment to own the selection before the app asks for it.
    tokio::time::sleep(Duration::from_millis(40)).await;
    let (mods, key) = if target.is_terminal() { ("SHIFT", "Insert") } else { ("CTRL", "V") };
    if let Err(error) = hyprland::send_shortcut(mods, key).await {
        // The text is already on the clipboard, so the user can still paste it by hand.
        tracing::warn!("paste shortcut failed: {error:#}");
        return Ok(InsertOutcome::CopiedToClipboard);
    }
    // Wayland paste is asynchronous: the target reads the offer after it handles the key.
    tokio::time::sleep(Duration::from_millis(300)).await;

    if read_clipboard_text().await.as_deref() == Some(text) {
        snapshot.restore().await;
    }
    Ok(InsertOutcome::Pasted)
}

/// Copies the current selection of `window` without disturbing the user's clipboard.
pub async fn selected_text(window: &ActiveWindow) -> Option<String> {
    let window = window.clone();
    tokio::spawn(async move { selected_text_now(&window).await }).await.ok().flatten()
}

async fn selected_text_now(window: &ActiveWindow) -> Option<String> {
    let _clipboard = CLIPBOARD.lock().await;
    let snapshot = ClipboardSnapshot::capture().await;
    let sentinel = format!("notype-selection-probe-{}", uuid::Uuid::new_v4());
    if set_clipboard_text(&sentinel).await.is_err() {
        return None;
    }

    let (mods, key) = if window.is_terminal() { ("CTRL", "Insert") } else { ("CTRL", "C") };
    let mut copied = None;
    if hyprland::send_shortcut(mods, key).await.is_ok() {
        for _ in 0..10 {
            tokio::time::sleep(Duration::from_millis(40)).await;
            match read_clipboard_text().await {
                Some(text) if text != sentinel => {
                    copied = Some(text);
                    break;
                }
                _ => {}
            }
        }
    }
    snapshot.restore().await;
    copied.filter(|text| !text.trim().is_empty())
}

pub async fn copy_text(text: &str) -> Result<()> {
    let _clipboard = CLIPBOARD.lock().await;
    set_clipboard_text(text).await
}

/// Without `--type`, wl-copy infers plain text and also offers the legacy text aliases
/// (`UTF8_STRING`, `STRING`, `TEXT`) that some toolkits request.
async fn set_clipboard_text(text: &str) -> Result<()> {
    write_clipboard(None, text.as_bytes()).await
}

async fn write_clipboard(mime: Option<&str>, bytes: &[u8]) -> Result<()> {
    let mut command = Command::new("wl-copy");
    if let Some(mime) = mime {
        command.args(["--type", mime]);
    }
    let mut child = command
        // The forked clipboard server inherits stdio; a pipe here would never reach EOF.
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .context("failed to run wl-copy; install wl-clipboard")?;
    let mut stdin = child.stdin.take().context("wl-copy has no stdin")?;
    stdin.write_all(bytes).await.context("failed to write to wl-copy")?;
    drop(stdin);
    // wl-copy forks a server process and exits once it owns the clipboard.
    let status = tokio::time::timeout(COMMAND_TIMEOUT, child.wait())
        .await
        .context("wl-copy timed out")??;
    if !status.success() {
        bail!("wl-copy failed with {status}");
    }
    Ok(())
}

async fn clear_clipboard() {
    let child = Command::new("wl-copy")
        .arg("--clear")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn();
    if let Ok(mut child) = child {
        let _ = tokio::time::timeout(COMMAND_TIMEOUT, child.wait()).await;
    }
}

async fn read_clipboard_text() -> Option<String> {
    let types = list_types().await?;
    let mime = TEXT_TYPES.iter().find(|candidate| types.iter().any(|mime| mime == *candidate))?;
    let bytes = run_capture("wl-paste", &["--no-newline", "--type", mime]).await?;
    String::from_utf8(bytes).ok()
}

async fn list_types() -> Option<Vec<String>> {
    let bytes = run_capture("wl-paste", &["--list-types"]).await?;
    Some(
        String::from_utf8_lossy(&bytes)
            .lines()
            .map(str::trim)
            .filter(|line| !line.is_empty())
            .map(str::to_owned)
            .collect(),
    )
}

/// Runs a clipboard command, returning stdout only on success within the timeout.
async fn run_capture(program: &str, args: &[&str]) -> Option<Vec<u8>> {
    let child = Command::new(program)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .ok()?;
    let output = tokio::time::timeout(COMMAND_TIMEOUT, child.wait_with_output()).await.ok()?.ok()?;
    output.status.success().then_some(output.stdout)
}

/// The most useful single representation of the clipboard. Wayland sources offer every MIME type
/// lazily, so restoring keeps one: text when available, otherwise an image or the first type.
struct ClipboardSnapshot {
    content: Option<(String, Vec<u8>)>,
}

impl ClipboardSnapshot {
    async fn capture() -> Self {
        let Some(types) = list_types().await else {
            return Self { content: None };
        };
        let Some(mime) = preferred_type(&types) else {
            return Self { content: None };
        };
        let mut args = vec!["--type", mime.as_str()];
        if TEXT_TYPES.contains(&mime.as_str()) {
            args.insert(0, "--no-newline");
        }
        let content = run_capture("wl-paste", &args)
            .await
            .filter(|bytes| bytes.len() <= MAX_SNAPSHOT_BYTES)
            .map(|bytes| (mime, bytes));
        Self { content }
    }

    async fn restore(self) {
        match self.content {
            Some((mime, bytes)) => {
                let mime = (!TEXT_TYPES.contains(&mime.as_str())).then_some(mime.as_str());
                let _ = write_clipboard(mime, &bytes).await;
            }
            None => clear_clipboard().await,
        }
    }
}

fn preferred_type(types: &[String]) -> Option<String> {
    let has = |mime: &str| types.iter().any(|candidate| candidate == mime);
    TEXT_TYPES
        .iter()
        .find(|mime| has(mime))
        .map(|mime| (*mime).to_owned())
        .or_else(|| types.iter().find(|mime| mime.as_str() == "image/png").cloned())
        .or_else(|| types.iter().find(|mime| mime.starts_with("image/")).cloned())
        .or_else(|| types.iter().find(|mime| mime.contains('/')).cloned())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn types(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| (*value).to_owned()).collect()
    }

    #[test]
    fn snapshot_prefers_text_then_images() {
        assert_eq!(
            preferred_type(&types(&["TARGETS", "text/html", "text/plain", "UTF8_STRING"])).as_deref(),
            Some("UTF8_STRING")
        );
        assert_eq!(
            preferred_type(&types(&["image/jpeg", "image/png", "text/uri-list"])).as_deref(),
            Some("image/png")
        );
        assert_eq!(preferred_type(&types(&["TARGETS", "x-special/gnome-copied-files"])).as_deref(), Some("x-special/gnome-copied-files"));
        assert_eq!(preferred_type(&types(&["TARGETS"])), None);
    }

    #[test]
    fn whitespace_is_not_inserted() {
        assert!(!should_insert(" \n\t"));
        assert!(should_insert(" hi "));
    }
}
