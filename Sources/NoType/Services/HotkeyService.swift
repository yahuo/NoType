import AppKit
import Carbon
import Foundation

enum HotkeyServiceError: LocalizedError {
    case eventHandlerInstallFailed(OSStatus)
    case primaryRegistrationFailed(HotkeyOption, OSStatus)
    case cancelRegistrationFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .eventHandlerInstallFailed(let status):
            "Unable to install the global hotkey event handler (\(status))."
        case .primaryRegistrationFailed(let hotkey, let status):
            "Unable to register global hotkey \(hotkey.displayName) (\(status)). It may already be in use by macOS or another app."
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
    private var cancelHotKeyRef: EventHotKeyRef?
    private var phase: DictationPhase = .idle

    init() {}

    deinit {
        unregisterHotkeys()
    }

    func register(using settings: AppSettings) throws -> HotkeyRegistrationResult {
        try ensureEventHandlerInstalled()
        unregisterHotkeys()

        let primaryID = EventHotKeyID(signature: Self.signature, id: 1)
        let primaryStatus = RegisterEventHotKey(
            settings.hotkey.keyCode,
            settings.hotkey.carbonModifiers,
            primaryID,
            GetApplicationEventTarget(),
            0,
            &primaryHotKeyRef
        )
        guard primaryStatus == noErr else {
            primaryHotKeyRef = nil
            throw HotkeyServiceError.primaryRegistrationFailed(settings.hotkey, primaryStatus)
        }

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
        let result = try Self.registrationResult(
            primaryStatus: primaryStatus,
            cancelStatus: cancelStatus,
            hotkey: settings.hotkey
        )
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
                let hotkeyService = Unmanaged<HotkeyService>.fromOpaque(userData).takeUnretainedValue()
                return hotkeyService.handle(eventRef: eventRef)
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
            switch phase {
            case .recording:
                eventHandler?(.stopDictation)
            case .processing:
                eventHandler?(.cancelDictation)
            default:
                eventHandler?(.startDictation)
            }
        case 2:
            eventHandler?(.cancelDictation)
        default:
            break
        }

        return noErr
    }

    private static let signature = fourCharCode("NTYP")

    static func registrationResult(
        primaryStatus: OSStatus,
        cancelStatus: OSStatus,
        hotkey: HotkeyOption
    ) throws -> HotkeyRegistrationResult {
        guard primaryStatus == noErr else {
            throw HotkeyServiceError.primaryRegistrationFailed(hotkey, primaryStatus)
        }

        if cancelStatus != noErr {
            return HotkeyRegistrationResult(
                warningMessage: HotkeyServiceError.cancelRegistrationFailed(cancelStatus).errorDescription
            )
        }

        return HotkeyRegistrationResult(warningMessage: nil)
    }

    private static func fourCharCode(_ string: String) -> OSType {
        string.utf8.reduce(0) { ($0 << 8) + OSType($1) }
    }
}
