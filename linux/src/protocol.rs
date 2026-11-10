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
/// Clients that replace the agent draft themselves (the Pi extension, the Claude Code mod);
/// their `translate` request claims a triple Space before the daemon opens the external editor.
pub const DIRECT_DRAFT_CLIENTS: [&str; 2] = ["pi", "claude-code"];

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranslationItem {
    pub id: String,
    pub text: String,
}

/// One entry of a batch reply: `{id,text}`, or `{id,error}` when only that item failed.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TranslationResult {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
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
    #[serde(
        default,
        rename = "parentProcessID",
        skip_serializing_if = "Option::is_none"
    )]
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
    pub items: Option<Vec<TranslationResult>>,
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
            || (browser
                && self.active.len() < 2
                && self.active.values().all(|is_browser| *is_browser));
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
    (1..=64).contains(&id.len())
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

/// Mirrors `NoTypeBrowserBatch.validate` in the macOS app.
pub fn validate_browser_batch(items: &[TranslationItem]) -> Result<(), InvalidBatch> {
    let unique_ids: HashSet<&str> = items.iter().map(|item| item.id.as_str()).collect();
    let valid = (1..=12).contains(&items.len())
        && unique_ids.len() == items.len()
        && (items.len() <= 4 || items.iter().all(|item| utf16_len(&item.text) <= 100))
        && items.iter().all(|item| {
            !item.text.trim().is_empty()
                && utf16_len(&item.text) <= 12_000
                && valid_item_id(&item.id)
        })
        && (items.len() == 1
            || items
                .iter()
                .map(|item| utf16_len(&item.text))
                .sum::<usize>()
                <= 6_000);
    if valid { Ok(()) } else { Err(InvalidBatch) }
}

pub const EMPTY_TRANSLATION_ERROR: &str = "模型返回了空译文。";

/// Why a batch reply was rejected. Messages carry only counts and 1-based positions,
/// never source or translated text, so they are safe to log and to show in the page.
#[derive(Debug, thiserror::Error, PartialEq, Eq)]
pub enum BatchError {
    #[error("译文格式错误：第 {line}/{lines} 行不是合法 JSON。")]
    UnparsableLine { line: usize, lines: usize },
    #[error(
        "译文与原文不对应：期望 {expected} 条，返回 {returned} 条，缺第 {} 条，多余 {unexpected} 条，重复 {duplicates} 条。",
        positions(missing)
    )]
    Mismatch {
        expected: usize,
        returned: usize,
        missing: Vec<usize>,
        unexpected: usize,
        duplicates: usize,
    },
}

fn positions(list: &[usize]) -> String {
    if list.is_empty() {
        return "无".into();
    }
    list.iter()
        .map(usize::to_string)
        .collect::<Vec<_>>()
        .join(",")
}

