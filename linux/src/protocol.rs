//! Bridge wire protocol shared with the macOS app (`docs/bridge.md`).
//!
//! A frame is a four-byte unsigned big-endian payload length followed by UTF-8 JSON.

use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt};
use uuid::Uuid;

pub const VERSION: i64 = 1;
pub const MAX_FRAME_BYTES: usize = 1_048_576;

pub const PING_METHOD: &str = "ping";
pub const TRANSLATE_METHOD: &str = "translate";
pub const TRANSLATE_CHINESE_METHOD: &str = "translate_chinese";
pub const TRANSLATE_CHINESE_BATCH_METHOD: &str = "translate_chinese_batch";
pub const TRANSLATE_EDITOR_METHOD: &str = "translate_editor";

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranslationItem {
    pub id: String,
    pub text: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BridgeRequest {
    pub version: i64,
    pub id: String,
    pub method: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub client: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token: Option<String>,
    #[serde(default, rename = "processID", skip_serializing_if = "Option::is_none")]
    pub process_id: Option<i32>,
    #[serde(default, rename = "parentProcessID", skip_serializing_if = "Option::is_none")]
    pub parent_process_id: Option<i32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub trigger: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<TranslationItem>>,
    #[serde(default, rename = "keepAlive", skip_serializing_if = "Option::is_none")]
    pub keep_alive: Option<bool>,
}

impl BridgeRequest {
    pub fn new(method: &str) -> Self {
        Self {
            version: VERSION,
            id: Uuid::new_v4().to_string().to_uppercase(),
            method: method.to_owned(),
            client: None,
            text: None,
            token: None,
            process_id: None,
            parent_process_id: None,
            terminal: None,
            trigger: None,
            items: None,
            keep_alive: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct BridgeFailure {
    pub code: String,
    pub message: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BridgeResponse {
    pub version: i64,
    pub id: String,
    pub ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<BridgeFailure>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub items: Option<Vec<TranslationItem>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub partial: Option<bool>,
}

impl BridgeResponse {
    pub fn success(id: &str, text: Option<String>) -> Self {
        Self {
            version: VERSION,
            id: id.to_owned(),
            ok: true,
            text,
            error: None,
            items: None,
            partial: None,
        }
    }

    pub fn failure(id: &str, code: &str, message: impl Into<String>) -> Self {
        Self {
            version: VERSION,
            id: id.to_owned(),
            ok: false,
            text: None,
            error: Some(BridgeFailure {
                code: code.to_owned(),
                message: message.into(),
            }),
            items: None,
            partial: None,
        }
    }
}

/// Browser batches share two slots; editor and other bridge operations stay exclusive.
#[derive(Debug, Default)]
pub struct Admission {
    active: HashMap<Uuid, bool>,
}

impl Admission {
    pub fn acquire(&mut self, browser: bool) -> Option<Uuid> {
        let admitted = self.active.is_empty()
            || (browser && self.active.len() < 2 && self.active.values().all(|is_browser| *is_browser));
        if !admitted {
            return None;
        }
        let token = Uuid::new_v4();
        self.active.insert(token, browser);
        Some(token)
    }

    pub fn release(&mut self, token: Uuid) {
        self.active.remove(&token);
    }
}

#[derive(Debug, thiserror::Error, PartialEq, Eq)]
#[error("invalid translation batch")]
pub struct InvalidBatch;

pub fn utf16_len(text: &str) -> usize {
    text.encode_utf16().count()
}

fn valid_item_id(id: &str) -> bool {
    (1..=64).contains(&id.len()) && id.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// Mirrors `NoTypeBrowserBatch.validate` in the macOS app.
pub fn validate_browser_batch(items: &[TranslationItem]) -> Result<(), InvalidBatch> {
    let unique_ids: HashSet<&str> = items.iter().map(|item| item.id.as_str()).collect();
    let valid = (1..=12).contains(&items.len())
        && unique_ids.len() == items.len()
        && (items.len() <= 4 || items.iter().all(|item| utf16_len(&item.text) <= 100))
        && items.iter().all(|item| {
            !item.text.trim().is_empty() && utf16_len(&item.text) <= 12_000 && valid_item_id(&item.id)
        })
        && (items.len() == 1 || items.iter().map(|item| utf16_len(&item.text)).sum::<usize>() <= 6_000);
    if valid { Ok(()) } else { Err(InvalidBatch) }
}

/// Mirrors `NoTypeBrowserBatch.decode`: JSON Lines output aligned to the input order.
pub fn decode_browser_batch(text: &str, items: &[TranslationItem]) -> Result<Vec<TranslationItem>, InvalidBatch> {
    let mut result = Vec::new();
    for line in text.split('\n').filter(|line| !line.trim().is_empty()) {
        let item: TranslationItem = serde_json::from_str(line).map_err(|_| InvalidBatch)?;
        result.push(item);
    }
    let result_ids: HashSet<&str> = result.iter().map(|item| item.id.as_str()).collect();
    let input_ids: HashSet<&str> = items.iter().map(|item| item.id.as_str()).collect();
    if result.len() != items.len() || result_ids != input_ids || result.iter().any(|item| item.text.trim().is_empty()) {
        return Err(InvalidBatch);
    }
    let by_id: HashMap<String, TranslationItem> = result.into_iter().map(|item| (item.id.clone(), item)).collect();
    Ok(items.iter().filter_map(|item| by_id.get(&item.id).cloned()).collect())
}

#[derive(Debug, thiserror::Error)]
pub enum FrameError {
    #[error("The NoType bridge received an empty frame.")]
    Empty,
    #[error("The NoType bridge frame is too large ({0} bytes).")]
    TooLarge(usize),
    #[error("The NoType bridge connection closed mid-frame.")]
    Truncated,
    #[error(transparent)]
    Io(#[from] std::io::Error),
}

pub fn encode_frame(payload: &[u8]) -> Result<Vec<u8>, FrameError> {
    if payload.is_empty() {
        return Err(FrameError::Empty);
    }
    if payload.len() > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(payload.len()));
    }
    let mut frame = Vec::with_capacity(4 + payload.len());
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    Ok(frame)
}

pub fn encode_json_frame<T: Serialize>(value: &T) -> Result<Vec<u8>, FrameError> {
    let payload = serde_json::to_vec(value).map_err(|error| FrameError::Io(error.into()))?;
    encode_frame(&payload)
}

/// Reads one frame. Returns `Ok(None)` on a clean EOF before any header byte.
pub async fn read_frame<R: AsyncRead + Unpin>(reader: &mut R) -> Result<Option<Vec<u8>>, FrameError> {
    let mut header = [0u8; 4];
    let mut filled = 0;
    while filled < header.len() {
        let read = reader.read(&mut header[filled..]).await?;
        if read == 0 {
            return if filled == 0 { Ok(None) } else { Err(FrameError::Truncated) };
        }
        filled += read;
    }
    let length = u32::from_be_bytes(header) as usize;
    if length == 0 {
        return Err(FrameError::Empty);
    }
    if length > MAX_FRAME_BYTES {
        return Err(FrameError::TooLarge(length));
    }
    let mut payload = vec![0u8; length];
    reader.read_exact(&mut payload).await.map_err(|error| match error.kind() {
        std::io::ErrorKind::UnexpectedEof => FrameError::Truncated,
        _ => FrameError::Io(error),
    })?;
    Ok(Some(payload))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, text: &str) -> TranslationItem {
        TranslationItem { id: id.into(), text: text.into() }
    }

    #[test]
    fn request_uses_swift_field_names() {
        let mut request = BridgeRequest::new(TRANSLATE_EDITOR_METHOD);
        request.process_id = Some(10);
        request.parent_process_id = Some(9);
        request.keep_alive = Some(true);
        let json = serde_json::to_value(&request).unwrap();
        assert_eq!(json["processID"], 10);
        assert_eq!(json["parentProcessID"], 9);
        assert_eq!(json["keepAlive"], true);
        assert!(json.get("text").is_none());
    }

    #[test]
    fn batch_limits_match_macos() {
        assert!(validate_browser_batch(&[item("p0", "Hello")]).is_ok());
        assert!(validate_browser_batch(&[]).is_err());
        assert!(validate_browser_batch(&[item("p0", "a"), item("p0", "b")]).is_err());
        assert!(validate_browser_batch(&[item("bad id", "a")]).is_err());
        let short: Vec<_> = (0..12).map(|index| item(&format!("p{index}"), "short")).collect();
        assert!(validate_browser_batch(&short).is_ok());
        let long: Vec<_> = (0..5).map(|index| item(&format!("p{index}"), &"x".repeat(101))).collect();
        assert!(validate_browser_batch(&long).is_err());
        assert!(validate_browser_batch(&[item("p0", &"x".repeat(12_000))]).is_ok());
        assert!(validate_browser_batch(&[item("p0", &"x".repeat(3_001)), item("p1", &"x".repeat(3_000))]).is_err());
    }

    #[test]
    fn batch_decode_aligns_to_input_order() {
        let input = [item("a", "one"), item("b", "two")];
        let decoded = decode_browser_batch("{\"id\":\"b\",\"text\":\"二\"}\n\n{\"id\":\"a\",\"text\":\"一\"}\n", &input).unwrap();
        assert_eq!(decoded, vec![item("a", "一"), item("b", "二")]);
        assert!(decode_browser_batch("{\"id\":\"a\",\"text\":\"一\"}", &input).is_err());
    }

    #[test]
    fn admission_shares_two_browser_slots() {
        let mut admission = Admission::default();
        let first = admission.acquire(true).unwrap();
        let second = admission.acquire(true).unwrap();
        assert!(admission.acquire(true).is_none());
        admission.release(first);
        assert!(admission.acquire(false).is_none());
        admission.release(second);
        let exclusive = admission.acquire(false).unwrap();
        assert!(admission.acquire(true).is_none());
        admission.release(exclusive);
    }

    #[tokio::test]
    async fn frames_round_trip_and_reject_oversize() {
        let frame = encode_frame(b"{}").unwrap();
        let mut reader = &frame[..];
        assert_eq!(read_frame(&mut reader).await.unwrap().unwrap(), b"{}");
        assert!(read_frame(&mut reader).await.unwrap().is_none());
        let oversize = ((MAX_FRAME_BYTES + 1) as u32).to_be_bytes();
        let mut reader = &oversize[..];
        assert!(matches!(read_frame(&mut reader).await, Err(FrameError::TooLarge(_))));
    }
}
