//! Listener, runtime lock and per-connection framing. Port of `NoTypeBridgeService` and
//! `NoTypeBridgeConnection`.

use std::fs::{self, File, OpenOptions};
use std::io;
use std::os::fd::AsRawFd;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError};
use std::time::{Duration, Instant};

use anyhow::Context;
use bytes::{Buf, Bytes, BytesMut};
use futures_util::future::BoxFuture;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::unix::OwnedWriteHalf;
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::{Semaphore, mpsc};
use tokio::task::{AbortHandle, JoinSet};
use uuid::Uuid;

use super::BridgeHandler;
use crate::paths;
use crate::protocol::{self, BridgeRequest, BridgeResponse, FrameError, MAX_FRAME_BYTES};

/// Live connections, not a lifetime acceptance budget.
pub const MAX_CONNECTIONS: usize = 16;

#[cfg(target_os = "linux")]
const SOCKET_PATH_LIMIT: usize = 108;
#[cfg(not(target_os = "linux"))]
const SOCKET_PATH_LIMIT: usize = 104;

#[derive(Debug, thiserror::Error)]
pub enum BridgeServiceError {
    #[error("Another NoType instance already owns the local bridge.")]
    AnotherInstanceIsListening,
    #[error("The NoType bridge runtime directory is not private or is not owned by this user: {0}")]
    InvalidRuntimeDirectory(String),
    #[error("The NoType bridge socket path is too long: {0}")]
    SocketPathTooLong(String),
    #[error("Unable to create the NoType bridge lock: {0}")]
    UnableToCreateLock(String),
}

/// Receives `partial: true` frames emitted before a request's final response.
#[derive(Clone)]
pub struct ProgressSink(Option<mpsc::UnboundedSender<BridgeResponse>>);

impl ProgressSink {
    /// A sink that drops every progress frame.
    pub fn discard() -> Self {
        Self(None)
    }

    pub fn send(&self, progress: BridgeResponse) {
        if let Some(sender) = &self.0 {
            let _ = sender.send(progress);
        }
    }

    pub(crate) fn channel() -> (Self, mpsc::UnboundedReceiver<BridgeResponse>) {
        let (sender, receiver) = mpsc::unbounded_channel();
        (Self(Some(sender)), receiver)
    }
}

/// Request handler driven by the server. Dropping the returned future cancels the request.
pub trait RequestHandler: Send + Sync + 'static {
    fn handle(&self, request: BridgeRequest, progress: ProgressSink) -> BoxFuture<'_, BridgeResponse>;
}

impl RequestHandler for BridgeHandler {
    fn handle(&self, request: BridgeRequest, progress: ProgressSink) -> BoxFuture<'_, BridgeResponse> {
        Box::pin(BridgeHandler::handle(self, request, progress))
    }
}

pub struct BridgeServer {
    socket_path: PathBuf,
    running: Mutex<Option<Running>>,
}

struct Running {
    accept: AbortHandle,
    lock: File,
}

impl BridgeServer {
    /// Binds `paths::bridge_socket()`. Must be called inside a tokio runtime.
    pub fn start(handler: Arc<BridgeHandler>) -> anyhow::Result<Self> {
        paths::ensure_private_runtime_dir().with_context(|| {
            BridgeServiceError::InvalidRuntimeDirectory(paths::runtime_dir().display().to_string())
        })?;
        Self::start_at(paths::bridge_socket(), paths::bridge_lock(), handler)
    }

    /// Binds `socket_path` while holding an exclusive `flock` on `lock_path`. The lock's
    /// directory must already exist. Must be called inside a tokio runtime.
    pub fn start_at(
        socket_path: PathBuf,
        lock_path: PathBuf,
        handler: Arc<dyn RequestHandler>,
    ) -> anyhow::Result<Self> {
        let lock = acquire_lock(&lock_path)?;
        let listener = match bind(&socket_path) {
            Ok(listener) => listener,
            Err(error) => {
                let _ = fs::remove_file(&socket_path);
                release_lock(&lock);
                return Err(error);
            }
        };
        let accept = tokio::spawn(accept_loop(listener, handler)).abort_handle();
        tracing::info!(socket = %socket_path.display(), "bridge listening");
        Ok(Self {
            socket_path,
            running: Mutex::new(Some(Running { accept, lock })),
        })
    }

