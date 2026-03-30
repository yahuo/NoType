import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: NoTypeAppModel
    @Environment(\.openWindow) private var openWindow
    let openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NoType")
                        .font(.headline)
                    Text(model.statusLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()

                Image(systemName: model.menuBarSymbolName)
                    .font(.system(size: 24))
                    .foregroundStyle(iconColor)
            }

            if !model.permissionSnapshot.ready {
                Button("Open Setup") {
                    activateAndOpenWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
            }

            if model.permissionSnapshot.ready && !model.hasASRCredentials {
                Text("Missing Doubao credentials")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)

                Button("Open Settings") {
                    openSettingsWindow()
                }
                .buttonStyle(.borderedProminent)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Main Hotkey")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.hotkeyDisplayName)
                    .font(.subheadline.monospaced())
            }

            if let warning = model.hotkeyWarningMessage {
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let errorMessage = model.errorMessage, model.phase == .failed {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Menu("Language") {
                ForEach(DictationLanguage.allCases) { language in
                    Button {
                        model.selectLanguage(language)
                    } label: {
                        Label(language.displayName, systemImage: model.settings.language == language ? "checkmark" : "")
                    }
                }
            }

            Menu("LLM Refinement") {
                Button {
                    model.setLLMRefinementEnabled(!model.llmRefinementEnabled)
                } label: {
                    Label(
                        model.llmRefinementEnabled ? "Enabled" : "Disabled",
                        systemImage: model.llmRefinementEnabled ? "checkmark.circle.fill" : "circle"
                    )
                }

                Button("Settings…") {
                    openSettingsWindow()
                }
            }

            Divider()

            HStack {
                Button("Settings…") {
                    openSettingsWindow()
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

    private var iconColor: Color {
        switch model.phase {
        case .recording:
            .red
        case .transcribing, .refining:
            .orange
        case .inserted, .copiedToClipboard:
            .green
        case .failed:
            .yellow
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
