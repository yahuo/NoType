//! Port of NoTypeEditorCore/EditorBuffer.swift.

use std::path::Path;

use crate::agent_editor::{HOTKEY_TRIGGER, is_uuid_string};

const CLAUDE_PROMPT_PREFIX: &str = "claude-prompt-";

/// Claude Code (`claude-*/claude-prompt-<uuid>.md`) or Codex CLI (`.codex/editor/.tmp*.md`).
pub fn is_supported_buffer(path: &Path) -> bool {
    is_claude_buffer(path) || is_codex_buffer(path)
}

pub fn is_claude_buffer(path: &Path) -> bool {
    let Some(name) = file_name(path) else { return false };
    if !has_markdown_extension(path)
        || !name.starts_with(CLAUDE_PROMPT_PREFIX)
        || !path.parent().and_then(file_name).is_some_and(|parent| parent.starts_with("claude-"))
    {
        return false;
    }
    name.get(CLAUDE_PROMPT_PREFIX.len()..name.len().saturating_sub(3))
        .is_some_and(is_uuid_string)
}

fn is_codex_buffer(path: &Path) -> bool {
    let parent = path.parent();
    has_markdown_extension(path)
        && file_name(path).is_some_and(|name| name.starts_with(".tmp"))
        && parent.and_then(file_name) == Some("editor")
        && parent.and_then(Path::parent).and_then(file_name) == Some(".codex")
}

fn file_name(path: &Path) -> Option<&str> {
    path.file_name()?.to_str()
}

fn has_markdown_extension(path: &Path) -> bool {
    path.extension().is_some_and(|extension| extension.eq_ignore_ascii_case("md"))
}

