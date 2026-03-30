import Carbon
import Foundation

struct InputSourceRestoreSession {
    let source: TISInputSource
}

final class InputSourceService {
    func prepareForPasteIfNeeded() -> InputSourceRestoreSession? {
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }

        guard Self.shouldSwitchToASCII(current) else {
            return nil
        }

        guard let asciiSource = Self.findASCIICapableSource() else {
            return nil
        }

        guard TISSelectInputSource(asciiSource) == noErr else {
            return nil
        }

        return InputSourceRestoreSession(source: current)
    }

    func restore(_ session: InputSourceRestoreSession?) {
        guard let session else { return }
        _ = TISSelectInputSource(session.source)
    }

    static func shouldSwitchToASCII(_ source: TISInputSource) -> Bool {
        isCJKInputSource(
            languages: arrayProperty(kTISPropertyInputSourceLanguages, from: source),
            inputSourceID: stringProperty(kTISPropertyInputSourceID, from: source) ?? "",
            inputModeID: stringProperty(kTISPropertyInputModeID, from: source)
        )
    }

    static func isCJKInputSource(
        languages: [String],
        inputSourceID: String,
        inputModeID: String?
    ) -> Bool {
        if languages.contains(where: isCJKLanguage) {
            return true
        }

        let descriptor = "\(inputSourceID) \(inputModeID ?? "")".lowercased()
        let markers = [
            "pinyin",
            "zhuyin",
            "cangjie",
            "wubi",
            "stroke",
            "hiragana",
            "katakana",
            "korean",
            "hangul",
            "japanese",
            "japaneseim",
            "shuangpin",
        ]
        return markers.contains { descriptor.contains($0) }
    }

    static func isCJKLanguage(_ languageCode: String) -> Bool {
        let normalized = languageCode.lowercased()
        return normalized.hasPrefix("zh") || normalized.hasPrefix("ja") || normalized.hasPrefix("ko")
    }

    private static func findASCIICapableSource() -> TISInputSource? {
        let properties: [String: Any] = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as Any,
            kTISPropertyInputSourceIsASCIICapable as String: kCFBooleanTrue as Any,
        ]

        guard let list = TISCreateInputSourceList(properties as CFDictionary, false)?.takeRetainedValue() else {
            return nil
        }

        let sources = (list as NSArray).map { $0 as! TISInputSource }

        if let abc = sources.first(where: { stringProperty(kTISPropertyInputSourceID, from: $0) == "com.apple.keylayout.ABC" }) {
            return abc
        }

        if let us = sources.first(where: { stringProperty(kTISPropertyInputSourceID, from: $0) == "com.apple.keylayout.US" }) {
            return us
        }

        return sources.first
    }

    private static func stringProperty(_ key: CFString, from source: TISInputSource) -> String? {
        guard let rawValue = TISGetInputSourceProperty(source, key) else {
            return nil
        }
        return unsafeBitCast(rawValue, to: CFTypeRef.self) as? String
    }

    private static func arrayProperty(_ key: CFString, from source: TISInputSource) -> [String] {
        guard let rawValue = TISGetInputSourceProperty(source, key) else {
            return []
        }
        return unsafeBitCast(rawValue, to: CFTypeRef.self) as? [String] ?? []
    }
}
