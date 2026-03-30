import AppKit
import Foundation

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
    @Published var permissionSnapshot: PermissionSnapshot
    @Published var phase: DictationPhase
    @Published var transcriptPreview = ""
    @Published var waveformLevel = 0.0
    @Published var errorMessage: String?
    @Published var hotkeyWarningMessage: String?
    @Published var llmSettingsDraft: LLMSettingsDraft
    @Published var llmSettingsStatusMessage: String?
    @Published var llmSettingsErrorMessage: String?
    @Published var isTestingLLMSettings = false

    private let settingsStore: SettingsStore
    private let keychainClient: KeychainClient
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let audioCaptureService: AudioCaptureService
    private let textInsertionService: TextInsertionService
    private let aiRewriteService: AIRewriteService
    private let hudController: HUDPanelController
    private let providerFactory: () -> ASRProvider
    private let doubaoAccessTokenAccount = "doubao.access-token"
    private let llmAPIKeyAccount = "llm.api-key"

    private var asrProvider: ASRProvider?
    private var hasLoadedAccessToken = false
    private var hasEditedAccessToken = false
    private var isInternallyUpdatingAccessToken = false
    private var storedAccessTokenPresence: Bool?
    private var hasStoredLLMAPIKey: Bool?
    private var feedbackTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var pendingRewritePreviewTask: Task<Void, Never>?
    private var pendingRewritePreviewText: String?
    private var lastRewritePreviewUpdate = 0.0
    private var sessionID = UUID()

    init(
        settingsStore: SettingsStore = SettingsStore(),
        keychainClient: KeychainClient = KeychainClient(),
        permissionService: PermissionService = PermissionService(),
        hotkeyService: HotkeyService = HotkeyService(),
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        aiRewriteService: AIRewriteService = AIRewriteService(),
        hudController: HUDPanelController = HUDPanelController(),
        providerFactory: @escaping () -> ASRProvider = { DoubaoStreamingASRProvider() }
    ) {
        self.settingsStore = settingsStore
        self.keychainClient = keychainClient
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.audioCaptureService = audioCaptureService
        self.textInsertionService = textInsertionService
        self.aiRewriteService = aiRewriteService
        self.hudController = hudController
        self.providerFactory = providerFactory

        let settings = settingsStore.load()
        self.settings = settings
        storedAccessTokenPresence = settingsStore.storedAccessTokenPresence()
        hasStoredLLMAPIKey = settingsStore.storedLLMAPIKeyPresence()
        permissionSnapshot = PermissionSnapshot(
            microphoneAuthorized: false,
            accessibilityAuthorized: false
        )
        phase = .onboarding
        llmSettingsDraft = LLMSettingsDraft(settings: settings, apiKey: "")

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
        case .transcribing, .refining:
            "ellipsis.circle.fill"
        case .inserted, .copiedToClipboard:
            "checkmark.circle.fill"
        case .failed:
            "exclamationmark.triangle.fill"
        case .idle, .onboarding:
            "mic.circle"
        }
    }

    var aiRewriteEnabled: Bool {
        settings.llmRefinementEnabled
    }

    var llmConfigured: Bool {
        settings.llmConfiguredWithoutAPIKey && (hasStoredLLMAPIKey ?? false)
    }

    var hasASRCredentials: Bool {
        guard settings.hasValidASRConfiguration else { return false }
        if hasLoadedAccessToken {
            return !accessToken.trimmed.isEmpty
        }
        return storedAccessTokenPresence ?? true
    }

    var hotkeyDisplayName: String {
        settings.hotkey.displayName
    }

    var hudDisplayText: String {
        let preview = transcriptPreview.trimmed

        switch phase {
        case .recording:
            return preview.isEmpty
                ? localizedText(
                    zh: "请开始说话，再按 \(hotkeyDisplayName) 结束",
                    en: "Start speaking. Press \(hotkeyDisplayName) again to stop."
                )
                : preview
        case .transcribing:
            return preview.isEmpty ? localizedText(zh: "Transcribing…", en: "Transcribing…") : preview
        case .refining:
            return preview.isEmpty ? localizedText(zh: "正在改写…", en: "Rewriting…") : preview
        case .inserted:
            return localizedText(zh: "已粘贴到当前输入框", en: "Pasted into the focused field")
        case .copiedToClipboard:
            return localizedText(zh: "已复制到剪贴板，可手动粘贴", en: "Copied to clipboard. Paste anywhere.")
        case .failed:
            return errorMessage ?? localizedText(zh: "语音输入失败", en: "Dictation failed")
        case .idle:
            return localizedText(
                zh: "按 \(hotkeyDisplayName) 开始录音，再按一次结束",
                en: "Press \(hotkeyDisplayName) to start. Press again to stop."
            )
        case .onboarding:
            return localizedText(zh: "先完成权限授权", en: "Grant permissions first")
        }
    }

    var statusLine: String {
        if !permissionSnapshot.ready {
            return Self.permissionRequirementMessage(for: permissionSnapshot, language: settings.language)
        }

        if !hasASRCredentials {
            return localizedText(
                zh: "先在 Settings 中配置豆包 App ID、Resource ID 和 Access Token。",
                en: "Configure the Doubao App ID, Resource ID, and Access Token in Settings first."
            )
        }

        switch phase {
        case .idle:
            return localizedText(
                zh: "准备就绪，按 \(hotkeyDisplayName) 开始录音。",
                en: "Ready. Press \(hotkeyDisplayName) to start dictation."
            )
        case .recording:
            return localizedText(
                zh: "正在录音，再按 \(hotkeyDisplayName) 结束，Option + Esc 取消。",
                en: "Recording. Press \(hotkeyDisplayName) again to stop, or Option + Esc to cancel."
            )
        case .transcribing:
            return localizedText(
                zh: "正在转写语音，再按 \(hotkeyDisplayName) 可取消。",
                en: "Transcribing. Press \(hotkeyDisplayName) again to cancel."
            )
        case .refining:
            return localizedText(
                zh: "正在进行 AI 改写，再按 \(hotkeyDisplayName) 可取消。",
                en: "AI Rewrite is running. Press \(hotkeyDisplayName) again to cancel."
            )
        case .inserted:
            return localizedText(zh: "已完成文本注入。", en: "Text pasted.")
        case .copiedToClipboard:
            return localizedText(zh: "未检测到输入焦点，已复制到剪贴板。", en: "No editable focus. Copied to clipboard.")
        case .failed:
            return errorMessage ?? localizedText(zh: "语音输入失败。", en: "Dictation failed.")
        case .onboarding:
            return Self.permissionRequirementMessage(for: permissionSnapshot, language: settings.language)
        }
    }

    func bootstrap() {
        permissionSnapshot = permissionService.snapshot()
        phase = permissionSnapshot.ready ? .idle : .onboarding
        hotkeyService.update(phase: phase)

        do {
            let result = try hotkeyService.register(using: settings)
            hotkeyWarningMessage = result.warningMessage
        } catch {
            hotkeyWarningMessage = nil
            errorMessage = error.localizedDescription
        }

        scheduleHUDLayoutUpdate(animated: false)
    }

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
        if phase != .recording, phase != .transcribing, phase != .refining {
            transition(to: permissionSnapshot.ready ? .idle : .onboarding)
        }
    }

    func requestPermissions() async {
        _ = await permissionService.requestMicrophoneAccess()
        _ = permissionService.promptAccessibilityAccess()
        refreshPermissions()
    }

    func openAccessibilitySettings() {
        permissionService.openAccessibilitySettings()
    }

    func openMicrophoneSettings() {
        permissionService.openMicrophoneSettings()
    }

    func selectLanguage(_ language: DictationLanguage) {
        guard settings.language != language else { return }
        settings.language = language
        persistSettings()
        scheduleHUDLayoutUpdate(animated: true)
    }

    func setAIRewriteEnabled(_ enabled: Bool) {
        guard settings.llmRefinementEnabled != enabled else { return }
        settings.llmRefinementEnabled = enabled
        persistSettings()

        if enabled && !llmConfigured {
            errorMessage = localizedText(
                zh: "AI Rewrite 已启用，但 API 信息尚未配置完整，当前会继续直接使用原始转写。",
                en: "AI Rewrite is enabled but not fully configured, so raw transcripts will still be used."
            )
        }
    }

    func prepareSettings() {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil

        do {
            let doubaoToken = try keychainClient.read(account: doubaoAccessTokenAccount)
            assignAccessToken(doubaoToken, markAsEdited: false)
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }

        do {
            let apiKey = try keychainClient.read(account: llmAPIKeyAccount)
            llmSettingsDraft = LLMSettingsDraft(settings: settings, apiKey: apiKey)
        } catch {
            llmSettingsDraft = LLMSettingsDraft(settings: settings, apiKey: "")
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func saveSettings() {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil

        let previousSettings = settingsStore.load()
        let previousAccessTokenPresence = settingsStore.storedAccessTokenPresence()
        let previousLLMAPIKeyPresence = settingsStore.storedLLMAPIKeyPresence()

        settings.appID = settings.appID.trimmed
        settings.resourceID = settings.resourceID.trimmed
        settings.llmBaseURL = llmSettingsDraft.baseURL.trimmed
        settings.llmModel = llmSettingsDraft.model.trimmed

        var persistedSettings = settings
        var warnings: [String] = []

        do {
            let result = try hotkeyService.register(using: settings)
            hotkeyWarningMessage = result.warningMessage
            if let warning = result.warningMessage {
                warnings.append(warning)
            }
        } catch {
            if settings.hotkey != previousSettings.hotkey {
                persistedSettings.hotkey = previousSettings.hotkey
                _ = try? hotkeyService.register(using: previousSettings)
            }
            hotkeyWarningMessage = nil
            warnings.append(error.localizedDescription)
        }

        do {
            try settingsStore.save(persistedSettings)
            try keychainClient.save(accessToken, for: doubaoAccessTokenAccount)
            try keychainClient.save(llmSettingsDraft.apiKey, for: llmAPIKeyAccount)

            let hasToken = !accessToken.trimmed.isEmpty
            let hasLLMAPIKey = !llmSettingsDraft.apiKey.trimmed.isEmpty
            settingsStore.setHasStoredAccessToken(hasToken)
            settingsStore.setHasStoredLLMAPIKey(hasLLMAPIKey)

            storedAccessTokenPresence = hasToken
            hasStoredLLMAPIKey = hasLLMAPIKey
            hasEditedAccessToken = false
            settings = persistedSettings
            llmSettingsDraft = LLMSettingsDraft(settings: persistedSettings, apiKey: llmSettingsDraft.apiKey)

            if warnings.isEmpty {
                llmSettingsStatusMessage = localizedText(zh: "设置已保存。", en: "Settings saved.")
                errorMessage = nil
            } else {
                llmSettingsStatusMessage = localizedText(
                    zh: "设置已保存，但有部分热键变更未生效。",
                    en: "Settings saved, but part of the hotkey change did not apply."
                )
                llmSettingsErrorMessage = warnings.joined(separator: "\n")
            }

            if phase == .idle || phase == .onboarding {
                hotkeyService.update(phase: phase)
            }
        } catch {
            settings = previousSettings
            if let previousAccessTokenPresence {
                settingsStore.setHasStoredAccessToken(previousAccessTokenPresence)
            } else {
                settingsStore.clearStoredAccessTokenPresence()
            }
            if let previousLLMAPIKeyPresence {
                settingsStore.setHasStoredLLMAPIKey(previousLLMAPIKeyPresence)
            } else {
                settingsStore.clearStoredLLMAPIKeyPresence()
            }
            storedAccessTokenPresence = previousAccessTokenPresence
            hasStoredLLMAPIKey = previousLLMAPIKeyPresence
            hotkeyWarningMessage = nil
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func testLLMSettings() async {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil
        isTestingLLMSettings = true
        defer { isTestingLLMSettings = false }

        do {
            try await aiRewriteService.testConnection(using: llmSettingsDraft)
            llmSettingsStatusMessage = localizedText(zh: "AI Rewrite 连接测试成功。", en: "AI Rewrite connection test passed.")
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func clearLLMAPIKeyDraft() {
        llmSettingsDraft.apiKey = ""
    }

    func stopDictationFromUI() {
        Task {
            await stopDictation()
        }
    }

    func cancelFromUI() {
        cancelCurrentSession()
    }

    func handleHotkey(_ event: NoTypeHotkeyEvent) {
        switch event {
        case .startDictation:
            Task {
                await startDictation()
            }
        case .stopDictation:
            Task {
                await stopDictation()
            }
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
                failSession(
                    localizedText(
                        zh: "豆包配置不完整。请先填写 App ID、Resource ID 和 Access Token。",
                        en: "Doubao configuration is incomplete. Fill the App ID, Resource ID, and Access Token first."
                    )
                )
                return
            }

            resetSessionStateForStart()
            let activeSessionID = sessionID
            let provider = providerFactory()
            provider.eventHandler = { [weak self] event in
                Task { @MainActor in
                    self?.handleASREvent(event, sessionID: activeSessionID)
                }
            }

            try await provider.startSession(config: config)
            asrProvider = provider

            _ = try audioCaptureService.startCapture(
                onChunk: { [weak self] frame in
                    guard let self else { return }
                    Task { @MainActor in
                        guard self.sessionID == activeSessionID else { return }
                        do {
                            try await self.asrProvider?.sendAudioFrame(frame, isFinal: false)
                        } catch {
                            self.failSession(error.localizedDescription)
                        }
                    }
                },
                onLevel: { [weak self] level in
                    Task { @MainActor in
                        guard let self, self.sessionID == activeSessionID else { return }
                        self.updateWaveformLevel(level)
                    }
                }
            )

            transition(to: .recording)
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func stopDictation() async {
        guard phase == .recording else { return }
        transition(to: .transcribing)
        waveformLevel = 0

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

    private func cancelCurrentSession() {
        feedbackTask?.cancel()
        completionTask?.cancel()
        sessionID = UUID()
        waveformLevel = 0
        transcriptPreview = ""
        resetRewritePreviewThrottle()
        errorMessage = nil

        do {
            try audioCaptureService.stopCapture(flushRemainder: false)
        } catch {
            hotkeyWarningMessage = error.localizedDescription
        }

        asrProvider?.cancel()
        asrProvider = nil
        transition(to: permissionSnapshot.ready ? .idle : .onboarding)
    }

    private func handleASREvent(_ event: ASRProviderEvent, sessionID activeSessionID: UUID) {
        guard activeSessionID == sessionID else { return }

        switch event {
        case .partialTranscript(let transcript):
            transcriptPreview = transcript
            if phase != .recording {
                transition(to: .transcribing)
            } else {
                scheduleHUDLayoutUpdate()
            }
        case .finalTranscript(let transcript):
            completionTask?.cancel()
            completionTask = Task { [weak self] in
                await self?.completeSession(with: transcript, sessionID: activeSessionID)
            }
        case .error(let message):
            failSession(message)
        }
    }

    private func completeSession(with transcript: String, sessionID activeSessionID: UUID) async {
        guard activeSessionID == sessionID else { return }
        waveformLevel = 0
        asrProvider?.cancel()
        asrProvider = nil

        let normalizedTranscript = TranscriptFormatter.normalize(transcript)
        transcriptPreview = normalizedTranscript

        guard !normalizedTranscript.trimmed.isEmpty else {
            failSession(
                localizedText(
                    zh: "没有检测到有效语音。",
                    en: "No speech was detected."
                )
            )
            return
        }

        var finalText = normalizedTranscript

        if settings.llmRefinementEnabled, let rewriteDraft = loadActiveLLMDraftIfConfigured() {
            transition(to: .refining)
            resetRewritePreviewThrottle()

            do {
                let rewritten = try await aiRewriteService.rewrite(
                    normalizedTranscript,
                    with: rewriteDraft,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            self?.handleRewritePartial(partial, sessionID: activeSessionID)
                        }
                    }
                )
                guard activeSessionID == sessionID else { return }
                pendingRewritePreviewTask?.cancel()
                pendingRewritePreviewText = nil
                finalText = rewritten
                transcriptPreview = rewritten
            } catch is CancellationError {
                return
            } catch {
                guard activeSessionID == sessionID else { return }
                resetRewritePreviewThrottle()
                transcriptPreview = normalizedTranscript
                errorMessage = localizedText(
                    zh: "AI 改写失败，已继续使用原始转写结果。",
                    en: "AI Rewrite failed. Using the raw transcript instead."
                )
            }
        }

        guard activeSessionID == sessionID else { return }

        do {
            let outcome = try await textInsertionService.insert(finalText)
            guard activeSessionID == sessionID else { return }

            transcriptPreview = finalText
            errorMessage = nil

            switch outcome {
            case .pasted:
                transition(to: .inserted)
                scheduleFeedbackReset(after: 1.2)
            case .copiedToClipboard:
                transition(to: .copiedToClipboard)
                scheduleFeedbackReset(after: 1.8)
            case .skipped:
                failSession(
                    localizedText(
                        zh: "最终转写为空，未执行文本注入。",
                        en: "The final transcript was empty, so nothing was pasted."
                    )
                )
            }
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func loadActiveLLMDraftIfConfigured() -> LLMSettingsDraft? {
        guard settings.llmConfiguredWithoutAPIKey else { return nil }

        do {
            let apiKey = try keychainClient.read(account: llmAPIKeyAccount)
            let draft = LLMSettingsDraft(settings: settings, apiKey: apiKey)
            return draft.isConfigured ? draft : nil
        } catch {
            return nil
        }
    }

    private func failSession(_ message: String) {
        feedbackTask?.cancel()
        completionTask?.cancel()
        sessionID = UUID()
        waveformLevel = 0
        resetRewritePreviewThrottle()

        do {
            try audioCaptureService.stopCapture(flushRemainder: false)
        } catch {
            hotkeyWarningMessage = error.localizedDescription
        }

        asrProvider?.cancel()
        asrProvider = nil
        errorMessage = message
        transition(to: .failed)
        scheduleFeedbackReset(after: 2.0)
    }

    private func resetSessionStateForStart() {
        feedbackTask?.cancel()
        completionTask?.cancel()
        sessionID = UUID()
        waveformLevel = 0
        transcriptPreview = ""
        resetRewritePreviewThrottle()
        errorMessage = nil
        hotkeyWarningMessage = nil
        audioCaptureService.clearRecording(at: audioCaptureService.recordingURL)
        asrProvider?.cancel()
        asrProvider = nil
    }

    private func updateWaveformLevel(_ incomingLevel: Double) {
        let smoothing = incomingLevel > waveformLevel ? 0.40 : 0.15
        waveformLevel += (incomingLevel - waveformLevel) * smoothing
        scheduleHUDLayoutUpdate()
    }

    private func handleRewritePartial(_ partial: String, sessionID activeSessionID: UUID) {
        guard activeSessionID == sessionID else { return }

        let now = CFAbsoluteTimeGetCurrent()
        let minimumInterval = 0.05
        let elapsed = now - lastRewritePreviewUpdate

        if elapsed >= minimumInterval {
            transcriptPreview = partial
            pendingRewritePreviewText = nil
            lastRewritePreviewUpdate = now
            scheduleHUDLayoutUpdate()
            return
        }

        pendingRewritePreviewText = partial
        guard pendingRewritePreviewTask == nil else { return }

        pendingRewritePreviewTask = Task { @MainActor [weak self] in
            let remainingDelay = max(0, minimumInterval - elapsed)
            try? await Task.sleep(for: .seconds(remainingDelay))

            guard let self else { return }
            self.pendingRewritePreviewTask = nil
            guard self.sessionID == activeSessionID, let latestPartial = self.pendingRewritePreviewText else { return }

            self.pendingRewritePreviewText = nil
            self.transcriptPreview = latestPartial
            self.lastRewritePreviewUpdate = CFAbsoluteTimeGetCurrent()
            self.scheduleHUDLayoutUpdate()
        }
    }

    private func resetRewritePreviewThrottle() {
        pendingRewritePreviewTask?.cancel()
        pendingRewritePreviewTask = nil
        pendingRewritePreviewText = nil
        lastRewritePreviewUpdate = 0
    }

    private func persistSettings() {
        do {
            try settingsStore.save(settings)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func assignAccessToken(_ value: String, markAsEdited: Bool) {
        isInternallyUpdatingAccessToken = true
        accessToken = value
        isInternallyUpdatingAccessToken = false
        hasLoadedAccessToken = true
        hasEditedAccessToken = markAsEdited
        storedAccessTokenPresence = !value.trimmed.isEmpty
    }

    private func loadAccessTokenIfNeeded() throws -> String {
        guard !hasLoadedAccessToken else {
            return accessToken
        }

        let token = try keychainClient.read(account: doubaoAccessTokenAccount)
        assignAccessToken(token, markAsEdited: false)
        return token
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

    private func transition(to newPhase: DictationPhase) {
        phase = newPhase
        hotkeyService.update(phase: newPhase)
        scheduleHUDLayoutUpdate()
    }

    private func scheduleFeedbackReset(after delay: TimeInterval) {
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self else { return }
            self.waveformLevel = 0
            self.transcriptPreview = ""
            self.resetRewritePreviewThrottle()
            self.errorMessage = nil
            self.transition(to: self.permissionSnapshot.ready ? .idle : .onboarding)
        }
    }

    private func scheduleHUDLayoutUpdate(animated: Bool = true) {
        hudController.update(for: self, animated: animated)
    }

    private func presentPermissionRequirementFeedback(for snapshot: PermissionSnapshot) {
        let message = Self.permissionRequirementMessage(for: snapshot, language: settings.language)
        errorMessage = message
        transition(to: .failed)

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard self.phase == .failed, self.errorMessage == message else { return }
            self.errorMessage = nil
            self.transition(to: .onboarding)
        }
    }

    private func localizedText(zh: String, en: String) -> String {
        settings.language.usesChineseCopy ? zh : en
    }

    nonisolated static func hotkeyAction(for phase: DictationPhase) -> NoTypeHotkeyEvent {
        switch phase {
        case .recording:
            .stopDictation
        case .transcribing, .refining:
            .cancelDictation
        case .onboarding, .idle, .failed, .inserted, .copiedToClipboard:
            .startDictation
        }
    }

    nonisolated static func permissionRequirementMessage(
        for snapshot: PermissionSnapshot,
        language: DictationLanguage
    ) -> String {
        switch (snapshot.microphoneAuthorized, snapshot.accessibilityAuthorized, language.usesChineseCopy) {
        case (false, false, true):
            "需要先授予麦克风和辅助功能权限。打开 Setup 完成授权后再试。"
        case (false, true, true):
            "需要先授予麦克风权限。打开 Setup 完成授权后再试。"
        case (true, false, true):
            "需要先授予辅助功能权限。打开 Setup 完成授权后再试。"
        case (false, false, false):
            "Microphone and Accessibility permissions are required. Open Setup and grant them before trying again."
        case (false, true, false):
            "Microphone permission is required. Open Setup and grant it before trying again."
        case (true, false, false):
            "Accessibility permission is required. Open Setup and grant it before trying again."
        case (true, true, _):
            ""
        }
    }
}
