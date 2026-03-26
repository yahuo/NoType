import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: NoTypeAppModel
    @Environment(\.openWindow) private var openWindow
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NoType")
                        .font(.headline)
                    Text(statusText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: model.menuBarSymbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(colorForPhase)
            }

            if !model.permissionSnapshot.ready {
                GroupBox("Permissions") {
                    Text("Microphone and Accessibility access are required before dictation can start.")
                        .font(.callout)
                    Button("Open Setup") {
                        activateAndOpenWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if !model.hasASRCredentials {
                GroupBox("ASR Setup") {
                    Text("Add App ID, Resource ID, and Access Token in Settings to connect Doubao ASR.")
                        .font(.callout)
                    Button {
                        openSettingsWindow()
                    } label: {
                        Text("Open Settings")
                    }
                }
            }

            HStack {
                Button(primaryButtonTitle) {
                    if model.phase == .recording {
                        model.stopDictationFromUI()
                    } else {
                        model.startDictationFromUI()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(primaryButtonDisabled)

                if model.phase == .failed {
                    Button("Retry") {
                        model.retryLastRecordingFromUI()
                    }
                }

                if model.phase == .recording || model.phase == .processing || model.phase == .failed {
                    Button("Cancel") {
                        model.cancelFromUI()
                    }
                }
            }

            Divider()

            HStack {
                Button("History") {
                    activateAndOpenWindow(id: "history")
                }
                Button {
                    openSettingsWindow()
                } label: {
                    Text("Settings")
                }
                Spacer()
                Button("Quit") {
                    NSApp.terminate(nil)
                }
            }
        }
        .padding(16)
        .frame(width: 360)
    }

    private var statusText: String {
        switch model.phase {
        case .onboarding:
            "Waiting for permissions"
        case .idle:
            "Ready on \(model.settings.hotkey.displayName)"
        case .recording:
            "Recording from \(model.currentMicrophoneName)"
        case .processing:
            "Processing audio"
        case .failed:
            model.errorMessage ?? "Last dictation failed"
        case .inserted:
            "Text inserted"
        }
    }

    private var primaryButtonTitle: String {
        model.phase == .recording ? "Stop Dictation" : "Start Dictation"
    }

    private var primaryButtonDisabled: Bool {
        switch model.phase {
        case .processing:
            true
        default:
            !model.permissionSnapshot.ready || !model.hasASRCredentials
        }
    }

    private var colorForPhase: Color {
        switch model.phase {
        case .recording:
            .red
        case .processing:
            .orange
        case .failed:
            .yellow
        case .inserted:
            .green
        case .idle, .onboarding:
            .secondary
        }
    }

    private func activateAndOpenWindow(id: String) {
        dismissMenuBarWindow()
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async {
            openWindow(id: id)
        }
    }

    private func openSettingsWindow() {
        dismissMenuBarWindow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            openSettings()
        }
    }

    private func dismissMenuBarWindow() {
        NSApp.keyWindow?.orderOut(nil)
    }
}
