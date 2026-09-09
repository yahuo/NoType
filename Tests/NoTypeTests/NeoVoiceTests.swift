import Foundation
import Testing
import WebKit
@testable import NoType

@Test func neoWakePhraseRequiresBothWholeWords() {
    for text in ["Hey Neo", "hey, Neo!", "OK Hey Neo 请问一下"] {
        #expect(NativeWakeWordService.matches(text))
    }
    for text in ["Neo", "hey", "Hey neon", "they neo", "hello Neo", "Hey new", "heyneo"] {
        #expect(!NativeWakeWordService.matches(text))
    }
}

@Test func neoEndCommandDoesNotMatchQuotedOrLongerRequests() {
    #expect(CodexRealtimeService.isEndCommand("结束对话。"))
    #expect(CodexRealtimeService.isEndCommand("Goodbye, Neo!"))
    #expect(!CodexRealtimeService.isEndCommand("请翻译结束对话这四个字"))
    #expect(!CodexRealtimeService.isEndCommand("不要结束对话"))
    #expect(!CodexRealtimeService.isEndCommand("不要结束会话"))
    #expect(!CodexRealtimeService.isEndCommand("解释一下结束会话是什么意思"))
}

@Test(arguments: ["结束会话", "结束会话。", "结束 会话！"])
func neoEndSessionCommandIsRecognized(_ text: String) {
    #expect(CodexRealtimeService.isEndCommand(text))
}

@MainActor @Test func neoUsesExistingLoginAndRealtimeModelWithoutCreatingHistory() throws {
    let credentials = CodexOAuthCredentials(accessToken: "unit-test-token", chatGPTAccountID: "unit-test-account", expiresAt: Date.distantFuture)
    let request = try CodexRealtimeService.makeRequest(sdp: "v=0\r\n", credentials: credentials, threadID: "ephemeral-test-thread")
    #expect(request.value(forHTTPHeaderField: "Thread-Id") == "ephemeral-test-thread")
    #expect(request.url?.host == "chatgpt.com")
    #expect(request.url?.path == "/backend-api/wham/realtime/calls")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer unit-test-token")
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let session = try #require(body["session"] as? [String: Any])
    #expect(session["model"] as? String == "gpt-live-1-codex")
    #expect(session["initial_items"] == nil)
    #expect(body["thread"] == nil)
}

@Test func neoWakeOptInSurvivesSaveAndDefaultsOffForExistingInstallations() throws {
    let old = Data("{\"appID\":\"old-app\",\"speechProvider\":\"doubao\"}".utf8)
    let migrated = try JSONDecoder().decode(AppSettings.self, from: old)
    #expect(!migrated.neoWakeEnabled)
    #expect(migrated.speechProvider == .doubao)
    var settings = migrated
    settings.neoWakeEnabled = true
    #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)) == settings)
}

@MainActor @Test(arguments: NeoVoice.allCases)
func neoSelectedVoiceIsSentToRealtimeSession(voice: NeoVoice) throws {
    let credentials = CodexOAuthCredentials(accessToken: "unit-test-token", chatGPTAccountID: nil, expiresAt: Date.distantFuture)
    let request = try CodexRealtimeService.makeRequest(sdp: "v=0\r\n", credentials: credentials, threadID: "voice-test", voice: voice)
    let data = try #require(request.httpBody)
    let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let session = try #require(body["session"] as? [String: Any])
    let audio = try #require(session["audio"] as? [String: Any])
    let output = try #require(audio["output"] as? [String: Any])
    #expect(output["voice"] as? String == voice.rawValue)
}

@Test func neoVoiceMigratesWithoutLosingOtherSettings() throws {
    for json in ["{\"appID\":\"saved\"}", "{\"appID\":\"saved\",\"neoVoice\":\"unknown\"}"] {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.neoVoice == .juniper)
        #expect(settings.appID == "saved")
    }
    for voice in NeoVoice.allCases {
        var settings = AppSettings.defaults
        settings.neoVoice = voice
        let saved = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(AppSettings.self, from: saved).neoVoice == voice)
    }
}