    pub fn socket_path(&self) -> &Path {
        &self.socket_path
    }

    /// Closes every connection (cancelling in-flight requests), removes the socket and releases
    /// the lock. Idempotent.
    pub fn shutdown(&self) {
        let Some(running) = self.running.lock().unwrap_or_else(PoisonError::into_inner).take() else {
            return;
        };
        // Aborting the accept task drops its JoinSet, which aborts every connection task.
        running.accept.abort();
        let _ = fs::remove_file(&self.socket_path);
        release_lock(&running.lock);
    }
}

impl Drop for BridgeServer {
    fn drop(&mut self) {
        self.shutdown();
    }
}

fn acquire_lock(path: &Path) -> Result<File, BridgeServiceError> {
    let file = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .custom_flags(libc::O_CLOEXEC)
        .open(path)
        .map_err(|error| BridgeServiceError::UnableToCreateLock(error.to_string()))?;
    file.set_permissions(fs::Permissions::from_mode(0o600))
        .map_err(|error| BridgeServiceError::UnableToCreateLock(error.to_string()))?;
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } != 0 {
        let error = io::Error::last_os_error();
        return Err(if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            BridgeServiceError::AnotherInstanceIsListening
        } else {
            BridgeServiceError::UnableToCreateLock(error.to_string())
        });
    }
    Ok(file)
}

fn release_lock(lock: &File) {
    unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) };
}

fn bind(socket_path: &Path) -> anyhow::Result<UnixListener> {
    if socket_path.as_os_str().len() >= SOCKET_PATH_LIMIT {
        return Err(BridgeServiceError::SocketPathTooLong(socket_path.display().to_string()).into());
    }
    // The lock guarantees no live daemon owns this path.
    match fs::symlink_metadata(socket_path) {
        Ok(_) => fs::remove_file(socket_path).context("unable to remove the stale NoType bridge socket")?,
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error).context("unable to inspect the NoType bridge socket"),
    }
    let listener = UnixListener::bind(socket_path).context("unable to bind the NoType bridge socket")?;
    fs::set_permissions(socket_path, fs::Permissions::from_mode(0o600))
        .context("Unable to secure the NoType bridge socket")?;
    Ok(listener)
}

async fn accept_loop(listener: UnixListener, handler: Arc<dyn RequestHandler>) {
    let slots = Arc::new(Semaphore::new(MAX_CONNECTIONS));
    let mut connections = JoinSet::new();
    let euid = unsafe { libc::geteuid() };
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(error) => {
                tracing::warn!(%error, "bridge accept failed");
                tokio::time::sleep(Duration::from_millis(100)).await;
                continue;
            }
        };
        while connections.try_join_next().is_some() {}
        match stream.peer_cred() {
            Ok(credentials) if credentials.uid() == euid => {}
            _ => {
                tracing::warn!("bridge rejected a peer owned by another user");
                continue;
            }
        }
        let Ok(permit) = slots.clone().try_acquire_owned() else {
            tracing::warn!("bridge connection limit reached");
            continue;
        };
        let handler = handler.clone();
        connections.spawn(async move {
            let _permit = permit;
            let connection = Uuid::new_v4().to_string().to_uppercase();
            tracing::debug!(%connection, "connection_open");
            let reason = serve_connection(stream, handler, &connection).await;
            tracing::debug!(%connection, reason, "connection_close");
        });
    }
}

/// Mirrors `NoTypeBridgeFrameDecoder`: buffers partial frames and rejects bad headers early.
#[derive(Default)]
struct FrameDecoder {
    buffer: BytesMut,
}

impl FrameDecoder {
    fn push(&mut self, data: &[u8]) {
        self.buffer.extend_from_slice(data);
    }

    fn next_frame(&mut self) -> Result<Option<Bytes>, FrameError> {
        if self.buffer.len() < 4 {
            return Ok(None);
        }
        let length = u32::from_be_bytes([self.buffer[0], self.buffer[1], self.buffer[2], self.buffer[3]]) as usize;
        if length == 0 {
            return Err(FrameError::Empty);
        }
        if length > MAX_FRAME_BYTES {
            return Err(FrameError::TooLarge(length));
        }
        if self.buffer.len() < 4 + length {
            return Ok(None);
        }
        self.buffer.advance(4);
        Ok(Some(self.buffer.split_to(length).freeze()))
    }
}

