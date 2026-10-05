//! Doubao streaming ASR over WebSocket.
//! Port of DoubaoStreamingASRProvider.swift and the PCM constants it uses.

use std::io::Read;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use futures_util::{SinkExt, StreamExt};
use serde::Deserialize;
use tokio::net::TcpStream;
use tokio::sync::mpsc::{self, UnboundedReceiver, UnboundedSender};
use tokio::sync::oneshot;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::{HeaderValue, Request};
use tokio_tungstenite::tungstenite::protocol::CloseFrame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::{self, Message};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream};

pub const SERVICE_URL: &str = "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async";
pub const DEFAULT_RESOURCE_ID: &str = "volc.seedasr.sauc.duration";
pub const DEFAULT_WORKFLOW: &str = "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate";

pub const SAMPLE_RATE: u32 = 16_000;
pub const CHANNEL_COUNT: u32 = 1;
pub const BITS_PER_SAMPLE: u32 = 16;
pub const CHUNK_DURATION_MS: u32 = 200;
/// Bytes of 16 kHz mono s16le audio in one 200 ms frame.
pub const CHUNK_BYTE_COUNT: usize =
    (SAMPLE_RATE * CHANNEL_COUNT * (BITS_PER_SAMPLE / 8) * CHUNK_DURATION_MS / 1_000) as usize;

const USER_AGENT: &str = "NoType/0.1";
/// Mirrors the 30 s `URLRequest.timeoutInterval` of the macOS client.
const CONNECT_TIMEOUT: Duration = Duration::from_secs(30);
/// Silence allowed after the final audio frame before the session gives up.
const FINAL_RESPONSE_TIMEOUT: Duration = Duration::from_secs(30);
const CLOSE_TIMEOUT: Duration = Duration::from_secs(1);

const MESSAGE_FULL_SERVER_RESPONSE: u8 = 0x9;
const MESSAGE_ERROR: u8 = 0xF;
const COMPRESSION_NONE: u8 = 0x0;
const COMPRESSION_GZIP: u8 = 0x1;

type Socket = WebSocketStream<MaybeTlsStream<TcpStream>>;

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct DoubaoConfig {
    pub app_id: String,
    pub access_token: String,
    pub resource_id: String,
    pub user_id: String,
    /// BCP 47 tag such as `zh-CN`.
    pub language: String,
    pub workflow: String,
    pub utterance_mode: bool,
}

impl DoubaoConfig {
    /// Trims the credentials and fills the defaults of the macOS `currentASRSessionConfig()`.
    pub fn new(app_id: String, access_token: String, resource_id: String, language: String) -> Self {
        Self {
            app_id: app_id.trim().to_owned(),
            access_token: access_token.trim().to_owned(),
            resource_id: resource_id.trim().to_owned(),
            user_id: host_name(),
            language,
            workflow: DEFAULT_WORKFLOW.to_owned(),
            utterance_mode: true,
        }
    }