@MainActor @Test func neoVoiceSaveDoesNotPersistOtherSettingsDrafts() throws {
    let suite = "NoTypeTests.neo-voice.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(userDefaults: defaults)
    try store.save(.defaults)
    let model = NoTypeAppModel(settingsStore: store)
    defer { model.neoVoice.shutdown() }
    model.settings.appID = "unsaved-draft"
    model.settings.llmRefinementEnabled = true
    model.setNeoVoice(.cove)
    #expect(store.load().neoVoice == .cove)
    #expect(model.settings.neoVoice == .cove)
    #expect(model.neoVoice.voice == .cove)
    #expect(store.load().appID.isEmpty)
    #expect(!store.load().llmRefinementEnabled)
    #expect(model.settings.appID == "unsaved-draft")
    #expect(model.settings.llmRefinementEnabled)
}

@Test func neoSpeechGuidanceMigratesAndPreservesEditableWhitespace() throws {
    let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{\"appID\":\"saved\"}".utf8))
    #expect(settings.neoSpeechGuidance.isEmpty)
    #expect(settings.appID == "saved")
    for guidance in ["语速慢一些，句间稍作停顿。\n ", "", " \n "] {
        var edited = settings
        edited.neoSpeechGuidance = guidance
        let saved = try JSONEncoder().encode(edited)
        #expect(try JSONDecoder().decode(AppSettings.self, from: saved) == edited)
    }
}

@MainActor @Test(arguments: ["语速慢一些，句间稍作停顿。\n ", "", " \n "])
func neoSpeechGuidanceExtendsExistingSessionInstructions(guidance: String) throws {
    let credentials = CodexOAuthCredentials(accessToken: "unit-test-token", chatGPTAccountID: nil, expiresAt: Date.distantFuture)
    func instructions(_ guidance: String) throws -> String {
        let request = try CodexRealtimeService.makeRequest(sdp: "v=0\r\n", credentials: credentials, threadID: "guidance-test", speechGuidance: guidance)
        let data = try #require(request.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let session = try #require(body["session"] as? [String: Any])
        return try #require(session["instructions"] as? String)
    }
    let baseline = try instructions("")
    #expect(baseline.contains("Immediately delegate every action"))
    #expect(baseline.contains("existing local Codex memories"))
    #expect(baseline.contains("结束会话"))
    let configured = try instructions(guidance)
    if guidance.trimmed.isEmpty {
        #expect(configured == baseline)
    } else {
        #expect(configured.hasPrefix(baseline + "\n\n"))
        #expect(configured.hasSuffix(guidance.trimmed))
    }
}

@MainActor @Test func neoSpeechGuidanceSaveDoesNotPersistOtherSettingsDrafts() throws {
    let suite = "NoTypeTests.neo-guidance.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(userDefaults: defaults)
    var saved = AppSettings.defaults
    saved.neoVoice = .cove
    try store.save(saved)
    let model = NoTypeAppModel(settingsStore: store)
    defer { model.neoVoice.shutdown() }
    model.settings.appID = "unsaved-draft"
    model.settings.llmRefinementEnabled = true
    for guidance in ["语速慢一些。\n ", ""] {
        model.setNeoSpeechGuidance(guidance)
        #expect(store.load().neoSpeechGuidance == guidance)
        #expect(model.settings.neoSpeechGuidance == guidance)
        #expect(model.neoVoice.speechGuidance == guidance)
        #expect(store.load().neoVoice == .cove)
        #expect(store.load().appID.isEmpty)
        #expect(!store.load().llmRefinementEnabled)
        #expect(model.settings.appID == "unsaved-draft")
        #expect(model.settings.llmRefinementEnabled)
    }
}

@MainActor private final class FakeWake: WakeWordListening {
    var wakes: [@MainActor () -> Void] = []
    var starts = 0
    var stops = 0
    var phrases: [String] = []
    func start(phrase: String, onWake: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) async throws {
        starts += 1
        phrases.append(phrase)
        wakes.append(onWake)
    }
    func stop() { stops += 1 }
}