/// Serves one connection until it closes; returns the close reason for logging.
async fn serve_connection(stream: UnixStream, handler: Arc<dyn RequestHandler>, connection: &str) -> &'static str {
    let (mut reader, mut writer) = stream.into_split();
    let mut decoder = FrameDecoder::default();
    let mut chunk = vec![0u8; 64 * 1024];

    loop {
        let payload = loop {
            match decoder.next_frame() {
                Ok(Some(payload)) => break payload,
                Ok(None) => {}
                Err(_) => return reject(&mut writer, "invalid_frame").await,
            }
            match reader.read(&mut chunk).await {
                Ok(0) => return "client_disconnected",
                Ok(read) => decoder.push(&chunk[..read]),
                Err(_) => return "receive_failed",
            }
        };
        let Ok(request) = serde_json::from_slice::<BridgeRequest>(&payload) else {
            return reject(&mut writer, "invalid_request").await;
        };

        let keep_alive = request.keep_alive == Some(true) && request.client.as_deref() == Some("browser");
        let request_id = request.id.clone();
        let started = Instant::now();
        let paragraphs = request.items.as_ref().map_or(1, Vec::len);
        let characters = request.items.as_ref().map_or_else(
            || request.text.as_deref().map_or(0, protocol::utf16_len),
            |items| items.iter().map(|item| protocol::utf16_len(&item.text)).sum(),
        );
        tracing::info!(%connection, request = %request_id, paragraphs, characters, "request_start");

        let (sink, mut progress) = ProgressSink::channel();
        let mut response = handler.handle(request, sink);
        let mut first_progress = true;

        // Frames already buffered behind this request were pipelined.
        match decoder.next_frame() {
            Ok(Some(_)) => return "overlapping_request",
            Ok(None) => {}
            Err(_) => {
                drop(response);
                return reject(&mut writer, "invalid_frame").await;
            }
        }

        let final_response = loop {
            tokio::select! {
                biased;
                Some(update) = progress.recv() => {
                    if first_progress {
                        first_progress = false;
                        tracing::info!(%connection, request = %request_id,
                            elapsed_ms = started.elapsed().as_millis() as u64, "first_progress");
                    }
                    if let Err(reason) = write_response(&mut writer, &update).await {
                        return reason;
                    }
                }
                final_response = &mut response => break final_response,
                read = reader.read(&mut chunk) => match read {
                    Ok(0) => return "client_disconnected",
                    Err(_) => return "receive_failed",
                    Ok(read) => {
                        decoder.push(&chunk[..read]);
                        match decoder.next_frame() {
                            Ok(Some(_)) => return "overlapping_request",
                            Ok(None) => {}
                            Err(_) => {
                                drop(response);
                                return reject(&mut writer, "invalid_frame").await;
                            }
                        }
                    }
                },
            }
        };
        drop(response);
        while let Ok(update) = progress.try_recv() {
            if let Err(reason) = write_response(&mut writer, &update).await {
                return reason;
            }
        }
        drop(progress);

        tracing::info!(
            %connection,
            request = %request_id,
            ok = final_response.ok,
            code = final_response.error.as_ref().map_or("none", |error| error.code.as_str()),
            elapsed_ms = started.elapsed().as_millis() as u64,
            "request_end"
        );
        if let Err(reason) = write_response(&mut writer, &final_response).await {
            return reason;
        }
        if !keep_alive {
            return "response_complete";
        }
    }
}

async fn reject(writer: &mut OwnedWriteHalf, code: &str) -> &'static str {
    let failure = BridgeResponse::failure("", code, "The NoType bridge request frame is invalid.");
    match write_response(writer, &failure).await {
        Ok(()) => "invalid_frame",
        Err(reason) => reason,
    }
}

