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
                Text("1.0 小时版: volc.bigasr.sauc.duration   1.0 并发版: volc.bigasr.sauc.concurrent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("2.0 小时版: volc.seedasr.sauc.duration   2.0 并发版: volc.seedasr.sauc.concurrent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Input") {
                Picker("Hotkey", selection: $model.settings.hotkey) {
                    ForEach(HotkeyOption.allCases) { option in
                        Text(option.displayName).tag(option)
                    }
                }

                Picker(
                    "Microphone",
                    selection: Binding(
                        get: { model.microphoneSelectionID },
                        set: { model.microphoneSelectionID = $0 }
                    )
                ) {
                    Text("System Default").tag("")
                    ForEach(model.availableMicrophones) { microphone in
                        Text(microphone.name).tag(microphone.id)
                    }
                }

                Picker("Language", selection: $model.settings.language) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section("Behavior") {
                Toggle("Auto insert text into the focused app", isOn: $model.settings.autoInsert)
                Toggle("Show Dock icon", isOn: $model.settings.showDockIcon)
                Toggle("Launch at login", isOn: $model.settings.launchAtLogin)

                Stepper(
                    "History retention: \(model.settings.historyRetentionDays) days",
                    value: $model.settings.historyRetentionDays,
                    in: 1...90
                )
            }

            Section("Diagnostics") {
                HStack {
                    Button("Run Connection Test") {
                        Task {
                            await model.diagnoseConnection()
                        }
                    }
                    .disabled(model.isRunningDiagnostics)

                    if !model.diagnosticsLog.isEmpty {
                        Button("Clear Log") {
                            model.clearDiagnosticsLog()
                        }
                    }
                }

                if let diagnosticsMessage = model.diagnosticsMessage {
                    Text(diagnosticsMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.callout)
                        .foregroundStyle(.red)
                }

                if !model.diagnosticsLog.isEmpty {
                    ScrollView {
                        Text(model.diagnosticsLog)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 160, maxHeight: 240)
                }
            }

            Section {
                HStack {
                    Spacer()
                    Button("Save Settings") {
                        model.saveSettings()
                    }
                    .buttonStyle(.borderedProminent)
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
