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
    }

    // MARK: - Speech Recognition Tab

    private var speechTab: some View {
        Form {
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

            Section {
                Picker("Hotkey", selection: $model.settings.hotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker("Language", selection: $model.settings.language) {
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

    // MARK: - AI Rewrite Tab

    private var aiRewriteTab: some View {
        Form {
            Section {
                Toggle(
                    "Enable AI Rewrite",
                    isOn: Binding(
                        get: { model.settings.llmRefinementEnabled },
                        set: { model.settings.llmRefinementEnabled = $0 }
                    )
                )

                Picker(
                    "Provider",
                    selection: Binding(
                        get: { model.llmSettingsDraft.provider },
                        set: { model.selectLLMProvider($0) }
                    )
                ) {
                    ForEach(LLMProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
            } header: {
                Label("General", systemImage: "cpu")
            }

            Section {
                if model.llmSettingsDraft.provider.requiresBaseURL {
                    TextField(
                        "API Base URL",
                        text: Binding(
                            get: { model.llmSettingsDraft.baseURL },
                            set: { model.llmSettingsDraft.baseURL = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                } else {
                    LabeledContent("API Endpoint") {
                        Text(model.llmSettingsDraft.provider.defaultBaseURL)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack(spacing: 8) {
                    SecureField(
                        "API Key",
                        text: Binding(
                            get: { model.llmSettingsDraft.apiKey },
                            set: { model.llmSettingsDraft.apiKey = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)

                    Button("Clear") {
                        model.clearLLMAPIKeyDraft()
                    }
                    .disabled(model.llmSettingsDraft.apiKey.isEmpty)
                }

                TextField(
                    "Model",
                    text: Binding(
                        get: { model.llmSettingsDraft.model },
                        set: { model.llmSettingsDraft.model = $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)

                Text(
                    model.llmSettingsDraft.provider == .gemini
                        ? "Gemini uses the native Gemini API endpoint. API Key is stored in Keychain."
                        : "API Key is stored securely in Keychain."
                )
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
        case .speech: "Test Speech"
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
