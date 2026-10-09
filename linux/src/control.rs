//! Control socket for the `notype` CLI, Hyprland bindings and the Omarchy shell plugin.
//!
//! A client writes one JSON line and reads JSON lines back: a single `ControlResponse`, or for
//! `status` the current `StatusEvent`s followed, with `follow`, by every change.

use std::fs::File;
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use anyhow::{Context, Result, bail};
use serde::{Deserialize, Serialize};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Semaphore, watch};
use tokio::task::JoinHandle;

use crate::paths;
use crate::status::{SelectionSnapshot, StatusEvent, StatusSnapshot};

const MAX_REQUEST_BYTES: u64 = 4_096;
const MAX_CONNECTIONS: usize = 32;
/// Coalesces streaming partials and level updates for the shell.
const FOLLOW_INTERVAL: Duration = Duration::from_millis(40);

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum ControlRequest {
    Ping,
    /// Same as the dictation hotkey: start, stop, or cancel depending on the phase.
    RecordToggle,
    RecordStart,
    RecordStop,
    /// Translation hotkey: replace the selection with English, or dictate in English.
    Translate,
    Cancel,
    /// Open the terminal agent's external editor and translate its draft.
    AgentTranslate,
    /// Translate the selection to Chinese in the floating panel.
    SelectionChinese,
    SelectionHide,
    /// Copies the finished Chinese translation to the clipboard.
    SelectionCopy,
    /// `config.toml` changed; refresh what the status shows from it.
    ReloadConfig,
    Status {
        #[serde(default)]
        follow: bool,
    },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ControlResponse {
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

pub trait ControlHandler: Send + Sync + 'static {
    /// Dispatches a command and returns without waiting for the session to finish.
    fn handle(&self, request: ControlRequest) -> Result<(), String>;
    fn status(&self) -> watch::Receiver<StatusSnapshot>;
    fn selection(&self) -> watch::Receiver<SelectionSnapshot>;
}

/// Exclusive lock that keeps a second daemon from taking over the sockets.
pub struct DaemonLock {
    _file: File,
}

impl DaemonLock {
    pub fn acquire() -> Result<Self> {
        paths::ensure_private_runtime_dir()
            .context("failed to prepare the NoType runtime directory")?;
        let path = paths::daemon_lock();
        let file = std::fs::OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&path)
            .with_context(|| format!("failed to open {}", path.display()))?;
        file.set_permissions(std::fs::Permissions::from_mode(0o600))?;
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
            bail!("another NoType daemon is already running");
        }
        Ok(Self { _file: file })
    }
}

pub struct ControlServer {
    task: JoinHandle<()>,
    path: PathBuf,
}

impl ControlServer {
    /// Binds the control socket. Call while holding `DaemonLock`, inside a tokio runtime.
    pub fn bind(handler: Arc<dyn ControlHandler>) -> Result<Self> {
        let path = paths::control_socket();
        match std::fs::remove_file(&path) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                return Err(error).with_context(|| format!("failed to remove {}", path.display()));
            }
        }
        let listener = UnixListener::bind(&path)
            .with_context(|| format!("failed to bind {}", path.display()))?;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600))?;
        let limit = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        let task = tokio::spawn(async move {
            loop {
                let Ok((stream, _)) = listener.accept().await else {
                    continue;
                };
                let Ok(permit) = limit.clone().try_acquire_owned() else {
                    continue;
                };
                if !same_user(&stream) {
                    continue;
                }
                let handler = handler.clone();
                tokio::spawn(async move {
                    let _permit = permit;
                    if let Err(error) = serve(stream, handler).await {
                        tracing::debug!("control connection ended: {error:#}");
                    }
                });
            }
        });
        Ok(Self { task, path })
    }

    pub fn shutdown(&self) {
        self.task.abort();
        let _ = std::fs::remove_file(&self.path);
    }
}

fn same_user(stream: &UnixStream) -> bool {
    stream
        .peer_cred()
        .is_ok_and(|cred| cred.uid() == unsafe { libc::geteuid() })
}

async fn serve(stream: UnixStream, handler: Arc<dyn ControlHandler>) -> Result<()> {
    let (reader, mut writer) = stream.into_split();
    let mut line = String::new();
    BufReader::new(reader.take(MAX_REQUEST_BYTES))
        .read_line(&mut line)
        .await?;
    let request = match serde_json::from_str::<ControlRequest>(line.trim()) {
        Ok(request) => request,
        Err(error) => {
            return write_line(
                &mut writer,
                &ControlResponse {
                    ok: false,
                    error: Some(format!("invalid request: {error}")),
                },
            )
            .await;
        }
    };

    if let ControlRequest::Status { follow } = request {
        return stream_status(&mut writer, handler.status(), handler.selection(), follow).await;
    }
    let response = match handler.handle(request) {
        Ok(()) => ControlResponse {
            ok: true,
            error: None,
        },
        Err(error) => ControlResponse {
            ok: false,
            error: Some(error),
        },
    };
    write_line(&mut writer, &response).await
}

