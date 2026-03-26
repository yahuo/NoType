import Foundation
import Testing
@testable import NoType

@Test
func pcmChunkingSplitsDataIntoFixedFrames() {
    let bytes = Data(repeating: 0x7F, count: PCMUtilities.chunkByteCount * 2 + 123)
    let chunks = PCMUtilities.chunk(bytes)

    #expect(chunks.count == 3)
    #expect(chunks[0].count == PCMUtilities.chunkByteCount)
    #expect(chunks[1].count == PCMUtilities.chunkByteCount)
    #expect(chunks[2].count == 123)
}

@Test
func transcriptFormatterMapsSpokenCommandsAndCollapsesWhitespace() {
    let raw = "  你好  换行   世界   新段落  测试  "
    let normalized = TranscriptFormatter.normalize(raw)

    #expect(normalized == "你好 \n 世界 \n\n 测试")
}

@Test
func doubaoAudioRequestMarksFinalFrameInHeader() {
    let audio = Data([0x01, 0x02, 0x03])

    let regular = DoubaoStreamingASRProvider.makeAudioRequest(audioData: audio, isFinal: false)
    let final = DoubaoStreamingASRProvider.makeAudioRequest(audioData: audio, isFinal: true)

    #expect(regular[1] == 0x20)
    #expect(final[1] == 0x22)
}

@Test
func settingsStoreRoundTripsAppSettings() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = SettingsStore(userDefaults: defaults)

    let settings = AppSettings(
        appID: "app-id",
        resourceID: "volc.seedasr.sauc.duration",
        microphoneID: "mic-id",
        autoInsert: false,
        showDockIcon: true,
        historyRetentionDays: 14,
        launchAtLogin: true,
        hotkey: .commandShiftSpace,
        language: .enUS
    )

    try store.save(settings)
    let loaded = store.load()

    #expect(loaded == settings)
}

@Test
func settingsStoreTracksWhetherAccessTokenExists() {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let store = SettingsStore(userDefaults: defaults)

    #expect(store.storedAccessTokenPresence() == nil)
    store.setHasStoredAccessToken(true)
    #expect(store.storedAccessTokenPresence() == true)
    store.clearStoredAccessTokenPresence()
    #expect(store.storedAccessTokenPresence() == nil)
}

@Test
func settingsStoreMigratesLegacyClusterField() throws {
    let defaults = UserDefaults(suiteName: UUID().uuidString)!
    let legacyPayload = """
    {
      "appID": "app-id",
      "cluster": "legacy-cluster",
      "microphoneID": "mic-id",
      "autoInsert": true,
      "showDockIcon": false,
      "historyRetentionDays": 30,
      "launchAtLogin": false,
      "hotkey": "optionSpace",
      "language": "zh-CN"
    }
    """.data(using: .utf8)!

    defaults.set(legacyPayload, forKey: "notype.settings")

    let loaded = SettingsStore(userDefaults: defaults).load()

    #expect(loaded.resourceID == "legacy-cluster")
}

@Test
func appSettingsDefaultResourceIDUsesDoubao20Duration() {
    #expect(AppSettings.defaults.resourceID == "volc.seedasr.sauc.duration")
}

@Test
func appSettingsDefaultDockIconModeIsEnabled() {
    #expect(AppSettings.defaults.showDockIcon)
}