@Test(arguments: [
    ("Hello Nova", "hey hello, NOVA can you help", true),
    ("Hello Nova", "Hey Neo", false),
    ("Neo", "Hey Neo", true),
    ("Neo", "Hey neon", false),
    ("你好小新", "嗯，你好，小新，帮我看看", true),
    ("小新小新", "小新，小新", true),
    ("你好 Neo", "你好，Neo 请帮忙", true),
    ("你好 Neo", "你好 Neon", false),
    ("Hey 小新", "they 小新", false),
    ("...", "anything", false),
])
func neoCustomWakePhraseMatchesCompleteWords(phrase: String, text: String, expected: Bool) {
    #expect(NativeWakeWordService.matches(text, phrase: phrase) == expected)
}

@Test func neoWakePhraseChoosesChineseOrEnglishOfflineRecognition() {
    #expect(NativeWakeWordService.recognitionLocaleIdentifier(for: "Hey Neo") == "en-US")
    #expect(NativeWakeWordService.recognitionLocaleIdentifier(for: "Hello Nova") == "en-US")
    #expect(NativeWakeWordService.recognitionLocaleIdentifier(for: "你好 Neo") == "zh-CN")
}

@Test func neoWakePhraseMigratesAndPersists() throws {
    for json in ["{}", "{\"neoWakePhrase\":\"   \"}", "{\"neoWakePhrase\":\"!!!\"}"] {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        #expect(settings.neoWakePhrase == "Hey Neo")
    }
    var settings = AppSettings.defaults
    settings.neoWakePhrase = "你好小新"
    let saved = try JSONEncoder().encode(settings)
    #expect(try JSONDecoder().decode(AppSettings.self, from: saved).neoWakePhrase == "你好小新")
}

@MainActor @Test func neoWakePhraseSaveDoesNotPersistOtherSettingsDrafts() throws {
    let suite = "NoTypeTests.neo-wake.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = SettingsStore(userDefaults: defaults)
    try store.save(.defaults)
    let model = NoTypeAppModel(settingsStore: store)
    defer { model.neoVoice.shutdown() }
    model.settings.llmRefinementEnabled = true
    model.setNeoWakePhrase("  你好  小新  ")
    #expect(store.load().neoWakePhrase == "你好 小新")
    #expect(model.neoVoice.wakePhrase == "你好 小新")
    #expect(!store.load().llmRefinementEnabled)
    #expect(model.settings.llmRefinementEnabled)
    model.setNeoWakePhrase("...")
    #expect(model.llmSettingsErrorMessage != nil)
    #expect(store.load().neoWakePhrase == "你好 小新")
}

