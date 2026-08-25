import ApplicationServices
import AppKit
import Carbon
import Foundation

enum TripleSpaceFieldValuePollResult: Equatable {
    case waiting
    case ready(String)
    case timedOut
}

struct TripleSpaceFieldValuePoller {
    private let maximumAttempts: Int
    private var attemptCount = 0

    init(maximumAttempts: Int) {
        precondition(maximumAttempts > 0)
        self.maximumAttempts = maximumAttempts
    }

    mutating func consume(_ fieldValue: String?) -> TripleSpaceFieldValuePollResult {
        attemptCount += 1

        if let fieldValue,
           let sourceText = TextInsertionService.tripleSpaceTranslationSource(from: fieldValue) {
            return .ready(sourceText)
        }

        return attemptCount < maximumAttempts ? .waiting : .timedOut
    }
}

enum TextInsertionServiceError: LocalizedError {
    case pasteCommandSynthesisFailed

    var errorDescription: String? {
        switch self {
        case .pasteCommandSynthesisFailed:
            return "Unable to synthesize the paste command."
        }
    }
}

@MainActor
final class TextInsertionService {
    private let inputSourceService: InputSourceService
    private let pasteboard: NSPasteboard

    init(
        inputSourceService: InputSourceService = InputSourceService(),
        pasteboard: NSPasteboard = .general
    ) {
        self.inputSourceService = inputSourceService
        self.pasteboard = pasteboard
    }