async fn stream_status<W: AsyncWrite + Unpin>(
    writer: &mut W,
    mut status: watch::Receiver<StatusSnapshot>,
    mut selection: watch::Receiver<SelectionSnapshot>,
    follow: bool,
) -> Result<()> {
    let mut last_status = status.borrow_and_update().clone();
    let mut last_selection = selection.borrow_and_update().clone();
    write_line(writer, &StatusEvent::Status(last_status.clone())).await?;
    write_line(writer, &StatusEvent::Selection(last_selection.clone())).await?;
    if !follow {
        return Ok(());
    }
    loop {
        tokio::select! {
            changed = status.changed() => changed?,
            changed = selection.changed() => changed?,
        }
        tokio::time::sleep(FOLLOW_INTERVAL).await;
        let current_status = status.borrow_and_update().clone();
        if current_status != last_status {
            write_line(writer, &StatusEvent::Status(current_status.clone())).await?;
            last_status = current_status;
        }
        let current_selection = selection.borrow_and_update().clone();
        if current_selection != last_selection {
            write_line(writer, &StatusEvent::Selection(current_selection.clone())).await?;
            last_selection = current_selection;
        }
    }
}

async fn write_line<W: AsyncWrite + Unpin, T: Serialize>(writer: &mut W, value: &T) -> Result<()> {
    let mut line = serde_json::to_vec(value)?;
    line.push(b'\n');
    writer.write_all(&line).await?;
    writer.flush().await?;
    Ok(())
}

async fn connect() -> Result<UnixStream> {
    let path = paths::control_socket();
    match UnixStream::connect(&path).await {
        Ok(stream) => Ok(stream),
        // No socket, or a stale one left by a crashed daemon.
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
            ) =>
        {
            bail!(
                "NoType is not running ({}). Start it with `systemctl --user start notype`.",
                path.display()
            )
        }
        Err(error) => {
            Err(error).with_context(|| format!("failed to connect to {}", path.display()))
        }
    }
}

/// Sends one command and waits for the daemon's acknowledgement.
pub async fn send(request: &ControlRequest) -> Result<()> {
    let mut stream = connect().await?;
    write_line(&mut stream, request).await?;
    let mut line = String::new();
    BufReader::new(stream).read_line(&mut line).await?;
    let response: ControlResponse =
        serde_json::from_str(line.trim()).context("invalid response from NoType")?;
    if !response.ok {
        bail!(
            response
                .error
                .unwrap_or_else(|| "NoType rejected the command.".into())
        );
    }
    Ok(())
}

/// Copies status lines to `output` until the daemon closes the stream.
pub async fn copy_status<W: AsyncWrite + Unpin>(follow: bool, output: &mut W) -> Result<()> {
    let mut stream = connect().await?;
    write_line(&mut stream, &ControlRequest::Status { follow }).await?;
    let daemon_closed = copy_lines(stream, output).await?;
    if follow && daemon_closed {
        bail!("NoType stopped");
    }
    Ok(())
}

/// Returns false when `output` closed first, e.g. `notype status --follow | head -1`.
async fn copy_lines<R: AsyncRead + Unpin, W: AsyncWrite + Unpin>(
    reader: R,
    output: &mut W,
) -> Result<bool> {
    let mut lines = BufReader::new(reader).lines();
    while let Some(line) = lines.next_line().await? {
        let written = async {
            output.write_all(line.as_bytes()).await?;
            output.write_all(b"\n").await?;
            output.flush().await
        };
        match written.await {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => return Ok(false),
            Err(error) => return Err(error.into()),
        }
    }
    Ok(true)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::status::Phase;

    #[test]
    fn request_lines_are_stable() {
        assert_eq!(
            serde_json::to_string(&ControlRequest::RecordToggle).unwrap(),
            r#"{"command":"record_toggle"}"#
        );
        assert_eq!(
            serde_json::from_str::<ControlRequest>(r#"{"command":"status"}"#).unwrap(),
            ControlRequest::Status { follow: false }
        );
        assert_eq!(
            serde_json::to_string(&ControlRequest::ReloadConfig).unwrap(),
            r#"{"command":"reload_config"}"#
        );
        assert!(serde_json::from_str::<ControlRequest>(r#"{"command":"rm"}"#).is_err());
    }

    #[tokio::test]
    async fn copy_lines_tells_who_closed_first() {
        let mut copied = Vec::new();
        assert!(copy_lines(&b"a\nb\n"[..], &mut copied).await.unwrap());
        assert_eq!(copied, b"a\nb\n");

        let (mut closed, reader) = tokio::io::duplex(64);
        drop(reader);
        assert!(!copy_lines(&b"a\n"[..], &mut closed).await.unwrap());
    }

    #[tokio::test]
    async fn follow_coalesces_and_skips_unchanged_snapshots() {
        let (status_tx, status_rx) = watch::channel(StatusSnapshot::default());
        let (_selection_tx, selection_rx) = watch::channel(SelectionSnapshot::default());
        let (client, mut server) = tokio::io::duplex(64 * 1024);
        let streamer =
            tokio::spawn(
                async move { stream_status(&mut server, status_rx, selection_rx, true).await },
            );
        let mut lines = BufReader::new(client).lines();
        let first = lines.next_line().await.unwrap().unwrap();
        assert!(
            first.starts_with(r#"{"type":"status","phase":"idle""#),
            "{first}"
        );
        let second = lines.next_line().await.unwrap().unwrap();
        assert!(second.starts_with(r#"{"type":"selection""#), "{second}");

        for index in 0..20 {
            status_tx.send_modify(|status| {
                status.phase = Phase::Recording;
                status.transcript = format!("partial {index}");
            });
        }
        tokio::time::sleep(Duration::from_millis(150)).await;
        drop(status_tx);
        let _ = streamer.await;

        let mut rest = Vec::new();
        while let Some(line) = lines.next_line().await.unwrap() {
            rest.push(line);
        }
        assert_eq!(rest.len(), 1, "{rest:?}");
        assert!(rest[0].contains("partial 19"));
    }
}
