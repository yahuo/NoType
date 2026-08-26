import Foundation

public enum NoTypeEditorBufferPath {
    public static func supports(_ url: URL) -> Bool {
        isClaude(url) || isCodex(url)
    }

    public static func isClaude(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let prefix = "claude-prompt-"
        guard url.pathExtension.lowercased() == "md",
              name.hasPrefix(prefix),
              url.deletingLastPathComponent().lastPathComponent.hasPrefix("claude-")
        else {
            return false
        }

        let identifier = String(name.dropFirst(prefix.count).dropLast(3))
        return UUID(uuidString: identifier) != nil
    }

    private static func isCodex(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        let parent = url.deletingLastPathComponent()
        return url.pathExtension.lowercased() == "md"
            && name.hasPrefix(".tmp")
            && parent.lastPathComponent == "editor"
            && parent.deletingLastPathComponent().lastPathComponent == ".codex"
    }
}

public struct NoTypeEditorBuffer: Equatable {
    public static let claudeReplyMarkerPrefix = "# ─── Write your reply below this line"

    public let preservedPrefix: String
    public let sourceText: String
    public let trailingLineEndings: String

    public static func parseTriggeredBuffer(_ content: String) -> NoTypeEditorBuffer? {
        let editableRange = editableDraftRange(in: content)
        let draft = content[editableRange]

        var bodyEnd = draft.endIndex
        while bodyEnd > draft.startIndex {
            let previous = draft.index(before: bodyEnd)
            let character = draft[previous]
            guard character == "\n" || character == "\r" else { break }
            bodyEnd = previous
        }

        let body = draft[..<bodyEnd]
        guard body.hasSuffix("   ") else { return nil }

        let source = String(body.dropLast(3))
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }

        return NoTypeEditorBuffer(
            preservedPrefix: String(content[..<editableRange.lowerBound]),
            sourceText: source,
            trailingLineEndings: String(draft[bodyEnd...])
        )
    }

    public func replacingSource(with translatedText: String) -> String {
        preservedPrefix + translatedText + trailingLineEndings
    }

    private static func editableDraftRange(in content: String) -> Range<String.Index> {
        guard let markerRange = content.range(of: claudeReplyMarkerPrefix),
              markerRange.lowerBound == content.startIndex
                || content[content.index(before: markerRange.lowerBound)] == "\n"
        else {
            return content.startIndex..<content.endIndex
        }

        guard let markerLineEnd = content[markerRange.upperBound...].firstIndex(of: "\n") else {
            return content.endIndex..<content.endIndex
        }

        var draftStart = content.index(after: markerLineEnd)
        if draftStart < content.endIndex, content[draftStart] == "\n" {
            draftStart = content.index(after: draftStart)
        }
        return draftStart..<content.endIndex
    }
}
