import SwiftUI

private enum SettingsTab: Hashable {
    case speech
    case aiRewrite
    case neo
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

                neoTab
                    .tag(SettingsTab.neo)
                    .tabItem { Label("Neo", systemImage: "waveform") }

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
        .onChange(of: selectedTab) {
            model.llmSettingsStatusMessage = nil
            model.llmSettingsErrorMessage = nil
        }
    }

    private var neoTab: some View {
        Form {
            Section("语音助手") {
                Toggle("语音唤醒", isOn: $model.neoWakeEnabledDraft)
                TextField("唤醒词", text: $model.neoWakePhraseDraft, prompt: Text("Hey Neo 或 你好小新"))
                Text("支持中文或英文，保存后生效。待机音频仅在本地检测。")
                    .font(.caption).foregroundStyle(.secondary)
                Text(model.neoVoice.state.message ?? model.neoVoice.statusText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("声音") {
                Picker("音色", selection: $model.neoVoiceDraft) {
                    ForEach(NeoVoice.allCases) { voice in
                        Text("\(voice.displayName) · \(voice.description)").tag(voice)
                    }
                }
                TextField("语音指引", text: $model.neoSpeechGuidanceDraft, prompt: Text("例如：语速慢一些，句间稍作停顿，语气自然。"), axis: .vertical)
                    .lineLimit(3...5)
                Text("保存后，下次对话生效。指引留空使用默认说话方式。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("执行") {
                Picker("执行模型", selection: $model.neoExecutionModelDraft) {
                    ForEach(NeoExecutionModel.allCases) { model in
                        Text(model.rawValue).tag(model)
                    }
                }
                Picker("思考强度", selection: $model.neoReasoningEffortDraft) {
                    ForEach(NeoReasoningEffort.allCases) { effort in
                        Text(effort.rawValue).tag(effort)
                    }
                }
                Text("保存后，下次对话生效。强度越高，通常耗时越长。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("对话方式") {
                Text("说「\(model.settings.neoWakePhrase)」唤醒，可连续对话和打断。")
                Text("说「结束会话」、点 × 或按 ⌥ Esc 退出；空闲 45 秒自动结束。")
                Text("支持联网、读屏和应用操作，沿用 Codex 权限。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("只读已有 Codex 记忆，不保存对话。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Speech Recognition Tab

    private var speechTab: some View {
        Form {
            Section {
                Picker("Speech Provider", selection: Binding(
                    get: { model.speechProviderDraft },
                    set: { model.selectSpeechProviderForSettings($0) }
                )) {
                    ForEach(SpeechProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                Text("点击 Save 后切换语音服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.speechProviderDraft == .codex {
                Section {
                    LabeledContent("Status") {
                        Text(model.hasCodexOAuthCredentials ? "Logged in" : "Run `codex login` first")
                            .foregroundStyle(model.hasCodexOAuthCredentials ? .green : .secondary)
                    }

                    Text("复用本机 Codex 登录。结束录音后整段识别，转写结果直接输入，不额外调用 AI Rewrite。")
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

                Picker(model.speechProviderDraft == .codex ? "Interface Language" : "Language", selection: $model.settings.language) {
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
        case .speech: model.speechProviderDraft == .codex ? "Check Codex Login" : "Test Speech"
        case .aiRewrite: "Test AI Rewrite"
        case .neo: model.neoVoice.state.inConversation ? "结束对话" : "开始对话"
        }
    }

    private var bottomBar: some View {
        HStack {
            Button {
                Task {
                    switch selectedTab {
                    case .neo:
                        if model.neoVoice.state.inConversation { model.neoVoice.endConversation() }
                        else { model.startNeoConversation() }
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
            .disabled(model.isTestingLLMSettings || (selectedTab == .neo && (model.phase == .recording || model.phase == .transcribing || model.phase == .refining)))

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
                if selectedTab == .neo { model.saveNeoSettings() }
                else { model.saveSettings() }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("s", modifiers: .command)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }
}
