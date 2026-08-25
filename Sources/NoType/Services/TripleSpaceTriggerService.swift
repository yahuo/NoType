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

struct TripleSpaceSequenceDetector {
    private let maximumDuration: TimeInterval
    private var firstTimestamp: TimeInterval?
    private var spaceCount = 0

    init(maximumDuration: TimeInterval = 1.0) {
        self.maximumDuration = maximumDuration
    }

    mutating func consume(
        isPlainSpace: Bool,
        isRepeat: Bool,
        timestamp: TimeInterval
    ) -> Bool {
        guard isPlainSpace, !isRepeat else {
            reset()
            return false
        }

        if let firstTimestamp,
           timestamp >= firstTimestamp,
           timestamp - firstTimestamp <= maximumDuration {
            spaceCount += 1
        } else {
            firstTimestamp = timestamp
            spaceCount = 1
        }

        guard spaceCount == 3 else { return false }
        reset()
        return true
    }

    mutating func reset() {
        firstTimestamp = nil
        spaceCount = 0
    }
}

final class TripleSpaceTriggerService {
    var eventHandler: (() -> Void)?

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

        let disallowedModifiers: CGEventFlags = [
            .maskShift,
            .maskControl,
            .maskAlternate,
            .maskCommand,
            .maskSecondaryFn,
        ]
        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let isPlainSpace = keyCode == CGKeyCode(kVK_Space)
            && event.flags.intersection(disallowedModifiers).isEmpty
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000

        if detector.consume(
            isPlainSpace: isPlainSpace,
            isRepeat: isRepeat,
            timestamp: timestamp
        ) {
            eventHandler?()
        }
    }

    private static let eventMask: CGEventMask = [
        CGEventType.keyDown,
        .leftMouseDown,
        .rightMouseDown,
        .otherMouseDown,
    ].reduce(0) { mask, eventType in
        mask | (CGEventMask(1) << eventType.rawValue)
    }
}