@Test
func appSettingsDecodeFallsBackToDefaultResourceIDWhenBlank() throws {
    let payload = """
    {
      "appID": "app-id",
      "resourceID": "",
      "microphoneID": null,
      "autoInsert": true,
      "showDockIcon": false,
      "historyRetentionDays": 30,
      "launchAtLogin": false,
      "hotkey": "optionSpace",
      "language": "zh-CN"
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(AppSettings.self, from: payload)
    #expect(decoded.resourceID == "volc.seedasr.sauc.duration")
}

@Test
func doubaoWebSocketRequestUsesV2ResourceHeaders() {
    let config = ASRSessionConfig(
        appID: "123456789",
        accessToken: "token-value",
        resourceID: "volc.seedasr.sauc.duration",
        userID: "host",
        language: .zhCN,
        workflow: "audio_in,resample",
        utteranceMode: true
    )

    let request = DoubaoStreamingASRProvider.makeWebSocketRequest(
        for: config,
        connectID: "connect-id",
        userAgent: "NoType/test"
    )

    #expect(request.value(forHTTPHeaderField: "X-Api-App-Key") == "123456789")
    #expect(request.value(forHTTPHeaderField: "X-Api-Access-Key") == "token-value")
    #expect(request.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
    #expect(request.value(forHTTPHeaderField: "X-Api-Connect-Id") == "connect-id")
    #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
}

@Test
func handshakeProbeBuildsHTTPUpgradeRequestFromWebSocketRequest() throws {
    let config = ASRSessionConfig(
        appID: "123456789",
        accessToken: "token-value",
        resourceID: "volc.seedasr.sauc.duration",
        userID: "host",
        language: .zhCN,
        workflow: "audio_in,resample",
        utteranceMode: true
    )

    let webSocketRequest = DoubaoStreamingASRProvider.makeWebSocketRequest(
        for: config,
        connectID: "connect-id",
        userAgent: "NoType/test"
    )
    let handshakeRequest = try DoubaoHandshakeProbe.makeHTTPRequest(from: webSocketRequest)

    #expect(handshakeRequest.url?.absoluteString == "https://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")
    #expect(handshakeRequest.value(forHTTPHeaderField: "Upgrade") == "websocket")
    #expect(handshakeRequest.value(forHTTPHeaderField: "Connection") == "Upgrade")
    #expect(handshakeRequest.value(forHTTPHeaderField: "X-Api-App-Key") == "123456789")
    #expect(handshakeRequest.value(forHTTPHeaderField: "X-Api-Resource-Id") == "volc.seedasr.sauc.duration")
}

@Test
func textInsertionServiceSkipsWhitespaceOnlyInsertions() {
    #expect(TextInsertionService.shouldInsert("hello"))
    #expect(!TextInsertionService.shouldInsert(""))
    #expect(!TextInsertionService.shouldInsert("  \n\t  "))
}

@Test
func pasteboardRestoreOnlyRunsWhenClipboardDidNotChangeAfterFallback() {
    #expect(TextInsertionService.shouldRestorePasteboard(currentChangeCount: 7, insertedChangeCount: 7))
    #expect(!TextInsertionService.shouldRestorePasteboard(currentChangeCount: 8, insertedChangeCount: 7))
}

@Test
func fullClientRequestIncludesConfiguredLanguage() throws {
    let config = ASRSessionConfig(
        appID: "123456789",
        accessToken: "token-value",
        resourceID: "volc.seedasr.sauc.duration",
        userID: "host",
        language: .enUS,
        workflow: "audio_in,resample",
        utteranceMode: true
    )

    let payload = try DoubaoStreamingASRProvider.makeFullClientRequest(for: config, requestID: "request-id")
    let jsonData = payload.dropFirst(8)
    let root = try #require(JSONSerialization.jsonObject(with: jsonData) as? [String: Any])
    let audio = try #require(root["audio"] as? [String: Any])

    #expect(audio["language"] as? String == "en-US")
}

@Test
func recoverableLaunchAtLoginFailureDoesNotClobberCredentials() {
    let previous = AppSettings.defaults
    let requested = AppSettings(
        appID: "7696528710",
        resourceID: "volc.seedasr.sauc.duration",
        microphoneID: nil,
        autoInsert: true,
        showDockIcon: true,
        historyRetentionDays: 30,
        launchAtLogin: true,
        hotkey: .optionSpace,
        language: .zhCN
    )

    let reconciled = NoTypeAppModel.reconcilingRecoverableSettingFailures(
        requested: requested,
        previous: previous,
        restoreLaunchAtLogin: true
    )

    #expect(reconciled.appID == requested.appID)
    #expect(reconciled.resourceID == requested.resourceID)
    #expect(reconciled.launchAtLogin == previous.launchAtLogin)
}

@Test
func recoverableHotkeyFailureDoesNotClobberCredentials() {
    let previous = AppSettings.defaults
    let requested = AppSettings(
        appID: "7696528710",
        resourceID: "volc.seedasr.sauc.duration",
        microphoneID: nil,
        autoInsert: true,
        showDockIcon: true,
        historyRetentionDays: 30,
        launchAtLogin: false,
        hotkey: .controlSpace,
        language: .zhCN
    )

    let reconciled = NoTypeAppModel.reconcilingRecoverableSettingFailures(
        requested: requested,
        previous: previous,
        restoreHotkey: true
    )

    #expect(reconciled.appID == requested.appID)
    #expect(reconciled.resourceID == requested.resourceID)
    #expect(reconciled.hotkey == previous.hotkey)
}

@Test
func cancelHotkeyFailureOnlyProducesWarningAndKeepsPrimaryHotkeyUsable() throws {
    let result = try HotkeyService.registrationResult(
        primaryStatus: noErr,
        cancelStatus: -9878,
        hotkey: .optionSpace
    )

    #expect(result.warningMessage?.contains("Option + Esc") == true)
}

@Test
func primaryHotkeyFailureStillThrows() {
    #expect(throws: HotkeyServiceError.self) {
        _ = try HotkeyService.registrationResult(
            primaryStatus: -9878,
            cancelStatus: noErr,
            hotkey: .optionSpace
        )
    }
}

@Test
func permissionRequirementMessageMentionsAccessibilityWhenOnlyAccessibilityMissing() {
    let message = NoTypeAppModel.permissionRequirementMessage(
        for: PermissionSnapshot(
            microphoneAuthorized: true,
            accessibilityAuthorized: false
        ),
        language: .zhCN
    )

    #expect(message == "需要先授予辅助功能权限。打开 Setup 完成授权后再试。")
}

@Test
func permissionRequirementMessageMentionsBothPermissionsInEnglish() {
    let message = NoTypeAppModel.permissionRequirementMessage(
        for: PermissionSnapshot(
            microphoneAuthorized: false,
            accessibilityAuthorized: false
        ),
        language: .enUS
    )

    #expect(
        message == "Microphone and Accessibility permissions are required. Open Setup and grant them before trying again."
    )
}
