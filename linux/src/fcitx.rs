//! Commits text through the NoType fcitx5 addon (`integrations/fcitx5`) into the input context
//! that reported triple Space, so the translation never passes through the clipboard.
//!
//! The addon issues a single-use token with each trigger. The request is
//! `"<token> <byte length>\n<text>"`; the addon answers `ok`, `stale` or `error` and commits only
//! a complete request.

use std::path::Path;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixStream;

use crate::paths;

/// Mirrors `kMaxCommitBytes` in `integrations/fcitx5/commit_request.h`.
const MAX_COMMIT_BYTES: usize = 64 * 1024;
const CONNECT_TIMEOUT: Duration = Duration::from_millis(300);
/// The addon replies from its event loop as soon as the request is complete.
const REPLY_TIMEOUT: Duration = Duration::from_secs(1);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CommitOutcome {
    Committed,
    /// The triggering input context lost focus or went away; nothing was committed.
    Stale,
    /// The addon could not take the request; nothing was committed.
    Unavailable,
    /// The request reached the addon but no reply came back; the text may have been committed.
    Uncertain,
}

pub async fn commit(token: &str, text: &str) -> CommitOutcome {
    commit_at(&paths::fcitx_socket(), token, text).await
}

async fn commit_at(path: &Path, token: &str, text: &str) -> CommitOutcome {
    if text.is_empty() || text.len() > MAX_COMMIT_BYTES {
        return CommitOutcome::Unavailable;
    }
    let Ok(Ok(mut stream)) = tokio::time::timeout(CONNECT_TIMEOUT, UnixStream::connect(path)).await
    else {
        return CommitOutcome::Unavailable;
    };
    let mut request = format!("{token} {}\n", text.len()).into_bytes();
    request.extend_from_slice(text.as_bytes());
    // An incomplete request is refused by its length, so a failed write commits nothing.
    let sent = tokio::time::timeout(REPLY_TIMEOUT, async {
        stream.write_all(&request).await?;
        stream.shutdown().await
    })
    .await;
    if !matches!(sent, Ok(Ok(()))) {
        return CommitOutcome::Unavailable;
    }
    let mut reply = String::new();
    let read = tokio::time::timeout(
        REPLY_TIMEOUT,
        (&mut stream).take(64).read_to_string(&mut reply),
    )
    .await;
    match (read, reply.trim()) {
        (Ok(Ok(_)), "ok") => CommitOutcome::Committed,
        (Ok(Ok(_)), "stale") => CommitOutcome::Stale,
        (Ok(Ok(_)), "error") => CommitOutcome::Unavailable,
        _ => CommitOutcome::Uncertain,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::net::UnixListener;

    /// Accepts one request, returns what the daemon sent, and answers with `reply`.
    fn fake_addon(path: &Path, reply: Option<&'static str>) -> tokio::task::JoinHandle<Vec<u8>> {
        let listener = UnixListener::bind(path).unwrap();
        tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            stream.read_to_end(&mut request).await.unwrap();
            match reply {
                Some(reply) => stream.write_all(reply.as_bytes()).await.unwrap(),
                // Hold the connection open past the daemon's reply timeout.
                None => tokio::time::sleep(REPLY_TIMEOUT * 2).await,
            }
            request
        })
    }

    #[tokio::test]
    async fn sends_token_length_and_text_and_reads_the_reply() {
        let dir = tempdir();
        let path = dir.join("fcitx5.sock");
        let addon = fake_addon(&path, Some("ok\n"));
        assert_eq!(
            commit_at(&path, "0123abcd", "你好 world").await,
            CommitOutcome::Committed
        );
        assert_eq!(addon.await.unwrap(), "0123abcd 12\n你好 world".as_bytes());

        std::fs::remove_file(&path).unwrap();
        let _addon = fake_addon(&path, Some("stale\n"));
        assert_eq!(commit_at(&path, "t", "x").await, CommitOutcome::Stale);

        std::fs::remove_file(&path).unwrap();
        let _addon = fake_addon(&path, Some("error\n"));
        assert_eq!(commit_at(&path, "t", "x").await, CommitOutcome::Unavailable);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn missing_addon_or_oversized_text_is_unavailable() {
        let dir = tempdir();
        let path = dir.join("fcitx5.sock");
        assert_eq!(commit_at(&path, "t", "x").await, CommitOutcome::Unavailable);
        let oversized = "a".repeat(MAX_COMMIT_BYTES + 1);
        assert_eq!(
            commit_at(&path, "t", &oversized).await,
            CommitOutcome::Unavailable
        );
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[tokio::test]
    async fn a_missing_reply_is_uncertain() {
        let dir = tempdir();
        let path = dir.join("fcitx5.sock");
        let _addon = fake_addon(&path, None);
        assert_eq!(commit_at(&path, "t", "x").await, CommitOutcome::Uncertain);
        std::fs::remove_dir_all(dir).unwrap();
    }

    fn tempdir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("notype-fcitx-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&dir).unwrap();
        dir
    }
}
