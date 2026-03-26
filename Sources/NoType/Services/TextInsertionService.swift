import ApplicationServices
import AppKit
import Foundation

@MainActor
final class TextInsertionService {
    func insert(_ text: String) throws -> DictationTargetContext {
        let context = DictationTargetContext.currentFrontmost()
        guard Self.shouldInsert(text) else {
            return context
        }

        if try directInsert(text) {
            return context
        }

        try pasteFallback(text)
        return context
    }

    private func directInsert(_ text: String) throws -> Bool {
        let systemElement = AXUIElementCreateSystemWide()
        var focusedValue: CFTypeRef?
        let focusedResult = AXUIElementCopyAttributeValue(
            systemElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )

        guard focusedResult == .success, let focusedElement = focusedValue else {
            return false
        }

        let element = focusedElement as! AXUIElement

        var valueSettable = DarwinBoolean(false)
        let canSetValue = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &valueSettable)
        if canSetValue == .success, valueSettable.boolValue {
            guard
                let currentValue = copyStringAttribute(kAXValueAttribute as CFString, from: element),
                let selectedRange = copyRangeAttribute(kAXSelectedTextRangeAttribute as CFString, from: element)
            else {
                return false
            }

            let nsValue = currentValue as NSString
            let replacementRange = NSRange(location: selectedRange.location, length: selectedRange.length)
            let updatedValue = nsValue.replacingCharacters(in: replacementRange, with: text)

            let setValueResult = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                updatedValue as CFTypeRef
            )
            guard setValueResult == .success else {
                return false
            }

            var cursor = CFRange(location: replacementRange.location + (text as NSString).length, length: 0)
            if let value = AXValueCreate(.cfRange, &cursor) {
                AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value)
            }
            return true
        }

        var selectedTextSettable = DarwinBoolean(false)
        let canSetSelectedText = AXUIElementIsAttributeSettable(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedTextSettable
        )
        if canSetSelectedText == .success, selectedTextSettable.boolValue {
            let result = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            return result == .success
        }

        return false
    }

    private func pasteFallback(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let insertedChangeCount = pasteboard.changeCount

        guard
            let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: false)
        else {
            throw ASRProviderError.transport("Unable to synthesize paste command.")
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard Self.shouldRestorePasteboard(
                currentChangeCount: pasteboard.changeCount,
                insertedChangeCount: insertedChangeCount
            ) else {
                return
            }
            snapshot.restore(to: pasteboard)
        }
    }

    nonisolated static func shouldInsert(_ text: String) -> Bool {
        !text.trimmed.isEmpty
    }

    nonisolated static func shouldRestorePasteboard(currentChangeCount: Int, insertedChangeCount: Int) -> Bool {
        currentChangeCount == insertedChangeCount
    }

    private func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func copyRangeAttribute(_ attribute: CFString, from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }
        let axValue = value as! AXValue
        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }
        return range
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
        let recreated = items.map { itemMap -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in itemMap {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(recreated)
    }
}