/// Swift `Character.isNewline`; `\r\n` is handled as one unit by the callers.
fn is_newline(character: char) -> bool {
    matches!(character, '\n' | '\r' | '\u{0B}' | '\u{0C}' | '\u{85}' | '\u{2028}' | '\u{2029}')
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct EditorBuffer {
    pub preserved_prefix: String,
    pub source_text: String,
    pub trailing_line_endings: String,
}

impl EditorBuffer {
    pub const CLAUDE_REPLY_MARKER_PREFIX: &'static str = "# ─── Write your reply below this line";

    /// Parses the draft for `trigger`: the hotkey translates the whole draft, while the macOS
    /// triple-space trigger requires and removes exactly three trailing spaces.
    pub fn parse(content: &str, trigger: &str) -> Option<Self> {
        if trigger == HOTKEY_TRIGGER {
            Self::parse_hotkey_buffer(content)
        } else {
            Self::parse_triggered_buffer(content)
        }
    }

    pub fn parse_triggered_buffer(content: &str) -> Option<Self> {
        Self::parse_draft(content, |body| body.strip_suffix("   "))
    }

    pub fn parse_hotkey_buffer(content: &str) -> Option<Self> {
        Self::parse_draft(content, |body| Some(body.trim_end()))
    }

    pub fn replacing_source(&self, translated_text: &str) -> String {
        format!("{}{}{}", self.preserved_prefix, translated_text, self.trailing_line_endings)
    }

    fn parse_draft(content: &str, source: impl FnOnce(&str) -> Option<&str>) -> Option<Self> {
        let start = editable_draft_start(content);
        let draft = &content[start..];
        let body_end = draft.trim_end_matches(is_newline).len();
        let (body, trailing) = draft.split_at(body_end);
        let source = source(body)?;
        if source.trim().is_empty() {
            return None;
        }
        Some(Self {
            preserved_prefix: content[..start].to_owned(),
            source_text: source.to_owned(),
            trailing_line_endings: trailing.to_owned(),
        })
    }
}

/// Byte offset of the editable reply: after Claude's response context, or the whole buffer.
fn editable_draft_start(content: &str) -> usize {
    let Some(marker) = content.find(EditorBuffer::CLAUDE_REPLY_MARKER_PREFIX) else {
        return 0;
    };
    if marker > 0 && !content[..marker].chars().next_back().is_some_and(is_newline) {
        return 0;
    }
    let marker_end = marker + EditorBuffer::CLAUDE_REPLY_MARKER_PREFIX.len();
    let Some(line_end) = content[marker_end..].find(is_newline) else {
        return content.len();
    };
    let mut draft_start = after_newline(content, marker_end + line_end);
    if content[draft_start..].starts_with(is_newline) {
        draft_start = after_newline(content, draft_start);
    }
    draft_start
}

fn after_newline(content: &str, index: usize) -> usize {
    let rest = &content[index..];
    if rest.starts_with("\r\n") {
        index + 2
    } else {
        index + rest.chars().next().map_or(0, char::len_utf8)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_only_claude_and_codex_temporary_markdown_paths() {
        let claude = Path::new("/tmp/claude-501/claude-prompt-2c259eaf-686d-4be3-8b30-f4728fed6ca0.md");
        let codex = Path::new("/Users/test/.codex/editor/.tmpAbCd.md");
        let unsupported = Path::new("/tmp/project/notes.md");

        assert!(is_supported_buffer(claude));
        assert!(is_claude_buffer(claude));
        assert!(is_supported_buffer(codex));
        assert!(!is_claude_buffer(codex));
        assert!(!is_supported_buffer(unsupported));

        assert!(is_claude_buffer(Path::new("/tmp/claude-1000/claude-prompt-2C259EAF-686D-4BE3-8B30-F4728FED6CA0.MD")));
        assert!(!is_claude_buffer(Path::new("/tmp/claude-501/claude-prompt-2c259eaf686d4be38b30f4728fed6ca0.md")));
        assert!(!is_claude_buffer(Path::new("/tmp/other/claude-prompt-2c259eaf-686d-4be3-8b30-f4728fed6ca0.md")));
        assert!(!is_claude_buffer(Path::new("/tmp/claude-501/claude-prompt-.md")));
        assert!(!is_supported_buffer(Path::new("/home/test/.codex/editor/.tmpAbCd.txt")));
        assert!(!is_supported_buffer(Path::new("/home/test/codex/editor/.tmpAbCd.md")));
    }

    #[test]
    fn parses_raw_codex_draft_and_preserves_its_final_newline() {
        for line_ending in ["\n", "\r\n"] {
            let buffer = EditorBuffer::parse_triggered_buffer(&format!("第一行\n第二行   {line_ending}")).unwrap();
            assert!(buffer.preserved_prefix.is_empty());
            assert_eq!(buffer.source_text, "第一行\n第二行");
            assert_eq!(buffer.trailing_line_endings, line_ending);
            assert_eq!(
                buffer.replacing_source("First line\nSecond line"),
                format!("First line\nSecond line{line_ending}")
            );
        }
    }

    fn claude_prefix(line_ending: &str) -> String {
        let context = "# ─── Claude's last response (for reference; removed on save) ───\n\
                       # I updated the parser and added its tests.\n\
                       # ─── Write your reply below this line ──────────────────────────";
        format!("{}{line_ending}{line_ending}", context.replace('\n', line_ending))
    }

    #[test]
    fn preserves_claude_response_context_and_replaces_only_the_reply() {
        for line_ending in ["\n", "\r\n"] {
            let prefix = claude_prefix(line_ending);
            let buffer = EditorBuffer::parse_triggered_buffer(&format!("{prefix}请继续检查边界情况   ")).unwrap();
            assert_eq!(buffer.source_text, "请继续检查边界情况");
            assert_eq!(buffer.preserved_prefix, prefix);
            assert_eq!(
                buffer.replacing_source("Please continue checking edge cases."),
                format!("{prefix}Please continue checking edge cases.")
            );
        }
    }

    #[test]
    fn requires_trailing_trigger_spaces_and_removes_exactly_three() {
        assert_eq!(EditorBuffer::parse_triggered_buffer("draft  "), None);
        assert_eq!(EditorBuffer::parse_triggered_buffer("draft    ").unwrap().source_text, "draft ");
        assert_eq!(EditorBuffer::parse_triggered_buffer("   "), None);
    }

    #[test]
    fn hotkey_translates_the_whole_draft_without_trailing_whitespace() {
        let buffer = EditorBuffer::parse("  第一行\n第二行 \t\n\n", HOTKEY_TRIGGER).unwrap();
        assert_eq!(buffer.source_text, "  第一行\n第二行");
        assert_eq!(buffer.trailing_line_endings, "\n\n");
        assert_eq!(buffer.replacing_source("Lines"), "Lines\n\n");

        let prefix = claude_prefix("\r\n");
        let buffer = EditorBuffer::parse(&format!("{prefix}请继续   \r\n"), HOTKEY_TRIGGER).unwrap();
        assert_eq!(buffer.preserved_prefix, prefix);
        assert_eq!(buffer.source_text, "请继续");
        assert_eq!(buffer.trailing_line_endings, "\r\n");

        assert_eq!(EditorBuffer::parse(" \n\n", HOTKEY_TRIGGER), None);
        assert_eq!(EditorBuffer::parse(&claude_prefix("\n"), HOTKEY_TRIGGER), None);
        assert_eq!(EditorBuffer::parse("draft", "triple-space"), None);
    }

    #[test]
    fn marker_must_start_a_line_and_may_end_the_buffer() {
        let marker = EditorBuffer::CLAUDE_REPLY_MARKER_PREFIX;
        let inline = format!("quote {marker}\nreply   ");
        assert_eq!(EditorBuffer::parse_triggered_buffer(&inline).unwrap().preserved_prefix, "");
        assert_eq!(EditorBuffer::parse_triggered_buffer(&format!("{marker} ───")), None);
        let single_newline = EditorBuffer::parse_triggered_buffer(&format!("{marker}\nreply   ")).unwrap();
        assert_eq!(single_newline.preserved_prefix, format!("{marker}\n"));
        assert_eq!(single_newline.source_text, "reply");
    }
}