@MainActor @Test func neoWakePhraseChangeRearmsWithoutInterruptingConversation() async throws {
    let wake = FakeWake(), call = FakeCall()
    let neo = NeoVoiceController(wake: wake, call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.setWakeEnabled(true)
    await settle()
    neo.setWakePhrase("Hello Nova")
    await settle()
    #expect(wake.phrases == ["Hey Neo", "Hello Nova"])
    wake.wakes[0]()
    await settle()
    #expect(call.starts == 0)
    wake.wakes[1]()
    await settle()
    call.events[0](.ready)
    let previousStops = call.stops
    neo.setWakePhrase("你好小新")
    #expect(neo.state == .listening)
    #expect(call.stops == previousStops)
    #expect(wake.starts == 2)
    neo.endConversation()
    try await Task.sleep(for: .seconds(1.6))
    await settle()
    #expect(neo.state == .armed)
    #expect(wake.phrases.last == "你好小新")
    #expect(neo.statusText.contains("你好小新"))
}

@MainActor private final class FakeCall: NeoRealtimeCalling {
    var mediaView: WKWebView? { nil }
    var events: [(NeoRealtimeEvent) -> Void] = []
    var starts = 0
    var stops = 0
    var finishes = 0
    var greetings = 0
    var voices: [NeoVoice] = []
    var speechGuidances: [String] = []
    func start(voice: NeoVoice, speechGuidance: String, onEvent: @escaping (NeoRealtimeEvent) -> Void) async throws {
        starts += 1
        voices.append(voice)
        speechGuidances.append(speechGuidance)
        events.append(onEvent)
    }
    func stop() { stops += 1 }
    func finishAfterReply() { finishes += 1 }
    func greet() { greetings += 1 }
}

@MainActor @Test func neoVoiceChangeAppliesToTheNextConversation() async throws {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.setVoice(.maple)
    neo.startConversation()
    neo.setVoice(.cove)
    await settle()
    #expect(call.voices == [.maple])
    call.events[0](.ready)
    let stops = call.stops
    neo.setVoice(.spruce)
    #expect(neo.state == .listening)
    #expect(call.stops == stops)
    #expect(call.starts == 1)
    neo.endConversation()
    neo.startConversation()
    await settle()
    #expect(call.voices == [.maple, .spruce])
}

@MainActor @Test func neoSpeechGuidanceChangeAppliesToTheNextConversation() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.setSpeechGuidance("语速慢一些")
    neo.startConversation()
    neo.setSpeechGuidance("语速快一些")
    await settle()
    #expect(call.speechGuidances == ["语速慢一些"])
    call.events[0](.ready)
    let stops = call.stops
    neo.setSpeechGuidance("句间稍作停顿")
    #expect(neo.state == .listening)
    #expect(call.stops == stops)
    #expect(call.starts == 1)
    neo.endConversation()
    neo.startConversation()
    await settle()
    #expect(call.speechGuidances == ["语速慢一些", "句间稍作停顿"])
    neo.setSpeechGuidance("")
    neo.endConversation()
    neo.startConversation()
    await settle()
    #expect(call.speechGuidances.last == "")
}

@MainActor @Test func neoGreetsOnceWhenTheCallIsReady() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.startConversation()
    await settle()
    #expect(call.greetings == 0)
    call.events[0](.ready)
    call.events[0](.ready)
    #expect(call.greetings == 1)
    neo.endConversation()
    call.events[0](.ready)
    #expect(call.greetings == 1)
}

@MainActor private func settle() async {
    for _ in 0..<12 { await Task.yield() }
}

@MainActor @Test func neoWakeStartsOneCallAndOldCallbacksCannotReviveEndedSession() async {
    let wake = FakeWake(), call = FakeCall()
    let neo = NeoVoiceController(wake: wake, call: call, microphoneAccess: { true })
    neo.setWakeEnabled(true)
    await settle()
    #expect(neo.state == .armed)
    wake.wakes[0]()
    wake.wakes[0]()
    await settle()
    #expect(call.starts == 1)
    #expect(wake.stops > 0)
    call.events[0](.ready)
    #expect(neo.state == .listening)
    neo.setWakeEnabled(false)
    neo.endConversation()
    call.events[0](.ready)
    call.events[0](.level(1, speaking: true))
    wake.wakes[0]()
    #expect(neo.state == .off)
    #expect(neo.level == 0)
    neo.shutdown()
}

@MainActor @Test func neoSuspendsForDictationAndOnlyRearmsWhenReleased() async {
    let wake = FakeWake(), call = FakeCall()
    let neo = NeoVoiceController(wake: wake, call: call, microphoneAccess: { true })
    neo.setWakeEnabled(true)
    await settle()
    neo.setSuspended(true)
    wake.wakes[0]()
    neo.startConversation()
    await settle()
    #expect(call.starts == 0)
    #expect(neo.state == .off)
    neo.setSuspended(false)
    await settle()
    #expect(wake.starts == 2)
    #expect(neo.state == .armed)
    neo.shutdown()
}