    func insert(_ text: String) async throws -> TextInsertionOutcome {
        let context = DictationTargetContext.currentFrontmost()
        guard Self.shouldInsert(text) else {
            return .skipped(context)
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard Self.hasEditableTextFocus() else {
            return .copiedToClipboard(context)
        }

        let inputSourceSession = inputSourceService.prepareForPasteIfNeeded()
        defer { inputSourceService.restore(inputSourceSession) }

        if inputSourceSession != nil {
            try? await Task.sleep(for: .milliseconds(80))
        }

        try postPasteCommand()
        try await Task.sleep(for: .milliseconds(250))

        if Self.shouldRestorePasteboard(
            currentChangeCount: pasteboard.changeCount,
            insertedChangeCount: insertedChangeCount
        ) {
            snapshot.restore(to: pasteboard)
        }

        return .pasted(context)
    }

    func selectedText() async -> String? {
        if let axText = Self.currentSelectedTextViaAccessibility(), !axText.trimmed.isEmpty {
            return axText
        }

        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        defer { snapshot.restore(to: pasteboard) }

        pasteboard.clearContents()
        guard postKeyboardCommand(virtualKey: CGKeyCode(kVK_ANSI_C), flags: .maskCommand) else {
            return nil
        }

        try? await Task.sleep(for: .milliseconds(160))
        guard let copiedText = pasteboard.string(forType: .string), !copiedText.trimmed.isEmpty else {
            return nil
        }
        return copiedText
    }

    func prepareFocusedFieldForTripleSpaceTranslation() async -> String? {
        guard
            let focusedElement = Self.currentFocusedUIElement(),
            Self.isEditableTextElement(focusedElement),
            !Self.isSecureTextElement(focusedElement)
        else {
            return nil
        }

        var valuePoller = TripleSpaceFieldValuePoller(maximumAttempts: 16)
        let sourceText: String
        valuePolling: while true {
            let fieldValue = Self.copyStringAttribute(
                kAXValueAttribute as CFString,
                from: focusedElement
            )

            switch valuePoller.consume(fieldValue) {
            case let .ready(value):
                sourceText = value
                break valuePolling
            case .waiting:
                // Event taps observe keyDown before rich editors publish the character through AX.
                try? await Task.sleep(for: .milliseconds(20))
                guard Self.isStillFocused(focusedElement) else {
                    return nil
                }
            case .timedOut:
                return nil
            }
        }

        guard Self.isStillFocused(focusedElement) else { return nil }
        for _ in 0..<3 {
            guard postKeyboardCommand(virtualKey: CGKeyCode(kVK_Delete), flags: []) else {
                return nil
            }
        }

        try? await Task.sleep(for: .milliseconds(40))
        guard Self.isStillFocused(focusedElement) else { return nil }
        guard postKeyboardCommand(virtualKey: CGKeyCode(kVK_ANSI_A), flags: .maskCommand) else {
            return nil
        }

        try? await Task.sleep(for: .milliseconds(80))
        guard Self.isStillFocused(focusedElement) else { return nil }
        return sourceText
    }

    nonisolated static func shouldInsert(_ text: String) -> Bool {
        !text.trimmed.isEmpty
    }

    nonisolated static func tripleSpaceTranslationSource(from fieldValue: String) -> String? {
        guard fieldValue.hasSuffix("   ") else { return nil }
        let sourceText = String(fieldValue.dropLast(3))
        return sourceText.trimmed.isEmpty ? nil : sourceText
    }

    nonisolated static func shouldRestorePasteboard(currentChangeCount: Int, insertedChangeCount: Int) -> Bool {
        currentChangeCount == insertedChangeCount
    }

    nonisolated static func hasEditableTextFocus() -> Bool {
        guard let focusedElement = currentFocusedUIElement() else { return false }
        return isEditableTextElement(focusedElement)
    }

    private nonisolated static func isEditableTextElement(_ focusedElement: AXUIElement) -> Bool {
        if let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement),
           editableRoles.contains(role) {
            return true
        }

        var settable = DarwinBoolean(false)
        if AXUIElementIsAttributeSettable(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            return true
        }

        if AXUIElementIsAttributeSettable(
            focusedElement,
            kAXValueAttribute as CFString,
            &settable
        ) == .success, settable.boolValue {
            return true
        }

        var selectedRange: CFTypeRef?
        let rangeResult = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )
        return rangeResult == .success
    }

    nonisolated static func currentSelectedTextViaAccessibility() -> String? {
        guard let focusedElement = currentFocusedUIElement() else { return nil }
        return copyStringAttribute(kAXSelectedTextAttribute as CFString, from: focusedElement)
    }

    private nonisolated static func currentFocusedUIElement() -> AXUIElement? {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success, let focusedValue else {
            return nil
        }

        return (focusedValue as! AXUIElement)
    }

    private nonisolated static func isSecureTextElement(_ element: AXUIElement) -> Bool {
        copyStringAttribute(kAXSubroleAttribute as CFString, from: element)
            == kAXSecureTextFieldSubrole as String
    }

    private nonisolated static func isStillFocused(_ element: AXUIElement) -> Bool {
        guard let currentElement = currentFocusedUIElement() else { return false }
        return CFEqual(element, currentElement)
    }

    private func postPasteCommand() throws {
        guard postKeyboardCommand(virtualKey: CGKeyCode(kVK_ANSI_V), flags: .maskCommand) else {
            throw TextInsertionServiceError.pasteCommandSynthesisFailed
        }
    }

    private func postKeyboardCommand(virtualKey: CGKeyCode, flags: CGEventFlags) -> Bool {
        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: virtualKey, keyDown: false)
        else {
            return false
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private nonisolated static let editableRoles: Set<String> = [
        kAXTextAreaRole as String,
        kAXTextFieldRole as String,
        kAXComboBoxRole as String,
        kAXSearchFieldSubrole as String,
    ]

    private nonisolated static func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else {
            return nil
        }
        return value as? String
    }
}

private struct PasteboardSnapshot {
    private let items: [[NSPasteboard.PasteboardType: Data]]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
        let storedItems: [[NSPasteboard.PasteboardType: Data]] = pasteboard.pasteboardItems?.map { item in
            var values: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                guard let data = item.data(forType: type) else { continue }
                values[type] = data
            }
            return values
        } ?? []
        return PasteboardSnapshot(items: storedItems)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }

        let restoredItems = items.map { itemValues -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemValues {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restoredItems)
    }
}
