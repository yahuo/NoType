import AppKit
import Foundation

enum DictationPhase: String, Equatable {
    case onboarding
    case idle
    case recording
    case processing
    case failed
    case inserted

    var hudVisible: Bool {
        switch self {
        case .recording, .processing, .failed, .inserted:
            true
        case .onboarding, .idle:
            false
        }
    }
}

struct PermissionSnapshot: Equatable {
    var microphoneAuthorized: Bool
    var accessibilityAuthorized: Bool

    var ready: Bool {
        microphoneAuthorized && accessibilityAuthorized
    }
}

struct AudioInputDevice: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
}

struct DictationTargetContext: Equatable {
    let bundleIdentifier: String
    let localizedName: String

    static func currentFrontmost() -> DictationTargetContext {
        let app = NSWorkspace.shared.frontmostApplication
        return DictationTargetContext(
            bundleIdentifier: app?.bundleIdentifier ?? "unknown",
            localizedName: app?.localizedName ?? "Unknown App"
        )
    }
}

struct ASRSessionConfig: Equatable {
    let appID: String
    let accessToken: String
    let resourceID: String
    let userID: String
    let language: DictationLanguage
    let workflow: String
    let utteranceMode: Bool
}

enum ASRProviderEvent: Equatable {
    case partialTranscript(String)
    case finalTranscript(String)
    case error(String)
}

enum NoTypeHotkeyEvent: Equatable {
    case startDictation
    case stopDictation
    case cancelDictation
}
