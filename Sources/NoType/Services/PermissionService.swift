import AVFoundation
import ApplicationServices
import AppKit
import Foundation

@MainActor
final class PermissionService {
    func snapshot() -> PermissionSnapshot {
        PermissionSnapshot(
            microphoneAuthorized: microphoneAuthorized,
            accessibilityAuthorized: accessibilityAuthorized
        )
    }

    var microphoneAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    var accessibilityAuthorized: Bool {
        AXIsProcessTrusted()
    }

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func promptAccessibilityAccess() -> Bool {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openSystemSettingsAccessibility() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    func openSystemSettingsMicrophone() {
        open(urlString: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }

    private func open(urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
