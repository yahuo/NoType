import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: NoTypeAppModel
    @Environment(\.openWindow) private var openWindow
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            // MARK: Zone 1 — Header Row
            HStack {
                Text("NoType")
                    .font(.headline)

                Spacer()

                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // MARK: Zone 2 — Main Card
            VStack(spacing: 10) {
                // Hotkey hero
                HStack(spacing: 10) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 28))
                        .foregroundStyle(statusColor)
                        .frame(width: 40, height: 40)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.statusLine)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(model.hotkeyDisplayName)
                            .font(.subheadline.monospaced())
                    }

                    Spacer()
                }

                // Conditional states
                if !model.permissionSnapshot.ready {
                    Button("Open Setup") {
                        activateAndOpenWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if model.permissionSnapshot.ready && !model.hasASRCredentials {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                        Text("Missing Doubao credentials")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button("Open Settings") {
                        openSettingsWindow()
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let warning = model.hotkeyWarningMessage {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let errorMessage = model.errorMessage, model.phase == .failed {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // Language & LLM tiles
                HStack(spacing: 8) {
                    Menu {
                        ForEach(DictationLanguage.allCases) { language in
                            Button {
                                model.selectLanguage(language)
                            } label: {
                                Label(language.displayName, systemImage: model.settings.language == language ? "checkmark" : "")
                            }
                        }
                    } label: {
                        Text("LANGUAGE")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                            )
                    }
                    .buttonStyle(.plain)

                    Menu {
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
                    } label: {
                        Text("LLM")
                            .font(.caption2.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(.quaternary)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(.quaternary.opacity(0.5))
            )

            // MARK: Zone 3 — Icon Footer
            HStack {
                Button {
                    openSettingsWindow()
                } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                        )
                }
                .buttonStyle(.plain)

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 14))
                        .frame(width: 28, height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.quaternary)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Computed Properties

    private var statusLabel: String {
        switch model.phase {
        case .idle:
            "Ready"
        case .onboarding:
            "Setup"
        case .recording:
            "Recording"
        case .transcribing:
            "Transcribing"
        case .refining:
            "Refining"
        case .inserted:
            "Inserted"
        case .copiedToClipboard:
            "Copied"
        case .failed:
            "Error"
        }
    }

    private var statusColor: Color {
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

    // MARK: - Helper Functions

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