    fn is_complete(&self) -> bool {
        !self.app_id.trim().is_empty() && !self.access_token.trim().is_empty() && !self.resource_id.trim().is_empty()
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum AsrEvent {
    Partial(String),
    Final(String),
    Error(String),
}

#[derive(Clone, Debug, PartialEq, Eq, thiserror::Error)]
pub enum AsrError {
    #[error("ASR configuration is incomplete.")]
    NotConfigured,
    #[error("ASR session has not started.")]
    SessionNotStarted,
    #[error("ASR service returned an unexpected response.")]
    InvalidResponse,
    #[error("{0}")]
    Transport(String),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MessageMetadata {
    pub header_size: usize,
    pub message_type: u8,
    pub message_flags: u8,
    pub compression: u8,
    pub payload_size: usize,
    pub sequence_number: Option<i32>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ParsedServerMessage {
    pub transcript: Option<String>,
    pub is_definite: bool,
    pub error_message: Option<String>,
}

#[derive(Deserialize)]
struct ServerPayload {
    code: Option<i64>,
    message: Option<String>,
    result: Option<ResultPayload>,
}

#[derive(Deserialize)]
struct ResultPayload {
    text: Option<String>,
    utterances: Option<Vec<Utterance>>,
}

#[derive(Deserialize)]
struct Utterance {
    definite: Option<bool>,
}

impl ServerPayload {
    fn is_definite(&self) -> bool {
        match self.result.as_ref().and_then(|result| result.utterances.as_ref()) {
            Some(utterances) if !utterances.is_empty() => {
                utterances.iter().all(|utterance| utterance.definite.unwrap_or(false))
            }
            _ => false,
        }
    }
}

/// Handshake request carrying the V3 `X-Api-*` authentication headers.
pub fn make_websocket_request(
    config: &DoubaoConfig,
    connect_id: &str,
    user_agent: &str,
) -> anyhow::Result<Request<()>> {
    make_websocket_request_for(SERVICE_URL, config, connect_id, user_agent)
}

fn make_websocket_request_for(
    url: &str,
    config: &DoubaoConfig,
    connect_id: &str,
    user_agent: &str,
) -> anyhow::Result<Request<()>> {
    let mut request = url.into_client_request()?;
    let headers = request.headers_mut();
    for (name, value) in [
        ("X-Api-App-Key", config.app_id.as_str()),
        ("X-Api-Access-Key", config.access_token.as_str()),
        ("X-Api-Resource-Id", config.resource_id.as_str()),
        ("X-Api-Connect-Id", connect_id),
        ("User-Agent", user_agent),
    ] {
        let value = HeaderValue::from_str(value)
            .map_err(|_| AsrError::Transport(format!("{name} contains characters that are not valid in a header.")))?;
        headers.insert(name, value);
    }
    Ok(request)
}

/// Full client request: header `11 10 10 00`, big-endian payload size, uncompressed JSON.
pub fn make_full_client_request(config: &DoubaoConfig) -> Vec<u8> {
    let payload = serde_json::json!({
        "user": {
            "uid": config.user_id,
            "platform": "Linux",
            "app_version": "1.0.0",
        },
        "audio": {
            "format": "pcm",
            "codec": "raw",
            "rate": SAMPLE_RATE,
            "bits": BITS_PER_SAMPLE,
            "channel": CHANNEL_COUNT,
            "language": config.language,
        },
        "request": {
            "model_name": "bigmodel",
            "enable_itn": true,
            "enable_ddc": false,
            "enable_punc": true,
            "show_utterances": config.utterance_mode,
            "end_window_size": 800,
        },
    });
    frame(
        [0x11, 0x10, 0x10, 0x00],
        &serde_json::to_vec(&payload).expect("JSON values always serialize"),
    )
}

/// Audio-only request: header `11 20 00 00`, or `11 22 00 00` for the last frame.
pub fn make_audio_request(audio: &[u8], is_final: bool) -> Vec<u8> {
    let flag = if is_final { 0x02 } else { 0x00 };
    frame([0x11, 0x20 | flag, 0x00, 0x00], audio)
}

fn frame(header: [u8; 4], payload: &[u8]) -> Vec<u8> {
    let mut data = Vec::with_capacity(8 + payload.len());
    data.extend_from_slice(&header);
    data.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    data.extend_from_slice(payload);
    data
}

pub fn parse_server_message(data: &[u8]) -> Result<ParsedServerMessage, AsrError> {
    let metadata = parse_metadata(data)?;
    match metadata.message_type {
        MESSAGE_FULL_SERVER_RESPONSE => {
            let (metadata, payload) = unpack_message(data)?;
            let decoded: ServerPayload = serde_json::from_slice(&payload).map_err(|_| AsrError::InvalidResponse)?;
            let is_definite = metadata.sequence_number.unwrap_or(0) < 0 || decoded.is_definite();
            let error_message = match decoded.code {
                None | Some(1000) => None,
                Some(_) => decoded.message,
            };
            Ok(ParsedServerMessage {
                transcript: decoded.result.and_then(|result| result.text),
                is_definite,
                error_message,
            })
        }
        MESSAGE_ERROR => {
            let start = metadata.header_size;
            if data.len() < start + 8 {
                return Err(AsrError::InvalidResponse);
            }
            let code = read_u32(data, start);
            let size = read_u32(data, start + 4) as usize;
            let message_start = start + 8;
            let message_end = message_start.checked_add(size).ok_or(AsrError::InvalidResponse)?;
            if message_end > data.len() {
                return Err(AsrError::InvalidResponse);
            }
            let message = String::from_utf8(data[message_start..message_end].to_vec())
                .unwrap_or_else(|_| format!("ASR service returned error code {code}."));
            Ok(ParsedServerMessage {
                transcript: None,
                is_definite: false,
                error_message: Some(format!("ASR error {code}: {message}")),
            })
        }
        _ => Err(AsrError::InvalidResponse),
    }
}

pub fn parse_metadata(data: &[u8]) -> Result<MessageMetadata, AsrError> {
    if data.len() < 8 {
        return Err(AsrError::InvalidResponse);
    }
    let header_size = usize::from(data[0] & 0x0F) * 4;
    let message_type = data[1] >> 4;
    let message_flags = data[1] & 0x0F;
    let compression = data[2] & 0x0F;

    let has_sequence = message_type == MESSAGE_FULL_SERVER_RESPONSE && matches!(message_flags, 0x01 | 0x03);
    let (sequence_number, payload_size_offset) = if has_sequence {
        if data.len() < header_size + 8 {
            return Err(AsrError::InvalidResponse);
        }
        (Some(read_u32(data, header_size) as i32), header_size + 4)
    } else {
        (None, header_size)
    };
    if data.len() < payload_size_offset + 4 {
        return Err(AsrError::InvalidResponse);
    }
    Ok(MessageMetadata {
        header_size,
        message_type,
        message_flags,
        compression,
        payload_size: read_u32(data, payload_size_offset) as usize,
        sequence_number,
    })
}

/// Returns the payload, inflating gzip payloads the macOS client would reject.
pub fn unpack_message(data: &[u8]) -> Result<(MessageMetadata, Vec<u8>), AsrError> {
    let metadata = parse_metadata(data)?;
    let start = metadata.header_size + if metadata.sequence_number.is_none() { 4 } else { 8 };
    let end = start
        .checked_add(metadata.payload_size)
        .ok_or(AsrError::InvalidResponse)?;
    if end > data.len() {
        return Err(AsrError::InvalidResponse);
    }
    let payload = &data[start..end];
    let payload = match metadata.compression {
        COMPRESSION_NONE => payload.to_vec(),
        COMPRESSION_GZIP => {
            let mut inflated = Vec::new();
            flate2::read::GzDecoder::new(payload)
                .read_to_end(&mut inflated)
                .map_err(|_| AsrError::InvalidResponse)?;
            inflated
        }
        _ => {
            return Err(AsrError::Transport(
                "Server returned compressed payload, which this app does not decode yet.".to_owned(),
            ));
        }
    };
    Ok((metadata, payload))
}

fn read_u32(data: &[u8], offset: usize) -> u32 {
    u32::from_be_bytes([data[offset], data[offset + 1], data[offset + 2], data[offset + 3]])
}

/// Receive-side state of one session; mirrors the flags of the Swift provider.
#[derive(Debug, Default)]
struct Progress {
    has_sent_final_audio: bool,
    is_awaiting_final_response: bool,
    did_emit_final: bool,
    did_receive_response_after_final_audio: bool,
    latest_transcript: String,
}

impl Progress {
    fn mark_final_audio(&mut self) {
        self.has_sent_final_audio = true;
        self.is_awaiting_final_response = true;
    }

    /// Returns the event to emit and whether the session ends.
    fn on_message(&mut self, data: &[u8]) -> (Option<AsrEvent>, bool) {
        if self.is_awaiting_final_response {
            self.did_receive_response_after_final_audio = true;
        }
        let response = match parse_server_message(data) {
            Ok(response) => response,
            Err(error) => return (Some(AsrEvent::Error(error.to_string())), true),
        };
        if let Some(error) = response.error_message {
            return (Some(AsrEvent::Error(error)), true);
        }
        match response.transcript.filter(|transcript| !transcript.trim().is_empty()) {
            Some(transcript) => {
                self.latest_transcript = transcript.clone();
                if self.is_awaiting_final_response && response.is_definite {
                    self.did_emit_final = true;
                    (Some(AsrEvent::Final(transcript)), true)
                } else {
                    (Some(AsrEvent::Partial(transcript)), false)
                }
            }
            None if self.is_awaiting_final_response && !self.latest_transcript.trim().is_empty() => {
                self.did_emit_final = true;
                (Some(AsrEvent::Final(self.latest_transcript.clone())), true)
            }
            None => (None, false),
        }
    }

    /// The connection ended or failed; the session always ends afterwards.
    fn on_failure(&mut self, description: String) -> Option<AsrEvent> {
        if self.is_awaiting_final_response && self.did_receive_response_after_final_audio {
            self.did_emit_final = true;
            Some(AsrEvent::Final(self.latest_transcript.clone()))
        } else if !self.did_emit_final {
            Some(AsrEvent::Error(description))
        } else {
            None
        }
    }

    /// What Swift's `cancel()` resets.
    fn reset_after_cancel(&mut self) {
        self.has_sent_final_audio = false;
        self.is_awaiting_final_response = false;
        self.did_receive_response_after_final_audio = false;
    }
}

struct Shared {
    /// Swift's `hasStarted`: cleared by `cancel()` and when the connection ends.
    active: bool,
    progress: Progress,
    events: UnboundedSender<AsrEvent>,
}

impl Shared {
    /// Events are dropped once the session is inactive, so none arrive after `cancel()`.
    fn emit(&self, event: Option<AsrEvent>) {
        if let Some(event) = event.filter(|_| self.active) {
            let _ = self.events.send(event);
        }
    }

    fn end(&mut self) {
        self.active = false;
        self.progress.reset_after_cancel();
    }
}

enum Command {
    Send(Vec<u8>, oneshot::Sender<Result<(), AsrError>>),
    Close,
}

/// One streaming recognition. Dropping it without `finish()` closes the connection;
/// dropping it after `finish()` still delivers the final transcript.
pub struct DoubaoSession {
    shared: Arc<Mutex<Shared>>,
    commands: UnboundedSender<Command>,
}

impl DoubaoSession {
    pub async fn start(config: DoubaoConfig, events: UnboundedSender<AsrEvent>) -> anyhow::Result<Self> {
        Self::start_at(SERVICE_URL, config, events).await
    }

    async fn start_at(url: &str, config: DoubaoConfig, events: UnboundedSender<AsrEvent>) -> anyhow::Result<Self> {
        if !config.is_complete() {
            return Err(AsrError::NotConfigured.into());
        }
        let connect_id = uuid::Uuid::new_v4().to_string();
        let mut socket = connect(make_websocket_request_for(url, &config, &connect_id, USER_AGENT)?).await?;
        socket
            .send(Message::Binary(make_full_client_request(&config).into()))
            .await
            .map_err(|error| AsrError::Transport(error.to_string()))?;

        let shared = Arc::new(Mutex::new(Shared {
            active: true,
            progress: Progress::default(),
            events,
        }));
        let (commands, receiver) = mpsc::unbounded_channel();
        tokio::spawn(run(socket, receiver, shared.clone()));
        Ok(Self { shared, commands })
    }

    /// `pcm` is 16 kHz mono signed 16-bit little-endian audio.
    pub async fn send_audio(&self, pcm: Vec<u8>, is_final: bool) -> anyhow::Result<()> {
        let acknowledged = {
            let mut shared = lock(&self.shared);
            if !shared.active {
                return Err(AsrError::SessionNotStarted.into());
            }
            if is_final {
                shared.progress.mark_final_audio();
            }
            let (sender, receiver) = oneshot::channel();
            self.commands
                .send(Command::Send(make_audio_request(&pcm, is_final), sender))
                .map_err(|_| AsrError::SessionNotStarted)?;
            receiver
        };
        acknowledged.await.map_err(|_| AsrError::SessionNotStarted)??;
        Ok(())
    }

    /// Sends the empty final frame unless one was already sent.
    pub async fn finish(&self) -> anyhow::Result<()> {
        {
            let shared = lock(&self.shared);
            if !shared.active || shared.progress.has_sent_final_audio {
                return Ok(());
            }
        }
        self.send_audio(Vec::new(), true).await
    }

    /// Closes the connection; no event is delivered after this returns.
    pub fn cancel(&self) {
        lock(&self.shared).end();
        let _ = self.commands.send(Command::Close);
    }
}

/// Opens a session, sends an empty final frame and checks the first response for errors.
pub async fn test_connection(config: DoubaoConfig) -> anyhow::Result<()> {
    test_connection_at(SERVICE_URL, config).await
}

async fn test_connection_at(url: &str, config: DoubaoConfig) -> anyhow::Result<()> {
    if !config.is_complete() {
        return Err(AsrError::NotConfigured.into());
    }
    let connect_id = uuid::Uuid::new_v4().to_string();
    let mut socket = connect(make_websocket_request_for(url, &config, &connect_id, USER_AGENT)?).await?;
    let result = async {
        for request in [make_full_client_request(&config), make_audio_request(&[], true)] {
            socket
                .send(Message::Binary(request.into()))
                .await
                .map_err(|error| AsrError::Transport(error.to_string()))?;
        }
        let data = tokio::time::timeout(CONNECT_TIMEOUT, next_data(&mut socket))
            .await
            .map_err(|_| AsrError::Transport("Timed out waiting for the ASR service.".to_owned()))??;
        match parse_server_message(&data)?.error_message {
            Some(error) => Err(AsrError::Transport(error)),
            None => Ok(()),
        }
    }
    .await;
    close(&mut socket).await;
    Ok(result?)
}

async fn next_data(socket: &mut Socket) -> Result<Vec<u8>, AsrError> {
    loop {
        match socket.next().await {
            Some(Ok(Message::Binary(data))) => return Ok(data.to_vec()),
            Some(Ok(Message::Text(text))) => return Ok(text.as_bytes().to_vec()),
            Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => continue,
            Some(Ok(Message::Close(frame))) => return Err(AsrError::Transport(closed_description(frame.as_ref()))),
            Some(Err(error)) => return Err(AsrError::Transport(error.to_string())),
            None => return Err(AsrError::Transport(closed_description(None))),
        }
    }
}

async fn connect(request: Request<()>) -> Result<Socket, AsrError> {
    match tokio::time::timeout(CONNECT_TIMEOUT, tokio_tungstenite::connect_async(request)).await {
        Err(_) => Err(AsrError::Transport(
            "Timed out connecting to the ASR service.".to_owned(),
        )),
        Ok(Err(error)) => Err(AsrError::Transport(describe_connect_error(error))),
        Ok(Ok((socket, _))) => Ok(socket),
    }
}

/// Auth failures arrive as an HTTP response to the upgrade; keep its status and body.
fn describe_connect_error(error: tungstenite::Error) -> String {
    match error {
        tungstenite::Error::Http(response) => {
            let mut description = format!("ASR handshake failed with HTTP {}.", response.status());
            let body = response
                .body()
                .as_deref()
                .map(|body| {
                    String::from_utf8_lossy(body)
                        .trim()
                        .chars()
                        .take(500)
                        .collect::<String>()
                })
                .unwrap_or_default();
            if !body.is_empty() {
                description.push(' ');
                description.push_str(&body);
            }
            description
        }
        error => format!("Cannot connect to the ASR service: {error}"),
    }
}

fn closed_description(frame: Option<&CloseFrame>) -> String {
    match frame {
        Some(frame) if !frame.reason.is_empty() => {
            format!(
                "ASR connection closed ({}): {}",
                u16::from(frame.code),
                frame.reason.as_str()
            )
        }
        Some(frame) => format!("ASR connection closed ({}).", u16::from(frame.code)),
        None => "ASR connection closed.".to_owned(),
    }
}

async fn close(socket: &mut Socket) {
    let frame = CloseFrame {
        code: CloseCode::Away,
        reason: "".into(),
    };
    let _ = tokio::time::timeout(CLOSE_TIMEOUT, socket.close(Some(frame))).await;
}

/// Why the connection task stops reading.
enum Stop {
    /// A message already produced the session's last event.
    Handled,
    /// The connection failed or closed; Swift's `receive` failure branch.
    Failed(String),
}

/// Owns the socket: writes queued audio and turns server messages into events.
async fn run(mut socket: Socket, mut commands: UnboundedReceiver<Command>, shared: Arc<Mutex<Shared>>) {
    let mut handle_alive = true;
    loop {
        let awaiting_final = lock(&shared).progress.is_awaiting_final_response;
        let final_deadline = async {
            if awaiting_final {
                tokio::time::sleep(FINAL_RESPONSE_TIMEOUT).await;
            } else {
                std::future::pending::<()>().await;
            }
        };

        let stop = tokio::select! {
            command = commands.recv(), if handle_alive => match command {
                Some(Command::Send(data, acknowledge)) => {
                    if lock(&shared).active {
                        let result = socket
                            .send(Message::Binary(data.into()))
                            .await
                            .map_err(|error| AsrError::Transport(error.to_string()));
                        let _ = acknowledge.send(result);
                    } else {
                        let _ = acknowledge.send(Err(AsrError::SessionNotStarted));
                    }
                    None
                }
                Some(Command::Close) => Some(Stop::Handled),
                None => {
                    // The handle is gone, so no more audio can come; only wait for a pending final.
                    handle_alive = false;
                    (!awaiting_final).then_some(Stop::Handled)
                }
            },
            message = socket.next() => match message {
                Some(Ok(Message::Binary(data))) => handle_message(&shared, &data),
                Some(Ok(Message::Text(text))) => handle_message(&shared, text.as_bytes()),
                Some(Ok(Message::Ping(_) | Message::Pong(_) | Message::Frame(_))) => None,
                Some(Ok(Message::Close(frame))) => Some(Stop::Failed(closed_description(frame.as_ref()))),
                Some(Err(error)) => Some(Stop::Failed(error.to_string())),
                None => Some(Stop::Failed(closed_description(None))),
            },
            _ = final_deadline => Some(Stop::Failed("Timed out waiting for the final ASR result.".to_owned())),
        };

        match stop {
            None => continue,
            Some(Stop::Handled) => {}
            Some(Stop::Failed(description)) => {
                let mut shared = lock(&shared);
                let event = shared.progress.on_failure(description);
                shared.emit(event);
            }
        }
        break;
    }
    lock(&shared).end();
    close(&mut socket).await;
}

fn handle_message(shared: &Mutex<Shared>, data: &[u8]) -> Option<Stop> {
    let mut shared = lock(shared);
    let (event, stop) = shared.progress.on_message(data);
    shared.emit(event);
    stop.then_some(Stop::Handled)
}

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

fn host_name() -> String {
    let mut buffer = [0u8; 256];
    let result = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) };
    if result == 0 {
        let end = buffer.iter().position(|&byte| byte == 0).unwrap_or(buffer.len());
        let name = String::from_utf8_lossy(&buffer[..end]).trim().to_owned();
        if !name.is_empty() {
            return name;
        }
    }
    "localhost".to_owned()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tokio::net::TcpListener;
    use tokio_tungstenite::tungstenite::handshake::server::{Request as ServerRequest, Response as ServerResponse};

    fn config(language: &str) -> DoubaoConfig {
        DoubaoConfig {
            app_id: "123456789".to_owned(),
            access_token: "token-value".to_owned(),
            resource_id: DEFAULT_RESOURCE_ID.to_owned(),
            user_id: "host".to_owned(),
            language: language.to_owned(),
            workflow: "audio_in,resample".to_owned(),
            utterance_mode: true,
        }
    }

    fn server_response(flags: u8, sequence: Option<i32>, compression: u8, payload: &[u8]) -> Vec<u8> {
        let mut data = vec![
            0x11,
            (MESSAGE_FULL_SERVER_RESPONSE << 4) | flags,
            0x10 | compression,
            0x00,
        ];
        if let Some(sequence) = sequence {
            data.extend_from_slice(&sequence.to_be_bytes());
        }
        data.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        data.extend_from_slice(payload);
        data
    }

    fn json_response(sequence: i32, json: serde_json::Value) -> Vec<u8> {
        let flags = if sequence < 0 { 0x03 } else { 0x01 };
        server_response(
            flags,
            Some(sequence),
            COMPRESSION_NONE,
            &serde_json::to_vec(&json).unwrap(),
        )
    }

    fn transcript(sequence: i32, text: &str, definite: bool) -> Vec<u8> {
        json_response(
            sequence,
            serde_json::json!({"result": {"text": text, "utterances": [{"definite": definite}]}}),
        )
    }

    fn error_frame(code: u32, message: &[u8]) -> Vec<u8> {
        let mut data = vec![0x11, MESSAGE_ERROR << 4, 0x10, 0x00];
        data.extend_from_slice(&code.to_be_bytes());
        data.extend_from_slice(&(message.len() as u32).to_be_bytes());
        data.extend_from_slice(message);
        data
    }

    /// Compile-time check that the daemon can share the session and spawn its futures.
    #[allow(dead_code)]
    fn session_is_shareable(session: &DoubaoSession, events: UnboundedSender<AsrEvent>) {
        fn shareable<T: Send + Sync>() {}
        fn sendable<T: Send>(_: T) {}
        shareable::<DoubaoSession>();
        sendable(DoubaoSession::start(config("zh-CN"), events));
        sendable(session.send_audio(Vec::new(), false));
        sendable(session.finish());
        sendable(test_connection(config("zh-CN")));
    }

    #[test]
    fn config_new_fills_macos_defaults() {
        let config = DoubaoConfig::new(" app ".into(), " token\n".into(), " resource ".into(), "zh-CN".into());
        assert_eq!(config.app_id, "app");
        assert_eq!(config.access_token, "token");
        assert_eq!(config.resource_id, "resource");
        assert_eq!(config.language, "zh-CN");
        assert_eq!(
            config.workflow,
            "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate"
        );
        assert!(config.utterance_mode);
        assert!(!config.user_id.is_empty());
    }

    #[test]
    fn chunk_size_covers_200_ms_of_audio() {
        assert_eq!(CHUNK_BYTE_COUNT, 6_400);
        let chunks: Vec<_> = vec![0x7F; CHUNK_BYTE_COUNT * 2 + 123]
            .chunks(CHUNK_BYTE_COUNT)
            .map(<[u8]>::len)
            .collect();
        assert_eq!(chunks, [CHUNK_BYTE_COUNT, CHUNK_BYTE_COUNT, 123]);
    }

    #[test]
    fn audio_request_marks_final_frame_in_header() {
        let audio = [0x01, 0x02, 0x03];
        assert_eq!(
            make_audio_request(&audio, false),
            [0x11, 0x20, 0x00, 0x00, 0, 0, 0, 3, 1, 2, 3]
        );
        assert_eq!(make_audio_request(&audio, true)[1], 0x22);
        assert_eq!(make_audio_request(&[], true), [0x11, 0x22, 0x00, 0x00, 0, 0, 0, 0]);
    }

    #[test]
    fn websocket_request_uses_v3_resource_headers() {
        let request = make_websocket_request(&config("zh-CN"), "connect-id", "NoType/test").unwrap();
        assert_eq!(request.uri(), SERVICE_URL);
        let header = |name: &str| request.headers()[name].to_str().unwrap().to_owned();
        assert_eq!(header("X-Api-App-Key"), "123456789");
        assert_eq!(header("X-Api-Access-Key"), "token-value");
        assert_eq!(header("X-Api-Resource-Id"), "volc.seedasr.sauc.duration");
        assert_eq!(header("X-Api-Connect-Id"), "connect-id");
        assert_eq!(header("User-Agent"), "NoType/test");
    }

    #[test]
    fn websocket_request_rejects_tokens_that_cannot_be_headers() {
        let mut config = config("zh-CN");
        config.access_token = "bad\ntoken".into();
        assert!(make_websocket_request(&config, "connect-id", USER_AGENT).is_err());
    }

    #[test]
    fn full_client_request_frames_uncompressed_json_with_language() {
        let payload = make_full_client_request(&config("ko-KR"));
        assert_eq!(payload[..4], [0x11, 0x10, 0x10, 0x00]);
        assert_eq!(
            u32::from_be_bytes(payload[4..8].try_into().unwrap()) as usize,
            payload.len() - 8
        );
        let root: serde_json::Value = serde_json::from_slice(&payload[8..]).unwrap();
        assert_eq!(root["audio"]["language"], "ko-KR");
        assert_eq!(root["audio"]["rate"], 16_000);
        assert_eq!(root["audio"]["bits"], 16);
        assert_eq!(root["audio"]["channel"], 1);
        assert_eq!(root["audio"]["format"], "pcm");
        assert_eq!(root["user"]["uid"], "host");
        assert_eq!(root["request"]["model_name"], "bigmodel");
        assert_eq!(root["request"]["show_utterances"], true);
        assert_eq!(root["request"]["enable_punc"], true);
        assert_eq!(root["request"]["enable_ddc"], false);
        assert_eq!(root["request"]["end_window_size"], 800);
    }

    #[test]
    fn metadata_reads_sequence_numbers_only_when_flagged() {
        let with_sequence = server_response(0x01, Some(7), COMPRESSION_NONE, b"{}");
        let metadata = parse_metadata(&with_sequence).unwrap();
        assert_eq!(metadata.header_size, 4);
        assert_eq!(metadata.message_type, MESSAGE_FULL_SERVER_RESPONSE);
        assert_eq!(metadata.sequence_number, Some(7));
        assert_eq!(metadata.payload_size, 2);

        let last = server_response(0x03, Some(-3), COMPRESSION_NONE, b"{}");
        assert_eq!(parse_metadata(&last).unwrap().sequence_number, Some(-3));

        let without_sequence = server_response(0x00, None, COMPRESSION_NONE, b"{}");
        let metadata = parse_metadata(&without_sequence).unwrap();
        assert_eq!(metadata.sequence_number, None);
        assert_eq!(unpack_message(&without_sequence).unwrap().1, b"{}");
    }

    #[test]
    fn transcript_is_definite_for_negative_sequence_or_all_definite_utterances() {
        let partial = parse_server_message(&transcript(2, "你好", false)).unwrap();
        assert_eq!(partial.transcript.as_deref(), Some("你好"));
        assert!(!partial.is_definite);
        assert_eq!(partial.error_message, None);

        assert!(parse_server_message(&transcript(2, "你好", true)).unwrap().is_definite);
        assert!(
            parse_server_message(&transcript(-2, "你好", false))
                .unwrap()
                .is_definite
        );

        let mixed = json_response(
            3,
            serde_json::json!({"result": {"text": "a", "utterances": [{"definite": true}, {"definite": false}]}}),
        );
        assert!(!parse_server_message(&mixed).unwrap().is_definite);
        let empty = json_response(3, serde_json::json!({"result": {"text": "a", "utterances": []}}));
        assert!(!parse_server_message(&empty).unwrap().is_definite);
    }

    #[test]
    fn response_codes_other_than_1000_are_errors() {
        let ok = json_response(
            1,
            serde_json::json!({"code": 1000, "message": "OK", "result": {"text": "hi"}}),
        );
        assert_eq!(parse_server_message(&ok).unwrap().error_message, None);
        let failed = json_response(1, serde_json::json!({"code": 45000001, "message": "invalid params"}));
        assert_eq!(
            parse_server_message(&failed).unwrap().error_message.as_deref(),
            Some("invalid params")
        );
        let no_result = parse_server_message(&json_response(1, serde_json::json!({}))).unwrap();
        assert_eq!(
            no_result,
            ParsedServerMessage {
                transcript: None,
                is_definite: false,
                error_message: None
            }
        );
    }

    #[test]
    fn error_frames_carry_code_and_message() {
        let parsed = parse_server_message(&error_frame(45000081, b"timeout")).unwrap();
        assert_eq!(parsed.error_message.as_deref(), Some("ASR error 45000081: timeout"));
        assert_eq!(parsed.transcript, None);

        let invalid_utf8 = parse_server_message(&error_frame(7, &[0xFF, 0xFE])).unwrap();
        assert_eq!(
            invalid_utf8.error_message.as_deref(),
            Some("ASR error 7: ASR service returned error code 7.")
        );

        let mut truncated = error_frame(7, b"timeout");
        truncated.truncate(truncated.len() - 1);
        assert_eq!(parse_server_message(&truncated), Err(AsrError::InvalidResponse));
    }

    #[test]
    fn gzip_payloads_are_inflated() {
        let json = br#"{"result":{"text":"gzip","utterances":[{"definite":true}]}}"#;
        let mut encoder = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::default());
        encoder.write_all(json).unwrap();
        let compressed = encoder.finish().unwrap();
        let parsed = parse_server_message(&server_response(0x01, Some(1), COMPRESSION_GZIP, &compressed)).unwrap();
        assert_eq!(parsed.transcript.as_deref(), Some("gzip"));
        assert!(parsed.is_definite);

        let corrupt = server_response(0x01, Some(1), COMPRESSION_GZIP, b"not gzip");
        assert_eq!(parse_server_message(&corrupt), Err(AsrError::InvalidResponse));
        let unsupported = server_response(0x01, Some(1), 0x2, b"{}");
        assert!(matches!(
            parse_server_message(&unsupported),
            Err(AsrError::Transport(_))
        ));
    }

    #[test]
    fn malformed_messages_are_rejected() {
        assert_eq!(parse_metadata(&[0x11, 0x90, 0x10]), Err(AsrError::InvalidResponse));
        // Sequence flag without room for the payload size.
        assert_eq!(
            parse_metadata(&[0x11, 0x91, 0x10, 0x00, 0, 0, 0, 1]),
            Err(AsrError::InvalidResponse)
        );
        let mut short_payload = server_response(0x01, Some(1), COMPRESSION_NONE, b"{}");
        short_payload.pop();
        assert_eq!(parse_server_message(&short_payload), Err(AsrError::InvalidResponse));
        let not_json = server_response(0x01, Some(1), COMPRESSION_NONE, b"nope");
        assert_eq!(parse_server_message(&not_json), Err(AsrError::InvalidResponse));
        let unknown_type = vec![0x11, 0xB0, 0x10, 0x00, 0, 0, 0, 0];
        assert_eq!(parse_server_message(&unknown_type), Err(AsrError::InvalidResponse));
        assert_eq!(
            parse_server_message(b"{\"text\":\"plain\"}"),
            Err(AsrError::InvalidResponse)
        );
    }

    #[test]
    fn partials_stream_until_a_definite_result_after_final_audio() {
        let mut progress = Progress::default();
        assert_eq!(
            progress.on_message(&transcript(1, "你好", true)),
            (Some(AsrEvent::Partial("你好".into())), false)
        );
        assert_eq!(progress.on_message(&transcript(2, "  ", false)), (None, false));
        progress.mark_final_audio();
        assert_eq!(
            progress.on_message(&transcript(3, "你好世界", false)),
            (Some(AsrEvent::Partial("你好世界".into())), false)
        );
        assert_eq!(
            progress.on_message(&transcript(-4, "你好世界。", false)),
            (Some(AsrEvent::Final("你好世界。".into())), true)
        );
        assert!(progress.did_emit_final);
    }

    #[test]
    fn empty_response_after_final_audio_finalizes_latest_transcript() {
        let mut progress = Progress::default();
        progress.on_message(&transcript(1, "latest", false));
        progress.mark_final_audio();
        let empty = json_response(2, serde_json::json!({"result": {"text": ""}}));
        assert_eq!(
            progress.on_message(&empty),
            (Some(AsrEvent::Final("latest".into())), true)
        );

        let mut silent = Progress::default();
        silent.mark_final_audio();
        assert_eq!(silent.on_message(&empty), (None, false));
    }

    #[test]
    fn server_errors_end_the_session() {
        let mut progress = Progress::default();
        let failed = json_response(1, serde_json::json!({"code": 1001, "message": "bad"}));
        assert_eq!(
            progress.on_message(&failed),
            (Some(AsrEvent::Error("bad".into())), true)
        );
        assert_eq!(
            progress.on_message(&error_frame(3, b"quota")),
            (Some(AsrEvent::Error("ASR error 3: quota".into())), true)
        );
        assert_eq!(
            progress.on_message(b"garbage!"),
            (
                Some(AsrEvent::Error("ASR service returned an unexpected response.".into())),
                true
            )
        );
    }

    #[test]
    fn connection_loss_after_a_post_final_response_finalizes() {
        let mut progress = Progress::default();
        progress.mark_final_audio();
        progress.on_message(&transcript(1, "  ", false));
        assert_eq!(
            progress.on_failure("closed".into()),
            Some(AsrEvent::Final(String::new()))
        );

        let mut before_final = Progress::default();
        before_final.on_message(&transcript(1, "text", false));
        assert_eq!(
            before_final.on_failure("closed".into()),
            Some(AsrEvent::Error("closed".into()))
        );

        let mut no_response = Progress::default();
        no_response.mark_final_audio();
        assert_eq!(
            no_response.on_failure("closed".into()),
            Some(AsrEvent::Error("closed".into()))
        );

        let mut finished = Progress {
            did_emit_final: true,
            ..Progress::default()
        };
        assert_eq!(finished.on_failure("closed".into()), None);
    }

    /// Accepts one connection, checks the handshake headers and first frame, then runs `script`.
    #[allow(clippy::result_large_err)] // The handshake callback signature is fixed by tungstenite.
    async fn mock_server<F, Fut>(script: F) -> String
    where
        F: FnOnce(WebSocketStream<TcpStream>) -> Fut + Send + 'static,
        Fut: std::future::Future<Output = ()> + Send,
    {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("ws://{}", listener.local_addr().unwrap());
        tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut socket =
                tokio_tungstenite::accept_hdr_async(stream, |request: &ServerRequest, response: ServerResponse| {
                    let headers = request.headers();
                    assert_eq!(headers["X-Api-App-Key"], "123456789");
                    assert_eq!(headers["X-Api-Access-Key"], "token-value");
                    assert_eq!(headers["X-Api-Resource-Id"], DEFAULT_RESOURCE_ID);
                    assert_eq!(headers["X-Api-Connect-Id"].len(), 36);
                    assert_eq!(headers["User-Agent"], USER_AGENT);
                    Ok(response)
                })
                .await
                .unwrap();
            let Some(Ok(Message::Binary(first))) = socket.next().await else {
                panic!("missing full client request")
            };
            assert_eq!(first[..4], [0x11, 0x10, 0x10, 0x00]);
            script(socket).await;
        });
        url
    }

    async fn next_binary(socket: &mut WebSocketStream<TcpStream>) -> Vec<u8> {
        loop {
            match socket.next().await {
                Some(Ok(Message::Binary(data))) => return data.to_vec(),
                Some(Ok(_)) => continue,
                other => panic!("expected a binary frame, got {other:?}"),
            }
        }
    }

    #[tokio::test]
    async fn session_streams_partials_and_final_from_server() {
        let url = mock_server(|mut socket| async move {
            assert_eq!(next_binary(&mut socket).await, make_audio_request(&[1, 2, 3, 4], false));
            socket
                .send(Message::Binary(transcript(1, "你好", false).into()))
                .await
                .unwrap();
            assert_eq!(next_binary(&mut socket).await, make_audio_request(&[], true));
            socket
                .send(Message::Binary(transcript(-2, "你好。", true).into()))
                .await
                .unwrap();
            let _ = socket.next().await;
        })
        .await;

        let (sender, mut events) = mpsc::unbounded_channel();
        let session = DoubaoSession::start_at(&url, config("zh-CN"), sender).await.unwrap();
        session.send_audio(vec![1, 2, 3, 4], false).await.unwrap();
        assert_eq!(events.recv().await, Some(AsrEvent::Partial("你好".into())));
        session.finish().await.unwrap();
        assert_eq!(events.recv().await, Some(AsrEvent::Final("你好。".into())));
        // The session ends itself after the final result, like the Swift provider.
        wait_until_inactive(&session).await;
        assert_eq!(
            session
                .send_audio(vec![0], false)
                .await
                .unwrap_err()
                .downcast::<AsrError>()
                .unwrap(),
            AsrError::SessionNotStarted
        );
        session.finish().await.unwrap();
    }

    async fn wait_until_inactive(session: &DoubaoSession) {
        for _ in 0..200 {
            if !lock(&session.shared).active {
                return;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        panic!("session stayed active");
    }

    #[tokio::test]
    async fn server_close_after_final_audio_finalizes_latest_transcript() {
        let url = mock_server(|mut socket| async move {
            socket
                .send(Message::Binary(transcript(1, "latest", false).into()))
                .await
                .unwrap();
            assert_eq!(next_binary(&mut socket).await, make_audio_request(&[], true));
            socket
                .send(Message::Binary(json_response(2, serde_json::json!({})).into()))
                .await
                .unwrap();
            socket.close(None).await.unwrap();
        })
        .await;

        let (sender, mut events) = mpsc::unbounded_channel();
        let session = DoubaoSession::start_at(&url, config("zh-CN"), sender).await.unwrap();
        assert_eq!(events.recv().await, Some(AsrEvent::Partial("latest".into())));
        // Dropping the handle after finish still delivers the final result.
        session.finish().await.unwrap();
        drop(session);
        assert_eq!(events.recv().await, Some(AsrEvent::Final("latest".into())));
        assert_eq!(events.recv().await, None);
    }

    #[tokio::test]
    async fn cancel_stops_events_and_sends() {
        let url = mock_server(|mut socket| async move {
            while let Some(Ok(message)) = socket.next().await {
                if matches!(message, Message::Close(_)) {
                    break;
                }
                let _ = socket.send(Message::Binary(transcript(1, "late", false).into())).await;
            }
        })
        .await;

        let (sender, mut events) = mpsc::unbounded_channel();
        let session = DoubaoSession::start_at(&url, config("zh-CN"), sender).await.unwrap();
        session.cancel();
        assert!(session.send_audio(vec![0], false).await.is_err());
        session.finish().await.unwrap();
        drop(session);
        assert_eq!(events.recv().await, None);
    }

    #[tokio::test]
    async fn test_connection_reports_server_errors() {
        let url = mock_server(|mut socket| async move {
            assert_eq!(next_binary(&mut socket).await, make_audio_request(&[], true));
            socket
                .send(Message::Binary(error_frame(45000030, b"unauthorized").into()))
                .await
                .unwrap();
            let _ = socket.next().await;
        })
        .await;
        let error = test_connection_at(&url, config("zh-CN")).await.unwrap_err();
        assert_eq!(error.to_string(), "ASR error 45000030: unauthorized");

        let mut incomplete = config("zh-CN");
        incomplete.access_token = " ".into();
        let error = test_connection(incomplete).await.unwrap_err();
        assert_eq!(error.downcast::<AsrError>().unwrap(), AsrError::NotConfigured);
    }

    #[tokio::test]
    async fn test_connection_accepts_a_normal_response() {
        let url = mock_server(|mut socket| async move {
            next_binary(&mut socket).await;
            socket
                .send(Message::Binary(
                    json_response(1, serde_json::json!({"code": 1000})).into(),
                ))
                .await
                .unwrap();
            let _ = socket.next().await;
        })
        .await;
        test_connection_at(&url, config("zh-CN")).await.unwrap();
    }
}
