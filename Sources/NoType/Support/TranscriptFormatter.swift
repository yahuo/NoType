import Foundation

enum TranscriptFormatter {
    static func normalize(_ transcript: String) -> String {
        var value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)

        let replacements: [(String, String)] = [
            ("新段落", "\n\n"),
            ("换行", "\n"),
        ]

        for (spoken, replacement) in replacements {
            value = value.replacingOccurrences(of: spoken, with: replacement)
        }

        value = collapseSpaces(in: value)
        value = collapseEmptyLines(in: value)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseSpaces(in text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        let normalized = lines.map { line in
            line.replacingOccurrences(
                of: #"\s{2,}"#,
                with: " ",
                options: .regularExpression
            )
        }
        return normalized.joined(separator: "\n")
    }

    private static func collapseEmptyLines(in text: String) -> String {
        text.replacingOccurrences(
            of: #"\n{3,}"#,
            with: "\n\n",
            options: .regularExpression
        )
    }
}
