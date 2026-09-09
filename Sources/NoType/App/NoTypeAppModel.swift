import AppKit
import Foundation

@MainActor
final class NoTypeAppModel: ObservableObject {
    @Published var settings: AppSettings
    @Published private(set) var speechProviderDraft: SpeechProvider
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
    @Published var llmSettingsStatusMessage: String?
    @Published var llmSettingsErrorMessage: String?
    @Published var isTestingLLMSettings = false

    let neoVoice = NeoVoiceController()

    private let settingsStore: SettingsStore
    private let keychainClient: KeychainClient
    private let permissionService: PermissionService
    private let hotkeyService: HotkeyService
    private let tripleSpaceTriggerService: TripleSpaceTriggerService
    private let bridgeService: NoTypeBridgeService
    private let agentEditorIntegrationService: AgentEditorIntegrationService
    private let audioCaptureService: AudioCaptureService
    private let textInsertionService: TextInsertionService
    private let aiRewriteService: AIRewriteService
    private let codexTranscriptionService: CodexTranscriptionService
    private let hudController: HUDPanelController
    private let selectionTranslationController: SelectionTranslationPanelController
    private let providerFactory: () -> ASRProvider
    private let doubaoAccessTokenAccount = "doubao.access-token"

    private var asrProvider: ASRProvider?
    private var hasLoadedAccessToken = false
    private var hasEditedAccessToken = false
    private var isInternallyUpdatingAccessToken = false
    private var storedAccessTokenPresence: Bool?
    private var feedbackTask: Task<Void, Never>?
    private var completionTask: Task<Void, Never>?
    private var transcriptionTask: Task<String, Error>?
    private var activeSpeechProvider: SpeechProvider = .doubao
    private var shouldRewriteCurrentDictation = false
    private var pendingRewritePreviewTask: Task<Void, Never>?
    private var pendingRewritePreviewText: String?
    private var lastRewritePreviewUpdate = 0.0
    private var sessionID = UUID()
    private var currentOutputMode: DictationOutputMode = .dictation
    private var bridgeAdmission = NoTypeBridgeAdmission()
    private var lastDirectBridgeRequest: (timestamp: TimeInterval, processIdentifier: Int32)?

    init(
        settingsStore: SettingsStore = SettingsStore(),
        keychainClient: KeychainClient = KeychainClient(),
        permissionService: PermissionService = PermissionService(),
        hotkeyService: HotkeyService = HotkeyService(),
        tripleSpaceTriggerService: TripleSpaceTriggerService = TripleSpaceTriggerService(),
        bridgeService: NoTypeBridgeService = NoTypeBridgeService(),
        agentEditorIntegrationService: AgentEditorIntegrationService =
            AgentEditorIntegrationService(),
        audioCaptureService: AudioCaptureService = AudioCaptureService(),
        textInsertionService: TextInsertionService = TextInsertionService(),
        aiRewriteService: AIRewriteService = AIRewriteService(),
        codexTranscriptionService: CodexTranscriptionService = CodexTranscriptionService(),
        hudController: HUDPanelController = HUDPanelController(),
        providerFactory: @escaping () -> ASRProvider = { DoubaoStreamingASRProvider() }
    ) {
        self.settingsStore = settingsStore
        self.keychainClient = keychainClient
        self.permissionService = permissionService
        self.hotkeyService = hotkeyService
        self.tripleSpaceTriggerService = tripleSpaceTriggerService
        self.bridgeService = bridgeService
        self.agentEditorIntegrationService = agentEditorIntegrationService
        self.audioCaptureService = audioCaptureService
        self.textInsertionService = textInsertionService
        self.aiRewriteService = aiRewriteService
        self.codexTranscriptionService = codexTranscriptionService
        self.hudController = hudController
        self.selectionTranslationController = SelectionTranslationPanelController(
            model: SelectionTranslationModel(
                readSelection: { [permissionService, textInsertionService] in
                    guard permissionService.accessibilityAuthorized else {
                        throw NSError(domain: "NoType", code: 1, userInfo: [
                            NSLocalizedDescriptionKey: "需要辅助功能权限才能读取选中文字。请打开 Setup 完成授权。",
                        ])
                    }
                    return await textInsertionService.selectedText()
                },
                translate: { [aiRewriteService] text, onPartial in
                    try await aiRewriteService.translateToChinese(text, onPartial: onPartial)
                }
            )
        )
        self.providerFactory = providerFactory

        let settings = settingsStore.load()
        self.settings = settings
        speechProviderDraft = settings.speechProvider
        storedAccessTokenPresence = settingsStore.storedAccessTokenPresence()
        permissionSnapshot = PermissionSnapshot(
            microphoneAuthorized: false,
            accessibilityAuthorized: false
        )
        phase = .onboarding

        hotkeyService.eventHandler = { [weak self] event in
            Task { @MainActor in
                self?.handleHotkey(event)
            }
        }
        tripleSpaceTriggerService.eventHandler = { [weak self] in
            Task { @MainActor in
                await self?.translateFocusedFieldAfterTripleSpace()
            }
        }

        neoVoice.onChange = { [weak self] in
            guard let self else { return }
            self.objectWillChange.send()
            self.scheduleHUDLayoutUpdate()
        }
        hudController.attach(to: self)
    }

