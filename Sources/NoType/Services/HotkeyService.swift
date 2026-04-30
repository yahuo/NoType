import Carbon
import Foundation

enum HotkeyServiceError: LocalizedError {
    case eventHandlerInstallFailed(OSStatus)
    case primaryRegistrationFailed(OSStatus)
    case cancelRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallFailed(let status):
            "Unable to install the global hotkey event handler (\(status))."
        case .primaryRegistrationFailed(let status):
            "Unable to register global hotkey Option + Space (\(status)). It may already be in use by macOS or another app."
        case .cancelRegistrationFailed(let status):
            "Unable to register the cancel hotkey Option + Esc (\(status))."
        }
    }
}

struct HotkeyRegistrationResult {
    let warningMessage: String?
}

final class HotkeyService {
    var eventHandler: ((NoTypeHotkeyEvent) -> Void)?

    private var eventHandlerRef: EventHandlerRef?
    private var primaryHotKeyRef: EventHotKeyRef?
    private var translationHotKeyRef: EventHotKeyRef?
    private var cancelHotKeyRef: EventHotKeyRef?
    private var phase: DictationPhase = .idle

    deinit {
        unregisterHotkeys()
    }

    func register() throws -> HotkeyRegistrationResult {
        try ensureEventHandlerInstalled()
        unregisterHotkeys()

        let primaryID = EventHotKeyID(signature: Self.signature, id: 1)
        primaryHotKeyRef = nil
        let primaryStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey),
            primaryID,
            GetApplicationEventTarget(),
            0,
            &primaryHotKeyRef
        )
        guard primaryStatus == noErr else {
            primaryHotKeyRef = nil
            throw HotkeyServiceError.primaryRegistrationFailed(primaryStatus)
        }

        let translationID = EventHotKeyID(signature: Self.signature, id: 3)
        translationHotKeyRef = nil
        let translationStatus = RegisterEventHotKey(
            UInt32(kVK_Space),
            UInt32(optionKey | shiftKey),
            translationID,
            GetApplicationEventTarget(),
            0,
            &translationHotKeyRef
        )

        let cancelID = EventHotKeyID(signature: Self.signature, id: 2)
        cancelHotKeyRef = nil
        let cancelStatus = RegisterEventHotKey(
            UInt32(kVK_Escape),
            UInt32(optionKey),
            cancelID,
            GetApplicationEventTarget(),
            0,
            &cancelHotKeyRef
        )

        let result = Self.registrationResult(
            translationStatus: translationStatus,
            cancelStatus: cancelStatus
        )
        if translationStatus != noErr {
            translationHotKeyRef = nil
        }
        if cancelStatus != noErr {
            cancelHotKeyRef = nil
        }
        return result
    }

    func update(phase: DictationPhase) {
        self.phase = phase
    }

    private func ensureEventHandlerInstalled() throws {
        guard eventHandlerRef == nil else { return }

        var eventSpec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let userData = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, eventRef, userData in
                guard let userData else { return noErr }
                let service = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                return service.handle(eventRef: eventRef)
            },
            1,
            &eventSpec,
            userData,
            &eventHandlerRef
        )

        guard status == noErr else {
            eventHandlerRef = nil
            throw HotkeyServiceError.eventHandlerInstallFailed(status)
        }
    }

    private func unregisterHotkeys() {
        if let primaryHotKeyRef {
            UnregisterEventHotKey(primaryHotKeyRef)
            self.primaryHotKeyRef = nil
        }

        if let translationHotKeyRef {
            UnregisterEventHotKey(translationHotKeyRef)
            self.translationHotKeyRef = nil
        }

        if let cancelHotKeyRef {
            UnregisterEventHotKey(cancelHotKeyRef)
            self.cancelHotKeyRef = nil
        }
    }

    private func handle(eventRef: EventRef?) -> OSStatus {
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            return status
        }

        switch hotKeyID.id {
        case 1:
            eventHandler?(NoTypeAppModel.hotkeyAction(for: phase, requestedMode: .dictation))
        case 2:
            eventHandler?(.cancelDictation)
        case 3:
            eventHandler?(NoTypeAppModel.hotkeyAction(for: phase, requestedMode: .translation))
        default:
            break
        }

        return noErr
    }

    private static let signature = fourCharCode("NTYP")

    static func registrationResult(
        translationStatus: OSStatus,
        cancelStatus: OSStatus
    ) -> HotkeyRegistrationResult {
        var warnings: [String] = []
        if translationStatus != noErr {
            warnings.append("Unable to register translation hotkey Option + Shift + Space (\(translationStatus)).")
        }
        if cancelStatus != noErr {
            warnings.append(HotkeyServiceError.cancelRegistrationFailed(cancelStatus).errorDescription ?? "")
        }

        return HotkeyRegistrationResult(warningMessage: warnings.isEmpty ? nil : warnings.joined(separator: "\n"))
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
