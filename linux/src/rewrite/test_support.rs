//! A scripted HTTP/1.1 server for service tests.

use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;
use tokio::time::Instant;

#[derive(Clone, Debug)]
pub(crate) struct RecordedRequest {
    pub method: String,
    pub path: String,
    /// Lowercased header names.
    pub headers: Vec<(String, String)>,
    pub body: Vec<u8>,
}

impl RecordedRequest {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(key, _)| key == name)
            .map(|(_, value)| value.as_str())
    }
}

pub(crate) struct MockResponse {
    pub status: u16,
    pub content_type: &'static str,
    /// Body chunks sent at offsets from the response start.
    pub chunks: Vec<(Duration, Vec<u8>)>,
    /// Keeps the connection open after the last chunk.
    pub hold_open: bool,
    /// Never sends a response at all.
    pub silent: bool,
}

impl MockResponse {
    pub fn new(status: u16, content_type: &'static str) -> Self {
        Self {
            status,
            content_type,
            chunks: Vec::new(),
            hold_open: false,
            silent: false,
        }
    }

    pub fn body(mut self, body: impl Into<Vec<u8>>) -> Self {
        self.chunks.push((Duration::ZERO, body.into()));
        self
    }

    /// SSE `data:` lines at millisecond offsets.
    pub fn sse<S: AsRef<str>>(events: impl IntoIterator<Item = (u64, S)>) -> Self {
        let mut response = Self::new(200, "text/event-stream");
        for (millis, line) in events {
            response.chunks.push((
                Duration::from_millis(millis),
                format!("{}\n\n", line.as_ref()).into_bytes(),
            ));
        }
        response
    }
}

pub(crate) struct MockServer {
    pub url: String,
    pub requests: Arc<Mutex<Vec<RecordedRequest>>>,
    task: JoinHandle<()>,
}

impl MockServer {
    pub async fn start<F>(handler: F) -> Self
    where
        F: Fn(&RecordedRequest) -> MockResponse + Send + Sync + 'static,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let requests = Arc::new(Mutex::new(Vec::new()));
        let handler = Arc::new(handler);
        let recorded = requests.clone();
        let task = tokio::spawn(async move {
            while let Ok((stream, _)) = listener.accept().await {
                let handler = handler.clone();
                let recorded = recorded.clone();
                tokio::spawn(async move {
                    let _ = serve(stream, handler.as_ref(), &recorded).await;
                });
            }
        });
        Self {
            url,
            requests,
            task,
        }
    }

    pub fn requests(&self) -> Vec<RecordedRequest> {
        self.requests.lock().unwrap().clone()
    }
}

impl Drop for MockServer {
    fn drop(&mut self) {
        self.task.abort();
    }
}

async fn serve<F>(
    mut stream: TcpStream,
    handler: &F,
    recorded: &Mutex<Vec<RecordedRequest>>,
) -> std::io::Result<()>
where
    F: Fn(&RecordedRequest) -> MockResponse,
{
    let mut buffer = Vec::new();
    let header_end = loop {
        let mut chunk = [0u8; 4096];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            return Ok(());
        }
        buffer.extend_from_slice(&chunk[..read]);
        if let Some(position) = buffer.windows(4).position(|window| window == b"\r\n\r\n") {
            break position + 4;
        }
    };
    let head = String::from_utf8_lossy(&buffer[..header_end]).into_owned();
    let mut lines = head.split("\r\n");
    let mut request_line = lines.next().unwrap_or_default().split(' ');
    let method = request_line.next().unwrap_or_default().to_owned();
    let path = request_line.next().unwrap_or_default().to_owned();
    let headers: Vec<(String, String)> = lines
        .filter_map(|line| line.split_once(':'))
        .map(|(key, value)| (key.trim().to_ascii_lowercase(), value.trim().to_owned()))
        .collect();
    let length: usize = headers
        .iter()
        .find(|(key, _)| key == "content-length")
        .and_then(|(_, value)| value.parse().ok())
        .unwrap_or(0);
    let mut body = buffer[header_end..].to_vec();
    while body.len() < length {
        let mut chunk = [0u8; 65536];
        let read = stream.read(&mut chunk).await?;
        if read == 0 {
            break;
        }
        body.extend_from_slice(&chunk[..read]);
    }

    let request = RecordedRequest {
        method,
        path,
        headers,
        body,
    };
    let response = handler(&request);
    recorded.lock().unwrap().push(request.clone());
    if response.silent {
        std::future::pending::<()>().await;
    }

    let mut head = format!(
        "HTTP/1.1 {} Mock\r\nContent-Type: {}\r\n",
        response.status, response.content_type
    );
    if request.method == "HEAD" || response.status == 302 {
        head.push_str("Content-Length: 0\r\n");
        if response.status == 302 {
            head.push_str("Location: /redirected\r\n");
        }
    }
    // Without a length the body runs until the connection closes.
    head.push_str("Connection: close\r\n\r\n");
    stream.write_all(head.as_bytes()).await?;
    let start = Instant::now();
    if request.method != "HEAD" && response.status != 302 {
        for (offset, chunk) in response.chunks {
            tokio::time::sleep_until(start + offset).await;
            stream.write_all(&chunk).await?;
            stream.flush().await?;
        }
    }
    if response.hold_open {
        std::future::pending::<()>().await;
    }
    stream.shutdown().await
}

/// A `CODEX_HOME` with a non-expiring test token. Removed on drop.
pub(crate) struct TempCodexHome {
    pub path: std::path::PathBuf,
}

impl TempCodexHome {
    pub fn new(auth_json: Option<&str>) -> Self {
        let path = std::env::temp_dir().join(format!("notype-codex-test-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&path).unwrap();
        if let Some(auth_json) = auth_json {
            std::fs::write(path.join("auth.json"), auth_json).unwrap();
        }
        Self { path }
    }

    pub fn with_token() -> Self {
        Self::new(Some(r#"{"tokens":{"access_token":"test-only-token"}}"#))
    }

    pub fn store(&self) -> crate::codex_auth::CodexAuthStore {
        crate::codex_auth::CodexAuthStore::new(Some(self.path.clone()))
    }
}

impl Drop for TempCodexHome {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}