@MainActor @Test func neoPlaybackEndHidesHUDAndStopsCallWhileRearming() async throws {
    let wake = FakeWake(), call = FakeCall()
    let neo = NeoVoiceController(wake: wake, call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.setWakeEnabled(true)
    await settle()
    neo.startConversation()
    await settle()
    call.events[0](.ready)
    call.events[0](.level(0.8, speaking: true))
    #expect(neo.state.hudVisible)
    let previousStops = call.stops
    call.events[0](.endRequested)
    #expect(neo.state == .ending)
    #expect(neo.state.hudVisible)
    #expect(call.stops == previousStops)
    call.events[0](.playbackEnded)
    #expect(call.stops == previousStops + 1)
    #expect(neo.state == .arming)
    #expect(!neo.state.hudVisible)
    #expect(neo.level == 0)
    call.events[0](.level(1, speaking: true))
    #expect(!neo.state.hudVisible)
    try await Task.sleep(for: .seconds(1.6))
    await settle()
    #expect(neo.state == .armed)
    #expect(wake.starts == 2)
    #expect(call.starts == 1)
    #expect(!neo.state.hudVisible)
}

@MainActor @Test func neoSpokenEndKeepsHUDAndConnectionWhileReplyIsPlaying() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.startConversation()
    await settle()
    call.events[0](.ready)
    call.events[0](.level(0.8, speaking: true))
    let previousStops = call.stops
    call.events[0](.endRequested)
    #expect(neo.state.hudVisible)
    #expect(call.stops == previousStops)
    #expect(call.finishes == 1)
    call.events[0](.level(0.8, speaking: true))
    call.events[0](.ready)
    call.events[0](.endRequested)
    #expect(neo.state == .ending)
    #expect(call.finishes == 1)
}

@MainActor @Test func neoManualEndRemainsImmediateAndOldPlaybackCannotCloseNewCall() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.startConversation()
    await settle()
    call.events[0](.ready)
    call.events[0](.endRequested)
    neo.endConversation()
    #expect(!neo.state.hudVisible)
    neo.startConversation()
    await settle()
    call.events[1](.ready)
    call.events[0](.playbackEnded)
    call.events[1](.playbackEnded)
    #expect(neo.state == .listening)
}

@MainActor @Test func neoDisconnectDuringFarewellClosesInsteadOfLeavingErrorHUD() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.startConversation()
    await settle()
    call.events[0](.ready)
    call.events[0](.endRequested)
    call.events[0](.failed(NeoVoiceError.connectionLost))
    #expect(neo.state == .off)
    #expect(!neo.state.hudVisible)
}

@MainActor @Test func neoCancellationWhilePermissionIsPendingCannotStartMicrophoneCall() async {
    var permission: CheckedContinuation<Bool, Never>?
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: {
        await withCheckedContinuation { permission = $0 }
    })
    neo.startConversation()
    await settle()
    neo.endConversation()
    permission?.resume(returning: true)
    await settle()
    #expect(call.starts == 0)
    #expect(neo.state == .off)
    neo.shutdown()
}

@MainActor @Test func neoOldCallErrorDoesNotCloseNewCall() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    neo.startConversation()
    await settle()
    neo.endConversation()
    neo.startConversation()
    await settle()
    call.events[1](.ready)
    call.events[0](.failed(NeoVoiceError.connectionLost))
    #expect(neo.state == .listening)
    neo.shutdown()
}

@MainActor @Test func neoWorkingStateSurvivesSilenceAndCanEndByVoice() async {
    let call = FakeCall()
    let neo = NeoVoiceController(wake: FakeWake(), call: call, microphoneAccess: { true })
    defer { neo.shutdown() }
    neo.startConversation()
    await settle()
    call.events[0](.ready)
    call.events[0](.working(true))
    call.events[0](.level(0, speaking: false))
    #expect(neo.state == .working)
    #expect(neo.state.hudVisible)
    call.events[0](.level(0.5, speaking: true))
    #expect(neo.state == .speaking)
    call.events[0](.level(0, speaking: false))
    #expect(neo.state == .working)
    call.events[0](.endRequested)
    call.events[0](.working(false))
    #expect(neo.state == .ending)
    #expect(call.finishes == 1)
    call.events[0](.playbackEnded)
    #expect(neo.state == .off)
}
