import SwiftUI

private enum SettingsTab: Hashable {
    case speech
    case aiRewrite
}

struct SettingsView: View {
    @ObservedObject var model: NoTypeAppModel
    @State private var selectedTab: SettingsTab = .speech

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $selectedTab) {
                speechTab
                    .tag(SettingsTab.speech)
                    .tabItem {
                        Label("Speech", systemImage: "mic.fill")
                    }

                aiRewriteTab
                    .tag(SettingsTab.aiRewrite)
                    .tabItem {
                        Label("AI Rewrite", systemImage: "wand.and.stars")
                    }
            }
            .padding(.top, 8)

            Divider()

            bottomBar
        }
        .task {
            model.prepareSettings()
        }
        .onChange(of: selectedTab) {
            model.llmSettingsStatusMessage = nil
            model.llmSettingsErrorMessage = nil
        }
        .onChange(of: model.settings.speechProvider) {
            model.prepareSettings()
        }
    }

    // MARK: - Speech Recognition Tab

    private var speechTab: some View {
        Form {
            Section {
                Picker("Speech Provider", selection: $model.settings.speechProvider) {
                    ForEach(SpeechProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            }

            if model.settings.speechProvider == .codex {
                Section {
                    LabeledContent("Status") {
                        Text(model.hasCodexOAuthCredentials ? "Logged in" : "Run `codex login` first")
                            .foregroundStyle(model.hasCodexOAuthCredentials ? .green : .secondary)
                    }

                    Text("复用本机 Codex 登录。结束录音后自动识别语言，转写结果直接输入，不再额外调用 AI Rewrite。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Codex Dictation", systemImage: "mic.fill")
                }
            } else {
                doubaoCredentials
            }

            Section {
                LabeledContent("Dictation Hotkey") {
                    Text(model.hotkeyDisplayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Translate Hotkey") {
                    Text(model.translationHotkeyDisplayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("选词译为中文") {
                    Text(model.selectionTranslationHotkeyDisplayName)
                        .foregroundStyle(.secondary)
                }

                Text("选中文字后按快捷键，在浮窗查看中文译文，原文保持不变。")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker(model.settings.speechProvider == .codex ? "Interface Language" : "Language", selection: $model.settings.language) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            } header: {
                Label("Input", systemImage: "keyboard")
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
    }

    private var doubaoCredentials: some View {
        Section {
            TextField("App ID", text: $model.settings.appID)
                .textFieldStyle(.roundedBorder)

            TextField("Resource ID", text: $model.settings.resourceID)
                .textFieldStyle(.roundedBorder)

            SecureField("Access Token", text: $model.accessToken)
                .textFieldStyle(.roundedBorder)

            Text("Access Token is stored securely in Keychain.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Doubao Credentials", systemImage: "key.fill")
        }
    }

    // MARK: - AI Rewrite Tab

    private var aiRewriteTab: some View {
        Form {
            Section {
                if model.settings.speechProvider == .doubao {
                    Toggle(
                        "Enable AI Rewrite",
                        isOn: Binding(
                            get: { model.settings.llmRefinementEnabled },
                            set: { model.setAIRewriteEnabled($0) }
                        )
                    )
                } else {
                    Text("Codex 语音转写直接输入，不经过额外改写。翻译快捷键仍可使用。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Provider") {
                    Text("Codex OAuth")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Status") {
                    Text(model.hasCodexOAuthCredentials ? "Logged in" : "Run `codex login` first")
                        .foregroundStyle(model.hasCodexOAuthCredentials ? .green : .secondary)
                }
            } header: {
                Label("General", systemImage: "cpu")
            }

            Section {
                Toggle(
                    "Enable Claude/Codex Triple-Space",
                    isOn: Binding(
                        get: { model.settings.agentTUITranslationEnabled },
                        set: { model.setAgentTUITranslationEnabled($0) }
                    )
                )

                Text("Requires the bundled notype-editor proxy to be configured as VISUAL and EDITOR before starting the agent. Manual external-editor shortcuts continue to open your original editor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Agent TUI Translation", systemImage: "terminal")
            }

            Section {
                LabeledContent("Endpoint") {
                    Text("chatgpt.com/backend-api/codex")
                        .foregroundStyle(.secondary)
                }

                Text("NoType reads the current Codex access token from your local Codex login and never refreshes the refresh token.")
                .font(.caption)
                .foregroundStyle(.secondary)
            } header: {
                Label("Connection", systemImage: "link")
            }
        }
        .formStyle(.grouped)
        .scrollIndicators(.hidden)
    }

    // MARK: - Bottom Bar

    private var testButtonLabel: String {
        switch selectedTab {
        case .speech: model.settings.speechProvider == .codex ? "Check Codex Login" : "Test Speech"
        case .aiRewrite: "Test AI Rewrite"
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                Task {
                    switch selectedTab {
                    case .speech:
                        await model.testASRConnection()
                    case .aiRewrite:
                        await model.testAIRewriteConnection()
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isTestingLLMSettings {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(model.isTestingLLMSettings ? "Testing…" : testButtonLabel)
                }
            }
            .disabled(model.isTestingLLMSettings)

            if let status = model.llmSettingsStatusMessage {
                Label(status, systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .lineLimit(1)
            }

            if let error = model.llmSettingsErrorMessage {
                Label(error, systemImage: "xmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Spacer()

            Button("Save") {
                model.saveSettings()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
