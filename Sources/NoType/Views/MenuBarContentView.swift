import AppKit
import SwiftUI

struct MenuBarContentView: View {
    @ObservedObject var model: NoTypeAppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.colorScheme) private var colorScheme
    let openSettings: () -> Void

    private var accentColor: Color {
        colorScheme == .dark
            ? Color(red: 0.55, green: 0.86, blue: 0.65)
            : Color(red: 0.21, green: 0.47, blue: 0.31)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
                .padding(.bottom, 16)

            statusNotice

            VStack(spacing: 4) {
                shortcutRow("语音输入", icon: "mic", shortcut: model.hotkeyDisplayName)
                shortcutRow("语音译成英文", icon: "character.bubble", shortcut: model.translationHotkeyDisplayName)
                shortcutRow(
                    "选词译成中文",
                    icon: "text.bubble",
                    shortcut: model.selectionTranslationHotkeyDisplayName,
                    detail: "浮窗查看，保留原文"
                )
            }

            Divider().padding(.vertical, 12)
            neoSection
            Divider().padding(.vertical, 12)
            settingsRow
            Divider().padding(.top, 12).padding(.bottom, 10)
            footerRow
        }
        .padding(18)
        .frame(width: 352)
        .background(colorScheme == .dark
            ? Color(red: 0.14, green: 0.15, blue: 0.14)
            : Color(nsColor: .windowBackgroundColor))
        .tint(accentColor)
    }

    private var headerRow: some View {
        HStack(spacing: 12) {
            Text("NoType")
                .font(.system(size: 18, weight: .semibold))

            Spacer()

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(statusLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Button(action: openSettingsWindow) {
                Image(systemName: "gearshape")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("设置")
            .help("设置")
        }
    }

    @ViewBuilder
    private var statusNotice: some View {
        if !model.permissionSnapshot.ready {
            VStack(alignment: .leading, spacing: 8) {
                Text(model.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("完成权限设置") {
                    activateAndOpenWindow(id: "onboarding")
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 12)
        } else if !model.hasASRCredentials {
            HStack {
                Label(
                    model.settings.speechProvider == .codex ? "需要登录 Codex" : "需要配置豆包语音",
                    systemImage: "exclamationmark.triangle"
                )
                .foregroundStyle(.orange)
                Spacer()
                Button("打开设置", action: openSettingsWindow)
                    .controlSize(.small)
            }
            .font(.caption)
            .padding(.bottom, 12)
        } else if model.phase != .idle {
            Text(model.phase == .failed ? model.errorMessage ?? model.statusLine : model.statusLine)
                .font(.caption)
                .foregroundStyle(model.phase == .failed ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
        }

        if let warning = model.hotkeyWarningMessage {
            Text(warning)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)
        }
    }

    private func shortcutRow(_ title: String, icon: String, shortcut: String, detail: String? = nil) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .medium))
                    Spacer(minLength: 0)
                    shortcutKeycaps(shortcut)
                }
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func shortcutKeycaps(_ shortcut: String) -> some View {
        let symbols = ["Option": "⌥", "Control": "⌃", "Shift": "⇧", "Command": "⌘"]
        return HStack(spacing: 4) {
            ForEach(Array(shortcut.components(separatedBy: " + ").enumerated()), id: \.offset) { _, key in
                Text(symbols[key] ?? key)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 23, minHeight: 23)
                    .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.primary.opacity(0.12)))
            }
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(shortcut)
    }

    private var neoSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "waveform")
                    .font(.system(size: 18))
                    .frame(width: 24)
                Text("Neo")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Button(model.neoVoice.state.inConversation ? "结束对话" : "开始对话") {
                    if model.neoVoice.state.inConversation { model.neoVoice.endConversation() }
                    else { model.startNeoConversation() }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(accentColor)
                .disabled(model.phase == .recording || model.phase == .transcribing || model.phase == .refining)
            }

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("语音唤醒")
                        .font(.system(size: 13, weight: .medium))
                    Text(model.neoVoice.state.message ?? model.neoVoice.statusText)
                        .font(.system(size: 11))
                        .foregroundStyle(model.neoVoice.state.message == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button {
                    model.setNeoWakeEnabled(!model.settings.neoWakeEnabled)
                } label: {
                    Capsule()
                        .fill(model.settings.neoWakeEnabled ? accentColor : Color.primary.opacity(0.18))
                        .overlay(alignment: model.settings.neoWakeEnabled ? .trailing : .leading) {
                            Circle().fill(.white).padding(2)
                        }
                        .frame(width: 36, height: 21)
                }
                .buttonStyle(.plain)
                .accessibilityRepresentation {
                    Toggle("语音唤醒", isOn: Binding(
                        get: { model.settings.neoWakeEnabled },
                        set: { model.setNeoWakeEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                }
            }
        }
    }

    private var settingsRow: some View {
        HStack {
            Menu {
                ForEach(DictationLanguage.allCases) { language in
                    Button {
                        model.selectLanguage(language)
                    } label: {
                        Label(language.displayName, systemImage: model.settings.language == language ? "checkmark" : "")
                    }
                }
            } label: {
                Text("\(model.settings.language.displayName) ⌄")
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .foregroundStyle(.primary)
            .accessibilityLabel("输入语言：\(model.settings.language.displayName)")

            Spacer()

            if model.settings.speechProvider == .codex {
                Button("Codex · 直接输入", action: openSettingsWindow)
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("语音服务设置")
            } else {
                Menu {
                    Button {
                        model.setAIRewriteEnabled(!model.aiRewriteEnabled)
                    } label: {
                        Label(
                            model.aiRewriteEnabled ? "关闭 AI 改写" : "开启 AI 改写",
                            systemImage: model.aiRewriteEnabled ? "checkmark.circle.fill" : "circle"
                        )
                    }
                    Button("设置…", action: openSettingsWindow)
                } label: {
                    Text(model.aiRewriteEnabled ? "AI 改写：开 ⌄" : "AI 改写：关 ⌄")
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
    }

    private var footerRow: some View {
        HStack {
            Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0")")
                .foregroundStyle(.tertiary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("退出", systemImage: "power")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .font(.system(size: 11))
    }

    private var statusLabel: String {
        if !model.permissionSnapshot.ready { return "待授权" }
        if !model.hasASRCredentials { return "待配置" }
        return switch model.phase {
        case .idle: "已就绪"
        case .onboarding: "待设置"
        case .recording: "录音中"
        case .transcribing: "转写中"
        case .refining: "处理中"
        case .inserted: "已输入"
        case .copiedToClipboard: "已复制"
        case .failed: "出错了"
        }
    }

    private var statusColor: Color {
        if !model.permissionSnapshot.ready || !model.hasASRCredentials { return .orange }
        return switch model.phase {
        case .recording, .failed: .red
        case .transcribing, .refining: .orange
        case .idle, .inserted, .copiedToClipboard: accentColor
        case .onboarding: .secondary
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