async fn write_response(writer: &mut OwnedWriteHalf, response: &BridgeResponse) -> Result<(), &'static str> {
    let frame = protocol::encode_json_frame(response).map_err(|_| "encode_failed")?;
    writer.write_all(&frame).await.map_err(|_| "send_failed")
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::MetadataExt;
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};

    use super::*;
    use crate::bridge::test_support::TestDir;
    use crate::protocol::{TRANSLATE_CHINESE_BATCH_METHOD, TRANSLATE_METHOD};

    const IO_TIMEOUT: Duration = Duration::from_secs(5);

    /// Emits one progress frame, then completes after `delay`. Records cancellation via drop.
    struct FakeHandler {
        delay: Duration,
        started: AtomicUsize,
        cancelled: Arc<AtomicBool>,
    }

    impl FakeHandler {
        fn new(delay: Duration) -> Arc<Self> {
            Arc::new(Self {
                delay,
                started: AtomicUsize::new(0),
                cancelled: Arc::new(AtomicBool::new(false)),
            })
        }
    }

    struct CancelFlag(Arc<AtomicBool>, bool);

    impl Drop for CancelFlag {
        fn drop(&mut self) {
            if !self.1 {
                self.0.store(true, Ordering::SeqCst);
            }
        }
    }

    impl RequestHandler for FakeHandler {
        fn handle(&self, request: BridgeRequest, progress: ProgressSink) -> BoxFuture<'_, BridgeResponse> {
            self.started.fetch_add(1, Ordering::SeqCst);
            Box::pin(async move {
                let mut flag = CancelFlag(self.cancelled.clone(), false);
                let mut partial = BridgeResponse::success(&request.id, Some("部分".into()));
                partial.partial = Some(true);
                progress.send(partial);
                tokio::time::sleep(self.delay).await;
                flag.1 = true;
                BridgeResponse::success(&request.id, Some("完整".into()))
            })
        }
    }

    struct Fixture {
        server: BridgeServer,
        dir: TestDir,
    }

    impl Fixture {
        fn start(handler: Arc<dyn RequestHandler>) -> Self {
            let dir = TestDir::new();
            let server = BridgeServer::start_at(dir.path("bridge.sock"), dir.path("bridge.lock"), handler).unwrap();
            Self { server, dir }
        }

        async fn connect(&self) -> UnixStream {
            UnixStream::connect(self.server.socket_path()).await.unwrap()
        }
    }

    fn request(id: &str, method: &str) -> BridgeRequest {
        let mut request = BridgeRequest::new(method);
        request.id = id.into();
        request.text = Some("你好".into());
        request
    }

    fn browser_request(id: &str) -> BridgeRequest {
        let mut request = request(id, TRANSLATE_CHINESE_BATCH_METHOD);
        request.client = Some("browser".into());
        request.keep_alive = Some(true);
        request
    }

    async fn send(stream: &mut UnixStream, request: &BridgeRequest) {
        stream.write_all(&protocol::encode_json_frame(request).unwrap()).await.unwrap();
    }

    async fn response(stream: &mut UnixStream) -> BridgeResponse {
        let frame = tokio::time::timeout(IO_TIMEOUT, protocol::read_frame(stream))
            .await
            .expect("timed out waiting for a frame")
            .unwrap()
            .expect("connection closed before a frame");
        serde_json::from_slice(&frame).unwrap()
    }

    async fn expect_closed(stream: &mut UnixStream) {
        let mut byte = [0u8; 1];
        let read = tokio::time::timeout(IO_TIMEOUT, stream.read(&mut byte)).await.expect("connection stayed open");
        assert!(matches!(read, Ok(0) | Err(_)), "unexpected data after close");
    }

    async fn wait_for(condition: impl Fn() -> bool) -> bool {
        for _ in 0..200 {
            if condition() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        condition()
    }

    #[tokio::test]
    async fn socket_is_private_and_second_server_is_refused() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));
        let metadata = fs::symlink_metadata(fixture.server.socket_path()).unwrap();
        assert_eq!(metadata.mode() & 0o777, 0o600);

        let competing = BridgeServer::start_at(
            fixture.dir.path("other.sock"),
            fixture.dir.path("bridge.lock"),
            FakeHandler::new(Duration::ZERO),
        );
        let error = competing.err().expect("a second server acquired the lock");
        assert!(matches!(
            error.downcast_ref::<BridgeServiceError>(),
            Some(BridgeServiceError::AnotherInstanceIsListening)
        ));
        // The active socket survives the competing start.
        assert!(fixture.server.socket_path().exists());

        fixture.server.shutdown();
        assert!(!fixture.server.socket_path().exists());
        let restarted = BridgeServer::start_at(
            fixture.dir.path("bridge.sock"),
            fixture.dir.path("bridge.lock"),
            FakeHandler::new(Duration::ZERO),
        );
        assert!(restarted.is_ok());
    }

    #[tokio::test]
    async fn legacy_client_gets_progress_and_final_then_close() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));
        let mut stream = fixture.connect().await;
        send(&mut stream, &request("legacy", TRANSLATE_METHOD)).await;
        let partial = response(&mut stream).await;
        assert_eq!(partial.partial, Some(true));
        let final_response = response(&mut stream).await;
        assert_eq!(final_response.id, "legacy");
        assert_eq!(final_response.text.as_deref(), Some("完整"));
        assert_eq!(final_response.partial, None);
        expect_closed(&mut stream).await;
    }

    struct Idle;

    impl crate::bridge::BridgeHooks for Idle {
        fn dictation_busy(&self) -> bool {
            false
        }
    }

    #[tokio::test]
    async fn real_handler_answers_ping_and_rejects_unknown_methods() {
        use crate::agent_editor::AgentEditorTriggers;
        use crate::agent_editor::tests::FakeDesktop;
        use crate::bridge::BridgeHandler;
        use crate::codex_auth::CodexAuthStore;
        use crate::protocol::PING_METHOD;
        use crate::rewrite::AiRewriteService;

        let dir = TestDir::new();
        let editor = AgentEditorTriggers::with_desktop(dir.path("editor-trigger.json"), FakeDesktop::new(None));
        let handler = Arc::new(BridgeHandler::new(
            Arc::new(AiRewriteService::new(CodexAuthStore::new(None))),
            Arc::new(editor),
            Arc::new(Idle),
        ));
        let fixture = Fixture::start(handler);

        let mut stream = fixture.connect().await;
        send(&mut stream, &request("ping", PING_METHOD)).await;
        let pong = response(&mut stream).await;
        assert!(pong.ok);
        assert_eq!((pong.id.as_str(), pong.text.as_deref()), ("ping", Some("pong")));
        expect_closed(&mut stream).await;

        let mut stream = fixture.connect().await;
        send(&mut stream, &request("rewrite", "rewrite")).await;
        let error = response(&mut stream).await.error.unwrap();
        assert_eq!(error.code, "unsupported_method");
        assert_eq!(error.message, "Unsupported NoType bridge method: rewrite.");
        expect_closed(&mut stream).await;
    }

    #[tokio::test]
    async fn browser_keep_alive_serves_sequential_batches_on_one_socket() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));
        let mut stream = fixture.connect().await;
        for index in 0..50 {
            let request = browser_request(&format!("batch-{index}"));
            let frame = protocol::encode_json_frame(&request).unwrap();
            // Fragmented writes must be reassembled.
            stream.write_all(&frame[..2]).await.unwrap();
            stream.write_all(&frame[2..]).await.unwrap();
            let partial = response(&mut stream).await;
            assert_eq!((partial.id.as_str(), partial.partial), (request.id.as_str(), Some(true)));
            let final_response = response(&mut stream).await;
            assert_eq!(final_response.id, request.id);
            assert_eq!(final_response.text.as_deref(), Some("完整"));
            assert_eq!(final_response.partial, None);
        }
        // keepAlive is ignored for non-browser clients.
        let mut legacy = request("legacy", TRANSLATE_METHOD);
        legacy.keep_alive = Some(true);
        send(&mut stream, &legacy).await;
        response(&mut stream).await;
        assert_eq!(response(&mut stream).await.id, "legacy");
        expect_closed(&mut stream).await;
    }

    #[tokio::test]
    async fn malformed_and_oversize_frames_are_rejected_with_an_empty_id() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));

        let mut malformed = fixture.connect().await;
        malformed.write_all(&[0, 0, 0, 1, b'{']).await.unwrap();
        let failure = response(&mut malformed).await;
        assert_eq!(failure.id, "");
        assert_eq!(failure.error.unwrap().code, "invalid_request");
        expect_closed(&mut malformed).await;

        let mut oversize = fixture.connect().await;
        oversize.write_all(&((MAX_FRAME_BYTES + 1) as u32).to_be_bytes()).await.unwrap();
        let failure = response(&mut oversize).await;
        assert_eq!(failure.id, "");
        assert_eq!(failure.error.as_ref().unwrap().code, "invalid_frame");
        assert_eq!(failure.error.unwrap().message, "The NoType bridge request frame is invalid.");
        expect_closed(&mut oversize).await;

        let mut empty = fixture.connect().await;
        empty.write_all(&[0, 0, 0, 0]).await.unwrap();
        assert_eq!(response(&mut empty).await.error.unwrap().code, "invalid_frame");
        expect_closed(&mut empty).await;
    }

    #[tokio::test]
    async fn client_disconnect_cancels_the_in_flight_handler() {
        let handler = FakeHandler::new(Duration::from_secs(10));
        let fixture = Fixture::start(handler.clone());
        let mut stream = fixture.connect().await;
        send(&mut stream, &browser_request("cancel")).await;
        // An old one-response client closes right after the first frame.
        assert_eq!(response(&mut stream).await.partial, Some(true));
        drop(stream);
        assert!(wait_for(|| handler.cancelled.load(Ordering::SeqCst)).await);
    }

    #[tokio::test]
    async fn pipelined_requests_close_the_connection_without_a_response() {
        let handler = FakeHandler::new(Duration::from_secs(10));
        let fixture = Fixture::start(handler.clone());

        // Two frames in one write.
        let mut stream = fixture.connect().await;
        let mut frames = protocol::encode_json_frame(&browser_request("first")).unwrap();
        frames.extend(protocol::encode_json_frame(&browser_request("second")).unwrap());
        stream.write_all(&frames).await.unwrap();
        expect_closed(&mut stream).await;
        assert_eq!(handler.started.load(Ordering::SeqCst), 1);

        // A second frame while the first is in flight.
        handler.cancelled.store(false, Ordering::SeqCst);
        let mut stream = fixture.connect().await;
        send(&mut stream, &browser_request("first")).await;
        assert_eq!(response(&mut stream).await.partial, Some(true));
        send(&mut stream, &browser_request("second")).await;
        expect_closed(&mut stream).await;
        assert!(wait_for(|| handler.cancelled.load(Ordering::SeqCst)).await);
    }

    #[tokio::test]
    async fn live_connections_are_capped_but_sequential_ones_are_not() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));
        for index in 0..(MAX_CONNECTIONS * 2) {
            let mut stream = fixture.connect().await;
            send(&mut stream, &request(&format!("seq-{index}"), TRANSLATE_METHOD)).await;
            response(&mut stream).await;
            assert_eq!(response(&mut stream).await.id, format!("seq-{index}"));
        }

        let mut idle = Vec::new();
        for _ in 0..MAX_CONNECTIONS {
            let mut stream = fixture.connect().await;
            // Prove the server accepted this connection before opening the next one.
            send(&mut stream, &browser_request("idle")).await;
            response(&mut stream).await;
            response(&mut stream).await;
            idle.push(stream);
        }
        let mut refused = fixture.connect().await;
        expect_closed(&mut refused).await;

        idle.pop();
        let mut accepted = None;
        for _ in 0..100 {
            let mut stream = fixture.connect().await;
            let frame = protocol::encode_json_frame(&request("after", TRANSLATE_METHOD)).unwrap();
            let mut header = [0u8; 4];
            if stream.write_all(&frame).await.is_ok()
                && let Ok(Ok(_)) = tokio::time::timeout(IO_TIMEOUT, stream.read_exact(&mut header)).await
            {
                accepted = Some(header);
                break;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        assert!(accepted.is_some(), "a freed slot was never reused");
    }

    #[tokio::test]
    async fn shutdown_closes_idle_persistent_connections() {
        let fixture = Fixture::start(FakeHandler::new(Duration::ZERO));
        let mut stream = fixture.connect().await;
        send(&mut stream, &browser_request("idle")).await;
        response(&mut stream).await;
        assert!(response(&mut stream).await.ok);
        fixture.server.shutdown();
        expect_closed(&mut stream).await;
        fixture.server.shutdown();
    }
}
