//! Port of NoTypeEditor/EditorBridgeClient.swift.

use std::path::PathBuf;
use std::time::Duration;

use tokio::io::AsyncWriteExt;
use tokio::net::UnixStream;

use crate::protocol::{
    BridgeRequest, BridgeResponse, FrameError, TRANSLATE_EDITOR_METHOD, VERSION, encode_json_frame,
    read_frame,
};

pub const EDITOR_CLIENT: &str = "agent-editor";
pub const DEFAULT_TIMEOUT: Duration = Duration::from_secs(30);

#[cfg(target_os = "linux")]
const MAX_SOCKET_PATH_BYTES: usize = 108;
#[cfg(not(target_os = "linux"))]
const MAX_SOCKET_PATH_BYTES: usize = 104;

#[derive(Debug, thiserror::Error)]
pub enum EditorBridgeError {
    #[error("Invalid NoType editor request: {0}")]
    InvalidRequest(String),
    #[error("Unable to connect to NoType: {0}")]
    ConnectionFailed(String),
    #[error("NoType editor transport failed: {0}")]
    TransportFailed(String),
    #[error("NoType returned an invalid editor response: {0}")]
    InvalidResponse(String),
    #[error("{0}")]
    TranslationFailed(String),
}

/// The draft and the proof that the user just triggered NoType from this terminal.
#[derive(Clone, Debug)]
pub struct EditorTranslation<'a> {
    pub source_text: &'a str,
    pub token: &'a str,
    pub process_id: i32,
    pub parent_process_id: i32,
    pub terminal: &'a str,
    pub trigger: &'a str,
}

pub struct EditorBridgeClient {
    socket_path: PathBuf,
    timeout: Duration,
}

impl EditorBridgeClient {
    pub fn new(socket_path: PathBuf) -> Self {
        Self {
            socket_path,
            timeout: DEFAULT_TIMEOUT,
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout.max(Duration::from_millis(100));
        self
    }

    pub async fn translate(
        &self,
        translation: &EditorTranslation<'_>,
    ) -> Result<String, EditorBridgeError> {
        let mut request = BridgeRequest::new(TRANSLATE_EDITOR_METHOD);
        request.client = Some(EDITOR_CLIENT.into());
        request.text = Some(translation.source_text.into());
        request.token = Some(translation.token.into());
        request.process_id = Some(translation.process_id);
        request.parent_process_id = Some(translation.parent_process_id);
        request.terminal = Some(translation.terminal.into());
        request.trigger = Some(translation.trigger.into());

        let response = tokio::time::timeout(self.timeout, self.send(&request))
            .await
            .map_err(|_| {
                EditorBridgeError::TransportFailed("timed out waiting for NoType".into())
            })??;

        if response.version != VERSION || response.id != request.id {
            return Err(EditorBridgeError::InvalidResponse(
                "response ID or version mismatch".into(),
            ));
        }
        if !response.ok {
            let message = response.error.map(|error| error.message);
            return Err(EditorBridgeError::TranslationFailed(
                message.unwrap_or_else(|| "NoType translation failed.".into()),
            ));
        }
        match response.text {
            Some(text) if !text.trim().is_empty() => Ok(text),
            _ => Err(EditorBridgeError::InvalidResponse(
                "translation is empty".into(),
            )),
        }
    }

    async fn send(&self, request: &BridgeRequest) -> Result<BridgeResponse, EditorBridgeError> {
        if self.socket_path.as_os_str().len() >= MAX_SOCKET_PATH_BYTES {
            return Err(EditorBridgeError::InvalidRequest(
                "socket path is too long".into(),
            ));
        }
        let frame = encode_json_frame(request)
            .map_err(|_| EditorBridgeError::InvalidRequest("payload is too large".into()))?;
        let mut stream = UnixStream::connect(&self.socket_path)
            .await
            .map_err(|error| EditorBridgeError::ConnectionFailed(error.to_string()))?;
        stream
            .write_all(&frame)
            .await
            .map_err(|error| EditorBridgeError::TransportFailed(error.to_string()))?;

        loop {
            let payload = match read_frame(&mut stream).await {
                Ok(Some(payload)) => payload,
                Ok(None) | Err(FrameError::Truncated) => {
                    return Err(EditorBridgeError::TransportFailed(
                        "connection closed before the response was complete".into(),
                    ));
                }
                Err(FrameError::Empty) => {
                    return Err(EditorBridgeError::InvalidResponse(
                        "invalid frame length 0".into(),
                    ));
                }
                Err(FrameError::TooLarge(length)) => {
                    return Err(EditorBridgeError::InvalidResponse(format!(
                        "invalid frame length {length}"
                    )));
                }
                Err(FrameError::Io(error)) => {
                    return Err(EditorBridgeError::TransportFailed(error.to_string()));
                }
            };
            let response: BridgeResponse = serde_json::from_slice(&payload)
                .map_err(|error| EditorBridgeError::InvalidResponse(error.to_string()))?;
            // The bridge never streams editor translations; ignore progress frames defensively.
            if response.partial != Some(true) {
                return Ok(response);
            }
        }
    }
}
