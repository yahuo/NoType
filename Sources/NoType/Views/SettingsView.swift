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
                LabeledContent("Dictation Hotkey") {
                    Text(model.hotkeyDisplayName)
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Translate Hotkey") {
                    Text(model.translationHotkeyDisplayName)
                        .foregroundStyle(.secondary)
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
                        set: { model.setAIRewriteEnabled($0) }
                    )
                )

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
