//! Codex Responses request body and SSE stream parsing.

use serde::{Deserialize, Serialize};

use super::AiError;

#[derive(Serialize)]
pub(crate) struct CodexResponseRequest<'a> {
    pub model: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub reasoning: Option<CodexReasoning<'a>>,
    pub instructions: &'a str,
    pub input: [CodexInputMessage<'a>; 1],
    pub stream: bool,
    pub store: bool,
}

#[derive(Serialize)]
pub(crate) struct CodexReasoning<'a> {
    pub effort: &'a str,
}

#[derive(Serialize)]
pub(crate) struct CodexInputMessage<'a> {
    pub role: &'a str,
    pub content: [CodexInputContent<'a>; 1],
}

#[derive(Serialize)]
pub(crate) struct CodexInputContent<'a> {
    #[serde(rename = "type")]
    pub kind: &'a str,
    pub text: &'a str,
}

impl<'a> CodexResponseRequest<'a> {
    pub fn new(model: &'a str, reasoning_effort: Option<&'a str>, instructions: &'a str, user_message: &'a str) -> Self {
        Self {
            model,
            reasoning: reasoning_effort.map(|effort| CodexReasoning { effort }),
            instructions,
            input: [CodexInputMessage {
                role: "user",
                content: [CodexInputContent { kind: "input_text", text: user_message }],
            }],
            stream: true,
            store: false,
        }
    }
}

#[derive(Deserialize)]
struct CodexResponseStreamEvent {
    #[serde(rename = "type")]
    kind: String,
    delta: Option<String>,
    text: Option<String>,
}

/// Collects `response.output_text.delta` events; each delta yields the accumulated text.
#[derive(Debug, Default)]
pub struct CodexResponseStreamAccumulator {
    accumulated_text: String,
    saw_terminal_event: bool,
}

impl CodexResponseStreamAccumulator {
    pub fn accumulated_text(&self) -> &str {
        &self.accumulated_text
    }

    pub fn into_text(self) -> String {
        self.accumulated_text
    }

    pub fn is_complete(&self) -> bool {
        self.saw_terminal_event
    }

    pub fn consume(&mut self, line: &str) -> Result<Option<String>, AiError> {
        let Some(payload) = line.trim().strip_prefix("data:") else {
            return Ok(None);
        };
        let payload = payload.trim();
        if payload.is_empty() {
            return Ok(None);
        }

        // Swift propagates the DecodingError; it is reported as an invalid response here.
        let event: CodexResponseStreamEvent =
            serde_json::from_str(payload).map_err(|_| AiError::InvalidResponse)?;
        match event.kind.as_str() {
            "response.output_text.delta" => {
                let delta = event.delta.unwrap_or_default();
                if delta.is_empty() {
                    return Ok(None);
                }
                self.accumulated_text.push_str(&delta);
                Ok(Some(self.accumulated_text.clone()))
            }
            "response.output_text.done" => {
                if let Some(text) = event.text {
                    self.accumulated_text = text;
                }
                self.saw_terminal_event = true;
                Ok(None)
            }
            "response.completed" | "response.failed" | "response.incomplete" => {
                self.saw_terminal_event = true;
                Ok(None)
            }
            _ => Ok(None),
        }
    }
}

/// Splits a byte stream into lines terminated by LF, CR or CRLF.
#[derive(Debug, Default)]
pub(crate) struct LineBuffer {
    pending: Vec<u8>,
}

impl LineBuffer {
    pub fn push(&mut self, chunk: &[u8]) -> Vec<String> {
        self.pending.extend_from_slice(chunk);
        let mut lines = Vec::new();
        let mut start = 0;
        while let Some(offset) = self.pending[start..].iter().position(|byte| matches!(byte, b'\n' | b'\r')) {
            let end = start + offset;
            // CRLF yields an extra empty line, which every consumer ignores.
            lines.push(String::from_utf8_lossy(&self.pending[start..end]).into_owned());
            start = end + 1;
        }
        self.pending.drain(..start);
        lines
    }

