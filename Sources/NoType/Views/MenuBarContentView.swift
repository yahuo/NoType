import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: NoTypeAppModel
    @Environment(\.openWindow) private var openWindow
    let openSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            headerRow
            mainCard
            iconFooter
        }
        .padding(14)
        .frame(width: 280)
    }

    // MARK: - Zone 1 — Header Row

    private var headerRow: some View {
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
    }

    // MARK: - Zone 2 — Main Card

    private var mainCard: some View {
        VStack(spacing: 12) {
            if !model.permissionSnapshot.ready {
                Button("Open Setup") {
                    activateAndOpenWindow(id: "onboarding")
                }
                .buttonStyle(.borderedProminent)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !model.hasASRCredentials {
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
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "mic.circle")
                        .font(.system(size: 36))
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

            settingsTiles
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.quaternary.opacity(0.5))
        )
    }

    private var settingsTiles: some View {
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
                VStack(alignment: .leading, spacing: 3) {
                    Text("LANGUAGE")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("\(model.settings.language.displayName) ▾")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                )
            }
            .buttonStyle(.plain)

            Menu {
                Button {
                    model.setAIRewriteEnabled(!model.aiRewriteEnabled)
                } label: {
                    Label(
                        model.aiRewriteEnabled ? "Enabled" : "Disabled",
                        systemImage: model.aiRewriteEnabled ? "checkmark.circle.fill" : "circle"
                    )
                }

                Button("Settings…") {
                    openSettingsWindow()
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text("AI REWRITE")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(model.aiRewriteEnabled ? Color.green : Color.secondary)
                            .frame(width: 6, height: 6)
                        Text("\(model.aiRewriteEnabled ? "On" : "Off") ▾")
                            .font(.caption)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Zone 3 — Icon Footer

    private var iconFooter: some View {
        HStack {
            Button {
                openSettingsWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")

            Spacer()

            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(.quaternary)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Quit")
        }
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
            "Rewriting"
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
        case .idle:
            .green
        case .onboarding:
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
