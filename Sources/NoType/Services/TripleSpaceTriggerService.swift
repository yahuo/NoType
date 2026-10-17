import Carbon
import CoreGraphics
import Foundation

enum TripleSpaceTriggerServiceError: LocalizedError {
    case eventTapCreationFailed

    var errorDescription: String? {
        switch self {
        case .eventTapCreationFailed:
            "Unable to monitor triple-Space translation. Check the Accessibility permission."
        }
    }
}

enum TripleSpaceSequenceResult: Equatable {
    case pending
    /// Two spaces arrived; the next one triggers translation.
    case armed
    case triggered
}

enum TripleSpaceKey: Equatable {
    case space
    /// An unmodified letter, which a Chinese input method may hold as a composition.
    case letter
    /// Usually corrects a composition rather than ending it.
    case backspace
    case other
}

struct TripleSpaceSequenceDetector {
    private let maximumDuration: TimeInterval
    private var firstTimestamp: TimeInterval?
    private var spaceCount = 0
    private var mayBeComposing = false

    init(maximumDuration: TimeInterval = 1.0) {
        self.maximumDuration = maximumDuration
    }

    mutating func consume(
        key: TripleSpaceKey,
        isRepeat: Bool,
        timestamp: TimeInterval,
        spaceCommitsComposition: @autoclosure () -> Bool = false
    ) -> TripleSpaceSequenceResult {
        guard key == .space, !isRepeat else {
            resetSpaces()
            switch key {
            case .letter:
                mayBeComposing = true
            case .backspace:
                break
            case .space, .other:
                mayBeComposing = false
            }
            return .pending
        }

        // A Chinese input method consumes the Space that commits a candidate, so it
        // never reaches the field and must not count. The cost is one extra Space when
        // English was typed in the input method's ASCII mode right before the trigger.
        // The input source is only queried for a Space that directly follows letters.
        if mayBeComposing {
            mayBeComposing = false
            if spaceCommitsComposition() {
                return .pending
            }
        }

        if let firstTimestamp,
           timestamp >= firstTimestamp,
           timestamp - firstTimestamp <= maximumDuration {
            spaceCount += 1
        } else {
            firstTimestamp = timestamp
            spaceCount = 1
        }

        switch spaceCount {
        case 2:
            return .armed
        case 3:
            resetSpaces()
            return .triggered
        default:
            return .pending
        }
    }

    mutating func reset() {
        resetSpaces()
        mayBeComposing = false
    }

    private mutating func resetSpaces() {
        firstTimestamp = nil
        spaceCount = 0
    }
}

final class TripleSpaceTriggerService {
    var eventHandler: (() -> Void)?
    var armedHandler: (() -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var detector = TripleSpaceSequenceDetector()

    deinit {
        unregister()
    }

    func register() throws {
        guard eventTap == nil else { return }

        let userInfo = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, userInfo in
                guard let userInfo else {
                    return Unmanaged.passUnretained(event)
                }

                let service = Unmanaged<TripleSpaceTriggerService>
                    .fromOpaque(userInfo)
                    .takeUnretainedValue()
                service.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            throw TripleSpaceTriggerServiceError.eventTapCreationFailed
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(nil, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            throw TripleSpaceTriggerServiceError.eventTapCreationFailed
        }

        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func unregister() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }

        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func handle(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            detector.reset()
            return
        }

        guard type == .keyDown else {
            detector.reset()
            return
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000

        switch detector.consume(
            key: Self.key(for: event),
            isRepeat: isRepeat,
            timestamp: timestamp,
            spaceCommitsComposition: InputSourceService.currentSourceCommitsCompositionWithSpace()
        ) {
        case .pending:
            break
        case .armed:
            armedHandler?()
        case .triggered:
            eventHandler?()
        }
    }

    private static func key(for event: CGEvent) -> TripleSpaceKey {
        let disallowedModifiers: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn,
        ]
        let isUnmodified = event.flags.intersection(disallowedModifiers).isEmpty
        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))

        switch keyCode {
        case kVK_Space:
            return isUnmodified ? .space : .other
        case kVK_Delete:
            return isUnmodified ? .backspace : .other
        case _ where letterKeyCodes.contains(keyCode):
            // Caps Lock letters are typed as-is instead of starting a composition.
            return isUnmodified && !event.flags.contains(.maskAlphaShift) ? .letter : .other
        default:
            return .other
        }
    }

    private static let letterKeyCodes: Set<Int> = [
        kVK_ANSI_A, kVK_ANSI_B, kVK_ANSI_C, kVK_ANSI_D, kVK_ANSI_E, kVK_ANSI_F, kVK_ANSI_G,
        kVK_ANSI_H, kVK_ANSI_I, kVK_ANSI_J, kVK_ANSI_K, kVK_ANSI_L, kVK_ANSI_M, kVK_ANSI_N,
        kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_Q, kVK_ANSI_R, kVK_ANSI_S, kVK_ANSI_T, kVK_ANSI_U,
        kVK_ANSI_V, kVK_ANSI_W, kVK_ANSI_X, kVK_ANSI_Y, kVK_ANSI_Z,
    ]

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ].reduce(0) { mask, eventType in
        mask | (CGEventMask(1) << eventType.rawValue)
    }
}