    /// The final unterminated line, if any.
    pub fn finish(&mut self) -> Option<String> {
        if self.pending.is_empty() {
            return None;
        }
        let line = String::from_utf8_lossy(&self.pending).into_owned();
        self.pending.clear();
        Some(line)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accumulator_builds_partial_text_from_sse_chunks() {
        let mut accumulator = CodexResponseStreamAccumulator::default();
        let first = accumulator.consume(r#"data: {"type":"response.output_text.delta","delta":"你好"}"#).unwrap();
        let second = accumulator.consume(r#"data: {"type":"response.output_text.delta","delta":"，世界"}"#).unwrap();
        let done = accumulator.consume(r#"data: {"type":"response.output_text.done","text":"你好，世界"}"#).unwrap();

        assert_eq!(first.as_deref(), Some("你好"));
        assert_eq!(second.as_deref(), Some("你好，世界"));
        assert_eq!(done, None);
        assert_eq!(accumulator.accumulated_text(), "你好，世界");
        assert!(accumulator.is_complete());
    }

    #[test]
    fn accumulator_ignores_non_data_and_non_text_events() {
        let mut accumulator = CodexResponseStreamAccumulator::default();
        assert_eq!(accumulator.consume("event: response.created").unwrap(), None);
        assert_eq!(accumulator.consume(r#"data: {"type":"response.created"}"#).unwrap(), None);
        assert_eq!(accumulator.consume("").unwrap(), None);
        assert_eq!(accumulator.consume(": keepalive").unwrap(), None);
        assert_eq!(accumulator.consume(r#"data: {"type":"response.output_text.delta","delta":""}"#).unwrap(), None);
        assert!(accumulator.accumulated_text().is_empty());
        assert!(!accumulator.is_complete());
        assert!(matches!(accumulator.consume("data: {not json"), Err(AiError::InvalidResponse)));
    }

    #[test]
    fn failed_and_incomplete_events_end_the_stream() {
        for kind in ["response.failed", "response.incomplete", "response.completed"] {
            let mut accumulator = CodexResponseStreamAccumulator::default();
            accumulator.consume(&format!(r#"data: {{"type":"{kind}"}}"#)).unwrap();
            assert!(accumulator.is_complete());
        }
    }

    #[test]
    fn line_buffer_handles_split_chunks_crlf_and_trailing_line() {
        let mut buffer = LineBuffer::default();
        assert!(buffer.push(b"data: {\"a\"").is_empty());
        assert_eq!(buffer.push(b":1}\r\n\r\nda"), vec!["data: {\"a\":1}", "", "", ""]);
        // A multi-byte character split across chunks survives.
        let text = "data: 你好".as_bytes();
        let mut buffer = LineBuffer::default();
        assert!(buffer.push(&text[..8]).is_empty());
        assert!(buffer.push(&text[8..]).is_empty());
        assert_eq!(buffer.finish().as_deref(), Some("data: 你好"));
        assert_eq!(buffer.finish(), None);
    }

    #[test]
    fn request_body_omits_reasoning_unless_requested() {
        let body = serde_json::to_value(CodexResponseRequest::new("gpt-test", None, "system", "user")).unwrap();
        assert_eq!(body["model"], "gpt-test");
        assert_eq!(body["stream"], true);
        assert_eq!(body["store"], false);
        assert!(body.get("reasoning").is_none());
        assert!(body.get("max_output_tokens").is_none());
        assert_eq!(body["instructions"], "system");
        assert_eq!(
            body["input"],
            serde_json::json!([{"role": "user", "content": [{"type": "input_text", "text": "user"}]}])
        );
        let body = serde_json::to_value(CodexResponseRequest::new("m", Some("high"), "i", "u")).unwrap();
        assert_eq!(body["reasoning"]["effort"], "high");
    }
}