/// Mirrors `NoTypeBrowserBatch.decode`: JSON Lines output aligned to the input order.
/// Errors when the reply as a whole cannot be trusted; an empty translation fails only its own item.
pub fn decode_browser_batch(
    text: &str,
    items: &[TranslationItem],
) -> Result<Vec<TranslationResult>, BatchError> {
    let lines: Vec<&str> = text
        .split('\n')
        .filter(|line| !line.trim().is_empty())
        .collect();
    let mut result = Vec::new();
    for (index, line) in lines.iter().enumerate() {
        if let Ok(item) = serde_json::from_str::<TranslationItem>(line) {
            result.push(item);
            continue;
        }
        // The model sometimes puts every object on one line, comma separated or as an array.
        let trimmed = line.trim();
        let array = if trimmed.starts_with('[') {
            trimmed.to_owned()
        } else {
            format!("[{}]", trimmed.strip_suffix(',').unwrap_or(trimmed))
        };
        let joined: Vec<TranslationItem> =
            serde_json::from_str(&array).map_err(|_| BatchError::UnparsableLine {
                line: index + 1,
                lines: lines.len(),
            })?;
        result.extend(joined);
    }
    let returned: HashSet<&str> = result.iter().map(|item| item.id.as_str()).collect();
    let expected: HashSet<&str> = items.iter().map(|item| item.id.as_str()).collect();
    let missing: Vec<usize> = (0..items.len())
        .filter(|&index| !returned.contains(items[index].id.as_str()))
        .map(|index| index + 1)
        .collect();
    let unexpected = result
        .iter()
        .filter(|item| !expected.contains(item.id.as_str()))
        .count();
    let duplicates = result.len() - returned.len();
    if !missing.is_empty() || unexpected > 0 || duplicates > 0 {
        return Err(BatchError::Mismatch {
            expected: items.len(),
            returned: result.len(),
            missing,
            unexpected,
            duplicates,
        });
    }
    let mut by_id: HashMap<String, String> = result
        .into_iter()
        .map(|item| (item.id, item.text))
        .collect();
    Ok(items
        .iter()
        .map(|item| match by_id.remove(&item.id) {
            Some(text) if !text.trim().is_empty() => TranslationResult {
                id: item.id.clone(),
                text: Some(text),
                error: None,
            },
            _ => TranslationResult {
                id: item.id.clone(),
                text: None,
                error: Some(EMPTY_TRANSLATION_ERROR.into()),
            },
        })
        .collect())
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
pub async fn read_frame<R: AsyncRead + Unpin>(
    reader: &mut R,
) -> Result<Option<Vec<u8>>, FrameError> {
    let mut header = [0u8; 4];
    let mut filled = 0;
    while filled < header.len() {
        let read = reader.read(&mut header[filled..]).await?;
        if read == 0 {
            return if filled == 0 {
                Ok(None)
            } else {
                Err(FrameError::Truncated)
            };
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
    reader
        .read_exact(&mut payload)
        .await
        .map_err(|error| match error.kind() {
            std::io::ErrorKind::UnexpectedEof => FrameError::Truncated,
            _ => FrameError::Io(error),
        })?;
    Ok(Some(payload))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(id: &str, text: &str) -> TranslationItem {
        TranslationItem {
            id: id.into(),
            text: text.into(),
        }
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
        let short: Vec<_> = (0..12)
            .map(|index| item(&format!("p{index}"), "short"))
            .collect();
        assert!(validate_browser_batch(&short).is_ok());
        let long: Vec<_> = (0..5)
            .map(|index| item(&format!("p{index}"), &"x".repeat(101)))
            .collect();
        assert!(validate_browser_batch(&long).is_err());
        assert!(validate_browser_batch(&[item("p0", &"x".repeat(12_000))]).is_ok());
        assert!(
            validate_browser_batch(&[
                item("p0", &"x".repeat(3_001)),
                item("p1", &"x".repeat(3_000))
            ])
            .is_err()
        );
    }

    fn ok(id: &str, text: &str) -> TranslationResult {
        TranslationResult {
            id: id.into(),
            text: Some(text.into()),
            error: None,
        }
    }

    #[test]
    fn batch_decode_aligns_to_input_order() {
        let input = [item("a", "one"), item("b", "two")];
        let decoded = decode_browser_batch(
            "{\"id\":\"b\",\"text\":\"二\"}\n\n{\"id\":\"a\",\"text\":\"一\"}\n",
            &input,
        )
        .unwrap();
        assert_eq!(decoded, vec![ok("a", "一"), ok("b", "二")]);
        let missing = decode_browser_batch("{\"id\":\"a\",\"text\":\"一\"}", &input).unwrap_err();
        assert_eq!(
            missing.to_string(),
            "译文与原文不对应：期望 2 条，返回 1 条，缺第 2 条，多余 0 条，重复 0 条。"
        );
    }

    #[test]
    fn batch_decode_fails_only_the_empty_item() {
        let input = [item("a", "[Music]"), item("b", "two")];
        let decoded = decode_browser_batch(
            "{\"id\":\"a\",\"text\":\" \"}\n{\"id\":\"b\",\"text\":\"二\"}",
            &input,
        )
        .unwrap();
        assert_eq!(decoded[1], ok("b", "二"));
        assert_eq!(decoded[0].text, None);
        assert_eq!(decoded[0].error.as_deref(), Some(EMPTY_TRANSLATION_ERROR));
        assert_eq!(
            serde_json::to_string(&decoded).unwrap(),
            r#"[{"id":"a","error":"模型返回了空译文。"},{"id":"b","text":"二"}]"#
        );
    }

    #[test]
    fn batch_decode_accepts_objects_joined_on_one_line() {
        let input = [item("a", "one"), item("b", "two"), item("c", "three")];
        let expected = vec![ok("a", "一"), ok("b", "二"), ok("c", "三")];
        for text in [
            "{\"id\":\"a\",\"text\":\"一\"},{\"id\":\"b\",\"text\":\"二\"},\n{\"id\":\"c\",\"text\":\"三\"}",
            "[{\"id\":\"a\",\"text\":\"一\"},{\"id\":\"b\",\"text\":\"二\"},{\"id\":\"c\",\"text\":\"三\"}]",
        ] {
            assert_eq!(decode_browser_batch(text, &input).unwrap(), expected);
        }
        assert_eq!(
            decode_browser_batch("{\"id\":\"a\",\"text\":\"一\"}\nnot json", &input),
            Err(BatchError::UnparsableLine { line: 2, lines: 2 })
        );
        let mismatch = decode_browser_batch(
            "{\"id\":\"a\",\"text\":\"一\"}\n{\"id\":\"a\",\"text\":\"一\"}\n{\"id\":\"x\",\"text\":\"三\"}",
            &input,
        )
        .unwrap_err();
        assert_eq!(
            mismatch,
            BatchError::Mismatch {
                expected: 3,
                returned: 3,
                missing: vec![2, 3],
                unexpected: 1,
                duplicates: 1,
            }
        );
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
        assert!(matches!(
            read_frame(&mut reader).await,
            Err(FrameError::TooLarge(_))
        ));
    }
}