    var menuBarIcon: NSImage {
        if neoVoice.state.inConversation { return MenuBarIconProvider.recording }
        return switch phase {
        case .recording:
            MenuBarIconProvider.recording
        case .transcribing, .refining:
            MenuBarIconProvider.transcribing
        case .inserted, .copiedToClipboard:
            MenuBarIconProvider.success
        case .failed:
            MenuBarIconProvider.failed
        case .idle, .onboarding:
            MenuBarIconProvider.idle
        }
    }

    var aiRewriteEnabled: Bool {
        settings.shouldRewriteDictation
    }

    var hasCodexOAuthCredentials: Bool {
        guard let credentials = try? CodexAuthStore().loadCredentials() else {
            return false
        }
        return !credentials.isExpired
    }

    var hasASRCredentials: Bool {
        if settings.speechProvider == .codex { return hasCodexOAuthCredentials }
        guard settings.hasValidASRConfiguration else { return false }
        if hasLoadedAccessToken {
            return !accessToken.trimmed.isEmpty
        }
        return storedAccessTokenPresence ?? true
    }

    var hotkeyDisplayName: String {
        "Option + Space"
    }

    var translationHotkeyDisplayName: String {
        "Option + Shift + Space"
    }

    var selectionTranslationHotkeyDisplayName: String {
        "Option + Control + Space"
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
            return preview.isEmpty ? localizedText(zh: "正在处理…", en: "Processing…") : preview
        case .inserted:
            return localizedText(zh: "已粘贴到当前输入框", en: "Pasted into the focused field")
        case .copiedToClipboard:
            return localizedText(zh: "已复制到剪贴板，可手动粘贴", en: "Copied to clipboard. Paste anywhere.")
        case .failed:
            return errorMessage ?? localizedText(zh: "语音输入失败", en: "Dictation failed")
        case .idle:
            return localizedText(
                zh: "按 \(hotkeyDisplayName) 开始录音，按 \(translationHotkeyDisplayName) 翻译成英文",
                en: "Press \(hotkeyDisplayName) to dictate. Press \(translationHotkeyDisplayName) to translate to English."
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
            if settings.speechProvider == .codex {
                return localizedText(
                    zh: "语音输入需要 Codex 登录态。请先运行 codex login。",
                    en: "Dictation requires Codex login. Run codex login first."
                )
            }
            return localizedText(
                zh: "先在 Settings 中配置豆包 App ID、Resource ID 和 Access Token。",
                en: "Configure the Doubao App ID, Resource ID, and Access Token in Settings first."
            )
        }

        switch phase {
        case .idle:
            return localizedText(
                zh: "准备就绪，按 \(hotkeyDisplayName) 语音输入，按 \(translationHotkeyDisplayName) 翻译成英文。",
                en: "Ready. Press \(hotkeyDisplayName) for dictation, or \(translationHotkeyDisplayName) to translate to English."
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
                zh: "正在进行 AI 处理，再按 \(hotkeyDisplayName) 可取消。",
                en: "AI processing is running. Press \(hotkeyDisplayName) again to cancel."
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
            let result = try hotkeyService.register()
            hotkeyWarningMessage = result.warningMessage
        } catch {
            hotkeyWarningMessage = nil
            errorMessage = error.localizedDescription
        }

        registerTripleSpaceTriggerIfPossible()
        startBridgeService()
        neoVoice.setWakePhrase(settings.neoWakePhrase)
        neoVoice.setWakeEnabled(settings.neoWakeEnabled)

        scheduleHUDLayoutUpdate(animated: false)
    }

    func shutdown() {
        neoVoice.shutdown()
        selectionTranslationController.close()
        agentEditorIntegrationService.shutdown()
        bridgeService.stop()
    }

    func refreshPermissions() {
        permissionSnapshot = permissionService.snapshot()
        if phase != .recording, phase != .transcribing, phase != .refining {
            transition(to: permissionSnapshot.ready ? .idle : .onboarding)
        }
        registerTripleSpaceTriggerIfPossible()
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

    func setNeoWakeEnabled(_ enabled: Bool) {
        do {
            var persisted = settingsStore.load()
            persisted.neoWakeEnabled = enabled
            try settingsStore.save(persisted)
            settings.neoWakeEnabled = enabled
            neoVoice.setWakeEnabled(enabled)
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func startNeoConversation() {
        guard phase != .recording, phase != .transcribing, phase != .refining else { return }
        neoVoice.startConversation()
    }

    func setNeoWakePhrase(_ value: String) {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil
        guard let phrase = AppSettings.normalizedNeoWakePhrase(value) else {
            llmSettingsErrorMessage = "请输入包含中文或英文字母的唤醒词。"
            return
        }
        do {
            var persisted = settingsStore.load()
            persisted.neoWakePhrase = phrase
            try settingsStore.save(persisted)
            settings.neoWakePhrase = phrase
            neoVoice.setWakePhrase(phrase)
            llmSettingsStatusMessage = "唤醒词已更新"
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func selectLanguage(_ language: DictationLanguage) {
        guard settings.language != language else { return }
        settings.language = language
        persistSettings()
        scheduleHUDLayoutUpdate(animated: true)
    }

    func setAIRewriteEnabled(_ enabled: Bool) {
        guard settings.speechProvider == .doubao else { return }
        guard settings.llmRefinementEnabled != enabled else { return }
        settings.llmRefinementEnabled = enabled
        persistSettings()

        if enabled && !hasCodexOAuthCredentials {
            errorMessage = localizedText(
                zh: "AI Rewrite 已启用，但未找到 Codex 登录态，当前会继续直接使用原始转写。",
                en: "AI Rewrite is enabled but Codex is not logged in, so raw transcripts will still be used."
            )
        }
    }

    func setAgentTUITranslationEnabled(_ enabled: Bool) {
        guard settings.agentTUITranslationEnabled != enabled else { return }
        settings.agentTUITranslationEnabled = enabled
        persistSettings()
    }

    func prepareSettings() {
        speechProviderDraft = settings.speechProvider
        prepareSpeechProviderSettings()
    }

    func selectSpeechProviderForSettings(_ provider: SpeechProvider) {
        speechProviderDraft = provider
        prepareSpeechProviderSettings()
    }

    private func prepareSpeechProviderSettings() {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil

        guard speechProviderDraft == .doubao, !hasEditedAccessToken else { return }

        do {
            let doubaoToken = try keychainClient.read(account: doubaoAccessTokenAccount)
            assignAccessToken(doubaoToken, markAsEdited: false)
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func saveSettings() {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil

        let previousSettings = settingsStore.load()
        let previousAccessTokenPresence = settingsStore.storedAccessTokenPresence()

        settings.appID = settings.appID.trimmed
        settings.resourceID = settings.resourceID.trimmed

        var persistedSettings = settings
        persistedSettings.speechProvider = speechProviderDraft
        var warnings: [String] = []

        do {
            let result = try hotkeyService.register()
            hotkeyWarningMessage = result.warningMessage
            if let warning = result.warningMessage {
                warnings.append(warning)
            }
        } catch {
            if settings.hotkey != previousSettings.hotkey {
                persistedSettings.hotkey = previousSettings.hotkey
                _ = try? hotkeyService.register()
            }
            hotkeyWarningMessage = nil
            warnings.append(error.localizedDescription)
        }

        do {
            if hasEditedAccessToken {
                try keychainClient.save(accessToken, for: doubaoAccessTokenAccount)
                let hasToken = !accessToken.trimmed.isEmpty
                settingsStore.setHasStoredAccessToken(hasToken)
                storedAccessTokenPresence = hasToken
            }
            try settingsStore.save(persistedSettings)
            hasEditedAccessToken = false
            settings = persistedSettings

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
            storedAccessTokenPresence = previousAccessTokenPresence
            hotkeyWarningMessage = nil
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func testASRConnection() async {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil
        isTestingLLMSettings = true
        defer { isTestingLLMSettings = false }

        do {
            if speechProviderDraft == .codex {
                try codexTranscriptionService.checkCredentials()
                llmSettingsStatusMessage = localizedText(
                    zh: "Codex 登录有效。请录音验证语音转写。",
                    en: "Codex login is valid. Record audio to verify transcription."
                )
                return
            }
            guard let config = try currentASRSessionConfig() else {
                llmSettingsErrorMessage = localizedText(
                    zh: "请先填写 App ID、Resource ID 和 Access Token。",
                    en: "Fill in App ID, Resource ID, and Access Token first."
                )
                return
            }
            try await DoubaoStreamingASRProvider.testConnection(config: config)
            llmSettingsStatusMessage = localizedText(
                zh: "语音识别连接测试成功。",
                en: "Speech connection test passed."
            )
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func testAIRewriteConnection() async {
        llmSettingsStatusMessage = nil
        llmSettingsErrorMessage = nil
        isTestingLLMSettings = true
        defer { isTestingLLMSettings = false }

        do {
            try await aiRewriteService.testConnection()
            llmSettingsStatusMessage = localizedText(
                zh: "AI Rewrite 连接测试成功。",
                en: "AI Rewrite connection test passed."
            )
        } catch {
            llmSettingsErrorMessage = error.localizedDescription
        }
    }

    func handleHotkey(_ event: NoTypeHotkeyEvent) {
        switch event {
        case .translateSelectionToChinese:
            guard phase != .recording, phase != .transcribing, phase != .refining else { return }
            selectionTranslationController.show()
        case .startDictation(let mode):
            selectionTranslationController.close()
            Task {
                await startDictation(mode: mode)
            }
        case .stopDictation:
            Task {
                await stopDictation()
            }
        case .cancelDictation:
            if neoVoice.state.hudVisible {
                neoVoice.endConversation()
                return
            }
            selectionTranslationController.close()
            cancelCurrentSession()
        }
    }

    private func startDictation(mode: DictationOutputMode) async {
        if mode == .translation, await translateSelectedTextIfPossible() {
            return
        }

        permissionSnapshot = permissionService.snapshot()
        guard permissionSnapshot.ready else {
            presentPermissionRequirementFeedback(for: permissionSnapshot)
            return
        }

        do {
            let config: ASRSessionConfig?
            if settings.speechProvider == .codex {
                try codexTranscriptionService.checkCredentials()
                config = nil
            } else {
                config = try currentASRSessionConfig()
            }
            if settings.speechProvider == .doubao, config == nil {
                failSession(
                    localizedText(
                        zh: "豆包配置不完整。请先填写 App ID、Resource ID 和 Access Token。",
                        en: "Doubao configuration is incomplete. Fill the App ID, Resource ID, and Access Token first."
                    )
                )
                return
            }

            neoVoice.setSuspended(true)
            resetSessionStateForStart()
            currentOutputMode = mode
            activeSpeechProvider = settings.speechProvider
            shouldRewriteCurrentDictation = settings.shouldRewriteDictation
            let activeSessionID = sessionID
            if let config {
                let provider = providerFactory()
                provider.eventHandler = { [weak self] event in
                    Task { @MainActor in
                        self?.handleASREvent(event, sessionID: activeSessionID)
                    }
                }

                try await provider.startSession(config: config)
                guard sessionID == activeSessionID else { provider.cancel(); return }
                asrProvider = provider
            }

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
        let activeSessionID = sessionID
        transition(to: .transcribing)
        waveformLevel = 0

        do {
            let stopResult = try audioCaptureService.stopCaptureForFinalization()
            defer { audioCaptureService.clearRecording(at: stopResult.recordingURL) }
            if activeSpeechProvider == .codex {
                guard let recordingURL = stopResult.recordingURL else {
                    throw CodexTranscriptionError.noSpeech
                }
                // The finalized file includes every captured chunk and the trailing
                // partial frame, independent of pending main-actor chunk callbacks.
                let pcm = try Data(contentsOf: recordingURL)
                let task = Task { try await codexTranscriptionService.transcribe(pcm: pcm) }
                transcriptionTask = task
                let transcript = try await task.value
                guard sessionID == activeSessionID else { return }
                transcriptionTask = nil
                handleASREvent(.finalTranscript(transcript), sessionID: activeSessionID)
                return
            }
            if let finalFrame = stopResult.flushedRemainder, !finalFrame.isEmpty {
                try await asrProvider?.sendAudioFrame(finalFrame, isFinal: false)
            }
            try await asrProvider?.finish()
        } catch {
            guard sessionID == activeSessionID else { return }
            transcriptionTask = nil
            failSession(error.localizedDescription)
        }
    }

    private func cancelCurrentSession() {
        feedbackTask?.cancel()
        completionTask?.cancel()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sessionID = UUID()
        waveformLevel = 0
        transcriptPreview = ""
        currentOutputMode = .dictation
        resetRewritePreviewThrottle()
        errorMessage = nil

        do {
            let recordingURL = try audioCaptureService.stopCapture(flushRemainder: false)
            audioCaptureService.clearRecording(at: recordingURL)
        } catch {
            hotkeyWarningMessage = error.localizedDescription
        }

        asrProvider?.cancel()
        asrProvider = nil
        transition(to: permissionSnapshot.ready ? .idle : .onboarding)
    }

    private func translateSelectedTextIfPossible() async -> Bool {
        guard let selectedText = await textInsertionService.selectedText(), !selectedText.trimmed.isEmpty else {
            return false
        }

        guard validateTranslationCredentials() else { return true }
        await translateTextReplacingCurrentSelection(selectedText)
        return true
    }

    private func translateFocusedFieldAfterTripleSpace() async {
        guard phase == .idle else { return }
        guard validateTranslationCredentials() else { return }

        let target = DictationTargetContext.currentFrontmost()
        if AgentEditorIntegrationService.supportsTerminal(target) {
            // Never treat a terminal's rendered AXValue as an editable field. Pi's native
            // adapter receives the same third Space just after this event tap, so give it
            // a brief chance to claim the draft before opening an external editor.
            guard settings.agentTUITranslationEnabled else { return }
            try? await Task.sleep(for: .milliseconds(150))
            guard !hasRecentDirectBridgeRequest(for: target) else { return }

            do {
                try agentEditorIntegrationService.triggerExternalEditor(for: target)
            } catch {
                appendWarning(error.localizedDescription)
            }
            return
        }

        guard let sourceText = await textInsertionService.prepareFocusedFieldForTripleSpaceTranslation() else {
            return
        }
        await translateTextReplacingCurrentSelection(sourceText)
    }

    private func hasRecentDirectBridgeRequest(for target: DictationTargetContext) -> Bool {
        guard let lastDirectBridgeRequest,
              lastDirectBridgeRequest.processIdentifier == target.processIdentifier
        else {
            return false
        }
        let age = Date.timeIntervalSinceReferenceDate - lastDirectBridgeRequest.timestamp
        return age >= 0 && age < 2
    }

    private func handleBridgeRequest(
        _ request: NoTypeBridgeRequest,
        onPartial: @escaping NoTypeBridgeService.ProgressHandler
    ) async -> NoTypeBridgeResponse {
        guard request.version == NoTypeBridgeProtocol.version else {
            return .failure(
                id: request.id,
                code: "unsupported_version",
                message: "Unsupported NoType bridge protocol version: \(request.version)."
            )
        }

        guard !request.id.isEmpty, request.id.utf8.count <= 128 else {
            return .failure(
                id: request.id,
                code: "invalid_request_id",
                message: "The NoType bridge request ID must contain 1 to 128 bytes."
            )
        }

        if request.method == NoTypeBridgeProtocol.pingMethod {
            return .success(id: request.id, text: "pong")
        }

        switch request.method {
        case NoTypeBridgeProtocol.translateChineseMethod, NoTypeBridgeProtocol.translateChineseBatchMethod:
            break
        case NoTypeBridgeProtocol.translateMethod:
            if request.client == "pi" {
                let target = DictationTargetContext.currentFrontmost()
                lastDirectBridgeRequest = (
                    timestamp: Date.timeIntervalSinceReferenceDate,
                    processIdentifier: target.processIdentifier
                )
            }
        case NoTypeBridgeProtocol.translateEditorMethod:
            guard request.client == "agent-editor",
                  request.trigger == "triple-space",
                  let token = request.token,
                  UUID(uuidString: token) != nil,
                  let processID = request.processID,
                  let parentProcessID = request.parentProcessID,
                  let terminal = request.terminal,
                  terminal.utf8.count <= 1_024,
                  agentEditorIntegrationService.consumePendingTrigger(
                    token: token,
                    processID: processID,
                    parentProcessID: parentProcessID,
                    terminal: terminal
                  )
            else {
                return .failure(
                    id: request.id,
                    code: "invalid_editor_trigger",
                    message: "The NoType agent editor trigger is missing, stale, or belongs to another terminal."
                )
            }
        default:
            return .failure(
                id: request.id,
                code: "unsupported_method",
                message: "Unsupported NoType bridge method: \(request.method)."
            )
        }

        let isBatch = request.method == NoTypeBridgeProtocol.translateChineseBatchMethod
        if isBatch {
            do { try NoTypeBrowserBatch.validate(request.items ?? []) }
            catch {
                return .failure(id: request.id, code: "invalid_batch", message: "翻译批次无效或超过段数/长度限制。")
            }
        }
        let sourceText = request.text ?? ""
        guard isBatch || !sourceText.trimmed.isEmpty else {
            return .failure(
                id: request.id,
                code: "empty_text",
                message: "The NoType bridge translation text is empty."
            )
        }

        guard phase != .recording,
              phase != .transcribing,
              phase != .refining,
              let bridgeToken = bridgeAdmission.acquire(browser: isBatch && request.client == "browser")
        else {
            return .failure(
                id: request.id,
                code: "busy",
                message: "NoType is already processing another request."
            )
        }
        defer { bridgeAdmission.release(bridgeToken) }

        guard hasCodexOAuthCredentials else {
            return .failure(
                id: request.id,
                code: "missing_codex_auth",
                message: "Translation requires Codex login. Run `codex login` first."
            )
        }

        do {
            if isBatch {
                let items = try await aiRewriteService.translateBrowserBatch(request.items ?? []) { partial in
                    var progress = NoTypeBridgeResponse.success(id: request.id, text: partial)
                    progress.partial = true
                    onPartial(progress)
                }
                var response = NoTypeBridgeResponse.success(id: request.id)
                response.items = items
                return response
            }
            let translated: String
            if request.method == NoTypeBridgeProtocol.translateChineseMethod {
                translated = try await aiRewriteService.translateToChinese(sourceText)
            } else {
                translated = try await aiRewriteService.translateToEnglish(sourceText)
            }
            return .success(id: request.id, text: translated)
        } catch {
            return .failure(
                id: request.id,
                code: "translation_failed",
                message: error.localizedDescription
            )
        }
    }

    private func validateTranslationCredentials() -> Bool {
        guard hasCodexOAuthCredentials else {
            failSession(
                localizedText(
                    zh: "翻译需要 Codex 登录态。请先运行 codex login。",
                    en: "Translation requires Codex login. Run codex login first."
                )
            )
            return false
        }
        return true
    }

    private func translateTextReplacingCurrentSelection(_ sourceText: String) async {
        resetSessionStateForStart()
        currentOutputMode = .translation
        let activeSessionID = sessionID
        transcriptPreview = sourceText
        transition(to: .refining)
        resetRewritePreviewThrottle()

        do {
            let translated = try await aiRewriteService.translateToEnglish(
                sourceText,
                onPartial: { [weak self] partial in
                    Task { @MainActor in
                        self?.handleRewritePartial(partial, sessionID: activeSessionID)
                    }
                }
            )
            guard activeSessionID == sessionID else { return }
            pendingRewritePreviewTask?.cancel()
            pendingRewritePreviewText = nil
            await insertFinalText(
                translated,
                sessionID: activeSessionID,
                emptyMessage: localizedText(
                    zh: "翻译结果为空，未执行文本注入。",
                    en: "The translation was empty, so nothing was pasted."
                )
            )
        } catch is CancellationError {
            return
        } catch {
            guard activeSessionID == sessionID else { return }
            failSession(error.localizedDescription)
        }
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

        let normalizedTranscript = activeSpeechProvider == .codex
            ? transcript.trimmed
            : TranscriptFormatter.normalize(transcript)
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

        if currentOutputMode == .translation {
            guard hasCodexOAuthCredentials else {
                failSession(
                    localizedText(
                        zh: "翻译需要 Codex 登录态。请先运行 codex login。",
                        en: "Translation requires Codex login. Run codex login first."
                    )
                )
                return
            }

            transition(to: .refining)
            resetRewritePreviewThrottle()

            do {
                let translated = try await aiRewriteService.translateToEnglish(
                    normalizedTranscript,
                    onPartial: { [weak self] partial in
                        Task { @MainActor in
                            self?.handleRewritePartial(partial, sessionID: activeSessionID)
                        }
                    }
                )
                guard activeSessionID == sessionID else { return }
                pendingRewritePreviewTask?.cancel()
                pendingRewritePreviewText = nil
                finalText = translated
                transcriptPreview = translated
            } catch is CancellationError {
                return
            } catch {
                guard activeSessionID == sessionID else { return }
                failSession(error.localizedDescription)
                return
            }
        } else if shouldRewriteCurrentDictation, hasCodexOAuthCredentials {
            transition(to: .refining)
            resetRewritePreviewThrottle()

            do {
                let rewritten = try await aiRewriteService.rewrite(
                    normalizedTranscript,
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

        await insertFinalText(
            finalText,
            sessionID: activeSessionID,
            emptyMessage: localizedText(
                zh: "最终转写为空，未执行文本注入。",
                en: "The final transcript was empty, so nothing was pasted."
            )
        )
    }

    private func insertFinalText(_ finalText: String, sessionID activeSessionID: UUID, emptyMessage: String) async {
        guard activeSessionID == sessionID else { return }

        do {
            let outcome = try await textInsertionService.insert(finalText)
            guard activeSessionID == sessionID else { return }

            transcriptPreview = finalText
            errorMessage = nil

            switch outcome {
            case .pasted:
                feedbackTask?.cancel()
                waveformLevel = 0
                resetRewritePreviewThrottle()
                transition(to: permissionSnapshot.ready ? .idle : .onboarding)
            case .copiedToClipboard:
                transition(to: .copiedToClipboard)
                scheduleFeedbackReset(after: 1.8)
            case .skipped:
                failSession(emptyMessage)
            }
        } catch {
            failSession(error.localizedDescription)
        }
    }

    private func failSession(_ message: String) {
        feedbackTask?.cancel()
        completionTask?.cancel()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        sessionID = UUID()
        waveformLevel = 0
        resetRewritePreviewThrottle()

        do {
            let recordingURL = try audioCaptureService.stopCapture(flushRemainder: false)
            audioCaptureService.clearRecording(at: recordingURL)
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
        transcriptionTask?.cancel()
        transcriptionTask = nil
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

    private func startBridgeService() {
        do {
            try bridgeService.start(
                requestHandler: { [weak self] request, onPartial in
                    guard let self else {
                        return .failure(
                            id: request.id,
                            code: "app_unavailable",
                            message: "NoType is shutting down."
                        )
                    }
                    return await self.handleBridgeRequest(request, onPartial: onPartial)
                },
                failureHandler: { [weak self] message in
                    Task { @MainActor [weak self] in
                        self?.appendWarning("NoType bridge: \(message)")
                    }
                }
            )
        } catch {
            appendWarning(error.localizedDescription)
        }
    }

    private func registerTripleSpaceTriggerIfPossible() {
        guard permissionSnapshot.accessibilityAuthorized else { return }

        do {
            try tripleSpaceTriggerService.register()
        } catch {
            appendWarning(error.localizedDescription)
        }
    }

    private func appendWarning(_ message: String) {
        if let currentWarning = hotkeyWarningMessage, !currentWarning.isEmpty {
            guard !currentWarning.contains(message) else { return }
            hotkeyWarningMessage = currentWarning + "\n" + message
        } else {
            hotkeyWarningMessage = message
        }
    }

    private func transition(to newPhase: DictationPhase) {
        phase = newPhase
        hotkeyService.update(phase: newPhase)
        if newPhase == .idle || newPhase == .onboarding {
            neoVoice.setSuspended(false)
        } else if newPhase == .recording || newPhase == .transcribing || newPhase == .refining {
            neoVoice.setSuspended(true)
        }
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

    nonisolated static func hotkeyAction(
        for phase: DictationPhase,
        requestedMode: DictationOutputMode = .dictation
    ) -> NoTypeHotkeyEvent {
        switch phase {
        case .recording:
            .stopDictation
        case .transcribing, .refining:
            .cancelDictation
        case .onboarding, .idle, .failed, .inserted, .copiedToClipboard:
            .startDictation(requestedMode)
        }
    }

    nonisolated static func permissionRequirementMessage(
        for snapshot: PermissionSnapshot,
        language: DictationLanguage
    ) -> String {
        guard !snapshot.ready else { return "" }

        if language.usesChineseCopy {
            var missing: [String] = []
            if !snapshot.microphoneAuthorized { missing.append("麦克风") }
            if !snapshot.accessibilityAuthorized { missing.append("辅助功能") }
            return "需要先授予\(missing.joined(separator: "、"))权限。打开 Setup 完成授权后再试。"
        }

        var missing: [String] = []
        if !snapshot.microphoneAuthorized { missing.append("Microphone") }
        if !snapshot.accessibilityAuthorized { missing.append("Accessibility") }
        if missing.count == 1 {
            return "\(missing[0]) permission is required. Open Setup and grant it before trying again."
        }
        return "\(missing.joined(separator: ", ")) permissions are required. Open Setup and grant them before trying again."
    }
}
