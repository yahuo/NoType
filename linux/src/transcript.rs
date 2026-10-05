//! Port of TranscriptFormatter.swift: spoken line-break commands and whitespace cleanup.

const SPOKEN_REPLACEMENTS: [(&str, &str); 2] = [("新段落", "\n\n"), ("换行", "\n")];

pub fn normalize(text: &str) -> String {
    let mut value = text.trim().to_owned();
    for (spoken, replacement) in SPOKEN_REPLACEMENTS {
        value = value.replace(spoken, replacement);
    }
    let value = collapse_empty_lines(&collapse_spaces(&value));
    value.trim().to_owned()
}

/// Foundation's `CharacterSet.newlines`; each one splits a line, so `\r\n` yields an empty line.
fn is_newline(character: char) -> bool {
    matches!(
        character,
        '\n' | '\u{0B}' | '\u{0C}' | '\r' | '\u{85}' | '\u{2028}' | '\u{2029}'
    )
}

/// Replaces runs of two or more whitespace characters within each line with one space.
fn collapse_spaces(text: &str) -> String {
    text.split(is_newline).map(collapse_line).collect::<Vec<_>>().join("\n")
}

fn collapse_line(line: &str) -> String {
    let mut output = String::with_capacity(line.len());
    let mut run = String::new();
    for character in line.chars() {
        if character.is_whitespace() {
            run.push(character);
            continue;
        }
        flush_run(&mut output, &mut run);
        output.push(character);
    }
    flush_run(&mut output, &mut run);
    output
}

fn flush_run(output: &mut String, run: &mut String) {
    if run.chars().nth(1).is_some() {
        output.push(' ');
    } else {
        output.push_str(run);
    }
    run.clear();
}

/// Caps blank lines: three or more consecutive `\n` become two.
fn collapse_empty_lines(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut newlines = 0;
    for character in text.chars() {
        if character == '\n' {
            newlines += 1;
            if newlines <= 2 {
                output.push('\n');
            }
        } else {
            newlines = 0;
            output.push(character);
        }
    }
    output
}

#[cfg(test)]
mod tests {
    use super::normalize;

    #[test]
    fn maps_spoken_commands_and_collapses_whitespace() {
        assert_eq!(
            normalize("  你好  换行   世界   新段落  测试  "),
            "你好 \n 世界 \n\n 测试"
        );
    }

    #[test]
    fn caps_consecutive_paragraph_breaks() {
        assert_eq!(normalize("一新段落新段落二"), "一\n\n二");
        assert_eq!(normalize("一换行换行换行二"), "一\n\n二");
    }

    #[test]
    fn keeps_single_spaces_and_collapses_mixed_whitespace() {
        assert_eq!(normalize("hello world"), "hello world");
        assert_eq!(normalize("hello \t\u{3000}world"), "hello world");
        assert_eq!(normalize("a\tb"), "a\tb");
    }

    #[test]
    fn trims_and_handles_empty_input() {
        assert_eq!(normalize(""), "");
        assert_eq!(normalize(" \n\t "), "");
        assert_eq!(normalize("新段落"), "");
        assert_eq!(normalize("\n文本\n"), "文本");
    }

    #[test]
    fn splits_carriage_return_line_feed_like_foundation() {
        assert_eq!(normalize("a\r\nb"), "a\n\nb");
        assert_eq!(normalize("a\r\n\r\nb"), "a\n\nb");
    }
}
