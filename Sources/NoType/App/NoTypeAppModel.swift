import AppKit
import Foundation
import SwiftData

@MainActor
final class NoTypeAppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var accessToken = "" {
        didSet {
            guard !isInternallyUpdatingAccessToken else { return }
            hasLoadedAccessToken = true
            hasEditedAccessToken = true
            storedAccessTokenPresence = !accessToken.trimmed.isEmpty
        }
    }
    @Published var permissionSnapshot = PermissionSnapshot(microphoneAuthorized: false, accessibilityAuthorized: false)
    @Published var phase: DictationPhase = .onboarding
    @Published var partialTranscript = ""
    @Published var finalTranscript = ""
    @Published var errorMessage: String?
    @Published var diagnosticsMessage: String?
    @Published var diagnosticsLog = ""
    @Published var availableMicrophones: [AudioInputDevice] = []
    @Published var isRunningDiagnostics = false

    private let settingsStore: SettingsStore
    private let keychainClient: KeychainClient
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let audioCaptureService: AudioCaptureService
    private let textInsertionService: TextInsertionService
    private let loginItemService: LoginItemService
    private let historyStore: HistoryStore
    private let hudController: HUDPanelController
    private let providerFactory: () -> ASRProvider

    private var asrProvider: ASRProvider?
    private var currentRecordingURL: URL?
    private var dictationStartedAt: Date?
    private var recordedHistoryForCurrentSession = false
    private var currentTargetContext = DictationTargetContext.currentFrontmost()
    private var acceptsLiveAudioFrames = false
    private var hasLoadedAccessToken = false
    private var hasEditedAccessToken = false
    private var isInternallyUpdatingAccessToken = false
    private var storedAccessTokenPresence: Bool?

    init(
        modelContainer: ModelContainer,
        settingsStore: SettingsStore = SettingsStore(),
        keychainClient: KeychainClient = KeychainClient(),
        permissionService: PermissionService = PermissionService(),
        hotkeyService: HotkeyService = HotkeyService(),
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        loginItemService: LoginItemService = LoginItemService(),
        hudController: HUDPanelController = HUDPanelController(),
        providerFactory: @escaping () -> ASRProvider = { DoubaoStreamingASRProvider() }
    ) {
        self.settingsStore = settingsStore
        self.keychainClient = keychainClient
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.audioCaptureService = audioCaptureService
        self.textInsertionService = textInsertionService
        self.loginItemService = loginItemService
        self.historyStore = HistoryStore(modelContext: modelContainer.mainContext)
        self.hudController = hudController
        self.providerFactory = providerFactory

        self.settings = settingsStore.load()
        self.storedAccessTokenPresence = settingsStore.storedAccessTokenPresence()

        hotkeyService.eventHandler = { [weak self] event in
            Task { @MainActor in
                self?.handleHotkey(event)
            }
        }

        hudController.attach(to: self)
    }

    var menuBarSymbolName: String {
        switch phase {
        case .recording:
            "waveform.circle.fill"
        case .processing:
            "ellipsis.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .inserted:
            "checkmark.circle.fill"
        case .idle, .onboarding:
            "mic.circle"
        }
    }

    var hasASRCredentials: Bool {
        guard settings.hasValidASRConfiguration else { return false }
        if hasLoadedAccessToken {
            return !accessToken.trimmed.isEmpty
        }
        return storedAccessTokenPresence ?? true
    }

    var microphoneSelectionID: String {
        get { settings.microphoneID ?? "" }
        set { settings.microphoneID = newValue.isEmpty ? nil : newValue }
    }

    var currentMicrophoneName: String {
        guard let microphoneID = settings.microphoneID else {
            return "System Default"
        }
        return availableMicrophones.first(where: { $0.id == microphoneID })?.name ?? "Unknown Mic"
    }

    func bootstrap() {
        availableMicrophones = AudioCaptureService.availableInputDevices()
        permissionSnapshot = permissionService.snapshot()
        applyActivationPolicy(using: settings)
        transition(to: permissionSnapshot.ready ? .idle : .onboarding)
        do {
            let result = try hotkeyService.register(using: settings)
            diagnosticsMessage = result.warningMessage
        } catch {
            diagnosticsMessage = error.localizedDescription
        }
        try? historyStore.prune(retentionDays: settings.historyRetentionDays)
        hudController.update(for: self)
    }

    func saveSettings() {
        let previousSettings = settingsStore.load()
        let previousAccessTokenPresence = settingsStore.storedAccessTokenPresence()
        let requestedSettings = settings
        var persistedSettings = requestedSettings
        var saveIssues: [String] = []
        var primaryFailure: Error?

        if requestedSettings.launchAtLogin != previousSettings.launchAtLogin {
            do {
                try loginItemService.setLaunchAtLogin(enabled: requestedSettings.launchAtLogin)
            } catch {
                persistedSettings = Self.reconcilingRecoverableSettingFailures(
                    requested: persistedSettings,
                    previous: previousSettings,
                    restoreLaunchAtLogin: true
                )
                saveIssues.append(error.localizedDescription)
                primaryFailure = primaryFailure ?? error
            }
        }

        if requestedSettings.hotkey != previousSettings.hotkey {
            do {
                let result = try hotkeyService.register(using: requestedSettings)
                if let warningMessage = result.warningMessage {
                    saveIssues.append(warningMessage)
                }
            } catch {
                persistedSettings = Self.reconcilingRecoverableSettingFailures(
                    requested: persistedSettings,
                    previous: previousSettings,
                    restoreHotkey: true
                )
                saveIssues.append(error.localizedDescription)
                primaryFailure = primaryFailure ?? error
                _ = try? hotkeyService.register(using: previousSettings)
            }
        }

        do {
            try settingsStore.save(persistedSettings)
            settings = persistedSettings
            applyActivationPolicy(using: persistedSettings)
            if hasLoadedAccessToken && hasEditedAccessToken {
                try keychainClient.save(accessToken, for: "doubao.access-token")
                let hasToken = !accessToken.trimmed.isEmpty
                settingsStore.setHasStoredAccessToken(hasToken)
                storedAccessTokenPresence = hasToken
                hasEditedAccessToken = false
            }
            try historyStore.prune(retentionDays: persistedSettings.historyRetentionDays)
            if saveIssues.isEmpty {
                diagnosticsMessage = "Settings saved."
                errorMessage = nil
            } else {
                diagnosticsMessage = "Settings saved, but some changes were not applied."
                errorMessage = saveIssues.joined(separator: "\n")
            }
        } catch {
            settings = persistedSettings
            if let previousAccessTokenPresence {
                settingsStore.setHasStoredAccessToken(previousAccessTokenPresence)
            } else {
                settingsStore.clearStoredAccessTokenPresence()
            }
            storedAccessTokenPresence = previousAccessTokenPresence
            diagnosticsMessage = nil
            errorMessage = (primaryFailure ?? error).localizedDescription
        }
    }

    func prepareSettings() {
        do {
            _ = try loadAccessTokenIfNeeded()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestPermissions() async {
        _ = await permissionService.requestMicrophoneAccess()
        _ = permissionService.promptAccessibilityAccess()
        permissionSnapshot = permissionService.snapshot()
        transition(to: permissionSnapshot.ready ? .idle : .onboarding)
    }

    func openAccessibilitySettings() {
        permissionService.openSystemSettingsAccessibility()
    }

    func openMicrophoneSettings() {
        permissionService.openSystemSettingsMicrophone()
    }

    func diagnoseConnection() async {
        do {
            errorMessage = nil

            guard let config = try currentASRSessionConfig() else {
                diagnosticsMessage = "Fill App ID, Resource ID, and Access Token first."
                return
            }

            isRunningDiagnostics = true
            diagnosticsMessage = "Testing Doubao protocol roundtrip..."
            diagnosticsLog = ""
            defer { isRunningDiagnostics = false }

            let provider = providerFactory()
            appendDiagnosticsLog("Starting Doubao diagnostics.")
            appendDiagnosticsLog("Endpoint: \(DoubaoStreamingASRProvider.serviceURL.absoluteString)")
            appendDiagnosticsLog("App ID: \(config.appID)")
            appendDiagnosticsLog("Resource ID: \(config.resourceID)")
            appendDiagnosticsLog("Access Token: \(maskedAccessToken(config.accessToken))")

            let handshakeRequest = DoubaoStreamingASRProvider.makeWebSocketRequest(
                for: config,
                connectID: UUID().uuidString.lowercased(),
                userAgent: "NoType/diag-preflight"
            )
            do {
                let handshake = try await DoubaoHandshakeProbe.probe(webSocketRequest: handshakeRequest)
                appendDiagnosticsLog("Handshake probe: \(handshake.statusLine)")
                if let logID = handshake.logID {
                    appendDiagnosticsLog("X-Tt-Logid: \(logID)")
                }
                if !handshake.body.isEmpty {
                    appendDiagnosticsLog("Handshake body: \(handshake.body)")
                }
                if handshake.statusCode != 101 {
                    appendDiagnosticsLog(
                        "Handshake probe returned HTTP \(handshake.statusCode); continuing with the real WebSocket roundtrip because this preflight can differ from the actual upgrade path."
                    )
                }
            } catch {
                appendDiagnosticsLog(
                    "Handshake probe could not inspect the response: \(error.localizedDescription). Continuing with the real WebSocket roundtrip."
                )
            }

            let event = try await runDiagnosticRoundtrip(with: provider, config: config)
            provider.cancel()

            switch event {
            case .partialTranscript(let transcript), .finalTranscript(let transcript):
                errorMessage = nil
                if transcript.isEmpty {
                    diagnosticsMessage = "Protocol roundtrip succeeded."
                    appendDiagnosticsLog("ASR event: final empty transcript; transport looks healthy.")
                } else {
                    diagnosticsMessage = "Protocol roundtrip succeeded: \(transcript)"
                    appendDiagnosticsLog("ASR event: transcript=\(transcript)")
                }
            case .error(let message):
                errorMessage = nil
                diagnosticsMessage = "Server replied: \(message)"
                appendDiagnosticsLog("ASR event: error=\(message)")
            case nil:
                errorMessage = nil
                diagnosticsMessage = "No ASR response within timeout."
                appendDiagnosticsLog("ASR event: timeout waiting for transcript.")
            }
        } catch {
            errorMessage = nil
            diagnosticsMessage = "Connection failed: \(error.localizedDescription)"
            appendDiagnosticsLog("Diagnostics failed: \(error.localizedDescription)")
        }
    }

    func clearDiagnosticsLog() {
        diagnosticsLog = ""
        diagnosticsMessage = nil
        errorMessage = nil
    }

    func startDictationFromUI() {
        Task { await startDictation() }
    }

    func stopDictationFromUI() {
        Task { await stopDictation() }
    }

    func cancelFromUI() {
        cancelCurrentSession()
    }

    func retryLastRecordingFromUI() {
        Task { await retryLastRecording() }
    }

    private func handleHotkey(_ event: NoTypeHotkeyEvent) {
        switch event {
        case .startDictation:
            Task { await startDictation() }
        case .stopDictation:
            Task { await stopDictation() }
        case .cancelDictation:
            cancelCurrentSession()
        }
    }

    private func startDictation() async {
        permissionSnapshot = permissionService.snapshot()
        guard permissionSnapshot.ready else {
            presentPermissionRequirementFeedback(for: permissionSnapshot)
            return
        }

        do {
            guard let config = try currentASRSessionConfig() else {
                transition(to: .failed, message: "ASR credentials are incomplete.")
                return
            }

            resetSessionStateForStart()
            let provider = providerFactory()
            provider.eventHandler = { [weak self] event in
                Task { @MainActor in
                    self?.handleASREvent(event)
                }
            }

            try await provider.startSession(config: config)
            asrProvider = provider
            acceptsLiveAudioFrames = true

            currentRecordingURL = try audioCaptureService.startCapture(microphoneID: settings.microphoneID) { [weak self] frame in
                guard let self else { return }
                Task { @MainActor in
                    guard self.acceptsLiveAudioFrames else { return }
                    do {
                        try await self.asrProvider?.sendAudioFrame(frame, isFinal: false)
                    } catch {
                        self.failSession(error.localizedDescription)
                    }
                }
            }

            dictationStartedAt = .now
            currentTargetContext = DictationTargetContext.currentFrontmost()
            transition(to: .recording)
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func stopDictation() async {
        guard phase == .recording else { return }
        transition(to: .processing)
        acceptsLiveAudioFrames = false

        do {
            let stopResult = try audioCaptureService.stopCaptureForFinalization()
            if let finalFrame = stopResult.flushedRemainder, !finalFrame.isEmpty {
                try await asrProvider?.sendAudioFrame(finalFrame, isFinal: false)
            }
            try await asrProvider?.finish()
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func retryLastRecording() async {
        guard let currentRecordingURL else {
            diagnosticsMessage = "No recording available to retry."
            return
        }

        do {
            guard let config = try currentASRSessionConfig() else {
                transition(to: .failed, message: "ASR credentials are incomplete.")
                return
            }

            let provider = providerFactory()
            provider.eventHandler = { [weak self] event in
                Task { @MainActor in
                    self?.handleASREvent(event)
                }
            }
            try await provider.startSession(config: config)
            asrProvider = provider
            transition(to: .processing)
            errorMessage = nil

            let audioData = try audioCaptureService.loadRecording(at: currentRecordingURL)
            for frame in PCMUtilities.chunk(audioData) {
                try await provider.sendAudioFrame(frame, isFinal: false)
            }
            try await provider.finish()
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func cancelCurrentSession() {
        acceptsLiveAudioFrames = false
        do {
            try audioCaptureService.stopCapture(flushRemainder: false)
        } catch {
            diagnosticsMessage = error.localizedDescription
        }

        asrProvider?.cancel()
        asrProvider = nil
        persistHistoryIfNeeded(status: .cancelled, text: finalTranscript.isEmpty ? partialTranscript : finalTranscript)
        cleanupRecording(deleteFile: true)
        partialTranscript = ""
        finalTranscript = ""
        errorMessage = nil
        transition(to: permissionSnapshot.ready ? .idle : .onboarding)
    }

    private func handleASREvent(_ event: ASRProviderEvent) {
        switch event {
        case .partialTranscript(let transcript):
            partialTranscript = transcript
            if phase != .recording {
                transition(to: .processing)
            }
        case .finalTranscript(let transcript):
            Task { await completeSession(with: transcript) }
        case .error(let message):
            failSession(message)
        }
    }

    private func completeSession(with transcript: String) async {
        acceptsLiveAudioFrames = false
        let formatted = TranscriptFormatter.normalize(transcript)
        finalTranscript = formatted
        partialTranscript = formatted

        do {
            if formatted.trimmed.isEmpty {
                currentTargetContext = DictationTargetContext.currentFrontmost()
                persistHistoryIfNeeded(status: .success, text: "")
                cleanupRecording(deleteFile: true)
                asrProvider?.cancel()
                asrProvider = nil
                partialTranscript = ""
                finalTranscript = ""
                transition(to: permissionSnapshot.ready ? .idle : .onboarding)
                return
            }

            let insertionContext = settings.autoInsert
                ? try textInsertionService.insert(formatted)
                : DictationTargetContext.currentFrontmost()

            currentTargetContext = insertionContext
            persistHistoryIfNeeded(status: .success, text: formatted)
            cleanupRecording(deleteFile: true)
            asrProvider?.cancel()
            asrProvider = nil
            transition(to: .inserted)

            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(900))
                if self.phase == .inserted {
                    self.transition(to: self.permissionSnapshot.ready ? .idle : .onboarding)
                    self.partialTranscript = ""
                }
            }
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func failSession(_ message: String) {
        acceptsLiveAudioFrames = false
        do {
            if phase == .recording {
                try audioCaptureService.stopCapture(flushRemainder: false)
            }
        } catch {
            diagnosticsMessage = error.localizedDescription
        }

        errorMessage = message
        diagnosticsMessage = nil
        asrProvider?.cancel()
        asrProvider = nil
        persistHistoryIfNeeded(status: .failed, text: finalTranscript.isEmpty ? partialTranscript : finalTranscript)
        transition(to: .failed, message: message)
    }

    private func persistHistoryIfNeeded(status: DictationSessionStatus, text: String) {
        guard !recordedHistoryForCurrentSession else { return }
        guard let dictationStartedAt else { return }

        let microphoneName = currentMicrophoneName
        try? historyStore.addRecord(
            startedAt: dictationStartedAt,
            endedAt: .now,
            context: currentTargetContext,
            microphoneName: microphoneName,
            finalText: text,
            status: status,
            latencyMs: Int(Date().timeIntervalSince(dictationStartedAt) * 1_000)
        )
        recordedHistoryForCurrentSession = true
    }

    private func cleanupRecording(deleteFile: Bool) {
        if deleteFile {
            audioCaptureService.clearRecording(at: currentRecordingURL)
        }
        currentRecordingURL = nil
        dictationStartedAt = nil
        recordedHistoryForCurrentSession = false
    }

    private func resetSessionStateForStart() {
        acceptsLiveAudioFrames = false
        partialTranscript = ""
        finalTranscript = ""
        errorMessage = nil
        diagnosticsMessage = nil
        recordedHistoryForCurrentSession = false
        audioCaptureService.clearRecording(at: currentRecordingURL)
        currentRecordingURL = nil
        asrProvider?.cancel()
        asrProvider = nil
    }

    private func transition(to newPhase: DictationPhase, message: String? = nil) {
        phase = newPhase
        if let message {
            errorMessage = message
        }
        hotkeyService.update(phase: newPhase)
        hudController.update(for: self)
    }

    private func currentASRSessionConfig() throws -> ASRSessionConfig? {
        guard settings.hasValidASRConfiguration else {
            return nil
        }

        let token = try loadAccessTokenIfNeeded().trimmed
        guard !token.isEmpty else {
            return nil
        }

        return ASRSessionConfig(
            appID: settings.appID.trimmed,
            accessToken: token,
            resourceID: settings.resourceID.trimmed,
            userID: ProcessInfo.processInfo.hostName,
            language: settings.language,
            workflow: "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate",
            utteranceMode: true
        )
    }

    nonisolated static func reconcilingRecoverableSettingFailures(
        requested: AppSettings,
        previous: AppSettings,
        restoreLaunchAtLogin: Bool = false,
        restoreHotkey: Bool = false
    ) -> AppSettings {
        var reconciled = requested
        if restoreLaunchAtLogin {
            reconciled.launchAtLogin = previous.launchAtLogin
        }
        if restoreHotkey {
            reconciled.hotkey = previous.hotkey
        }
        return reconciled
    }

    private func loadAccessTokenIfNeeded() throws -> String {
        guard !hasLoadedAccessToken else {
            return accessToken
        }

        let token = try keychainClient.read(account: "doubao.access-token")
        assignAccessToken(token, markAsEdited: false)
        return token
    }

    private func assignAccessToken(_ value: String, markAsEdited: Bool) {
        isInternallyUpdatingAccessToken = true
        accessToken = value
        isInternallyUpdatingAccessToken = false
        hasLoadedAccessToken = true
        hasEditedAccessToken = markAsEdited
        storedAccessTokenPresence = !value.trimmed.isEmpty
    }

    private func applyActivationPolicy(using settings: AppSettings) {
        let targetPolicy: NSApplication.ActivationPolicy = settings.showDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != targetPolicy else { return }

        NSApp.setActivationPolicy(targetPolicy)
        if targetPolicy == .regular {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func runDiagnosticRoundtrip(with provider: ASRProvider, config: ASRSessionConfig) async throws -> ASRProviderEvent? {
        let silence = Data(repeating: 0, count: PCMUtilities.chunkByteCount)
        var receivedEvent: ASRProviderEvent?
        provider.eventHandler = { event in
            if receivedEvent == nil {
                receivedEvent = event
            }
        }

        appendDiagnosticsLog("Opening WebSocket session.")
        try await provider.startSession(config: config)
        appendDiagnosticsLog("WebSocket session opened; sending final silent frame (\(silence.count) bytes).")
        try await provider.sendAudioFrame(silence, isFinal: true)

        for _ in 0..<50 {
            if let receivedEvent {
                return receivedEvent
            }
            try await Task.sleep(for: .milliseconds(100))
        }

        return nil
    }

    private func appendDiagnosticsLog(_ line: String) {
        let timestamp = ISO8601DateFormatter().string(from: .now)
        if diagnosticsLog.isEmpty {
            diagnosticsLog = "[\(timestamp)] \(line)"
        } else {
            diagnosticsLog += "\n[\(timestamp)] \(line)"
        }
    }

    private func maskedAccessToken(_ token: String) -> String {
        guard token.count > 8 else { return String(repeating: "*", count: max(token.count, 4)) }
        let prefix = token.prefix(4)
        let suffix = token.suffix(4)
        return "\(prefix)...\(suffix)"
    }

    private func presentPermissionRequirementFeedback(for snapshot: PermissionSnapshot) {
        let message = Self.permissionRequirementMessage(for: snapshot, language: settings.language)
        errorMessage = nil
        diagnosticsMessage = nil
        transition(to: .failed, message: message)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard self.phase == .failed, self.errorMessage == message else { return }
            self.errorMessage = nil
            self.transition(to: .onboarding)
        }
    }

    nonisolated static func permissionRequirementMessage(
        for snapshot: PermissionSnapshot,
        language: DictationLanguage
    ) -> String {
        switch (snapshot.microphoneAuthorized, snapshot.accessibilityAuthorized, language) {
        case (false, false, .zhCN):
            "需要先授予麦克风和辅助功能权限。打开 Setup 完成授权后再试。"
        case (false, true, .zhCN):
            "需要先授予麦克风权限。打开 Setup 完成授权后再试。"
        case (true, false, .zhCN):
            "需要先授予辅助功能权限。打开 Setup 完成授权后再试。"
        case (false, false, .enUS):
            "Microphone and Accessibility permissions are required. Open Setup and grant them before trying again."
        case (false, true, .enUS):
            "Microphone permission is required. Open Setup and grant it before trying again."
        case (true, false, .enUS):
            "Accessibility permission is required. Open Setup and grant it before trying again."
        case (true, true, _):
            ""
        }
    }
}
