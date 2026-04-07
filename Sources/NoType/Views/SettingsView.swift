import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: NoTypeAppModel

    var body: some View {
        Form {
            Section("Doubao Credentials") {
                TextField("App ID", text: $model.settings.appID)
                    .textFieldStyle(.roundedBorder)

                TextField("Resource ID", text: $model.settings.resourceID)
                    .textFieldStyle(.roundedBorder)

                SecureField("Access Token", text: $model.accessToken)
                    .textFieldStyle(.roundedBorder)

                Text("Access Token is stored in Keychain. Clearing the field and saving removes it completely.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input") {
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
            }

            Section("AI Rewrite") {
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
                    TextField(
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
                        : "API Key is stored in Keychain. Clearing the field and saving removes it completely."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Test AI Rewrite") {
                        Task {
                            await model.testLLMSettings()
                        }
                    }
                    .disabled(model.isTestingLLMSettings)

                    Spacer()

                    Button("Save Settings") {
                        model.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            if let status = model.llmSettingsStatusMessage {
                Section {
                    Text(status)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.llmSettingsErrorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            model.prepareSettings()
        }
    }
}
