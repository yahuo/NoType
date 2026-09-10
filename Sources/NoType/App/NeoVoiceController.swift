import AVFoundation
import Foundation
import WebKit
import OSLog

enum NeoVoiceState: Equatable {
    case off, arming, armed, connecting, listening, speaking, working, ending
    case unavailable(String), failed(String)

    var inConversation: Bool {
        switch self {
        case .connecting, .listening, .speaking, .working, .ending: true
        default: false
        }
    }
    var hudVisible: Bool {
        if case .failed = self { return true }
        return inConversation
    }
    var message: String? {
        switch self {
        case .failed(let message), .unavailable(let message): message
        default: nil
        }
    }
    var label: String {
        switch self {
        case .off: "唤醒已关闭"
        case .arming: "正在准备唤醒…"
        case .armed: "唤醒已就绪"
        case .connecting: "连接 Neo…"
        case .listening: "Neo 在听"
        case .speaking: "Neo 正在回答"
        case .working: "Neo 正在处理"
        case .ending: "Neo 正在告别"
        case .unavailable: "语音唤醒暂不可用"
        case .failed: "Neo 连接失败"
        }
    }
}

@MainActor
final class NeoVoiceController {
    private static let logger = Logger(subsystem: "com.opensource.notype", category: "NeoVoice")
    private(set) var state: NeoVoiceState = .off {
        didSet {
            let turnStates: [NeoVoiceState] = [.listening, .speaking]
            if state != oldValue, !(turnStates.contains(state) && turnStates.contains(oldValue)) {
                Self.logger.notice("state=\(self.state.label, privacy: .public)")
            }
            onChange?()
        }
    }
    private(set) var level = 0.0 { didSet { onChange?() } }
    var onChange: (() -> Void)?
    var mediaView: WKWebView? { call.mediaView }
    private(set) var wakePhrase = AppSettings.defaultNeoWakePhrase
    private(set) var voice: NeoVoice = .juniper
    private(set) var speechGuidance = ""
    private(set) var executionModel: NeoExecutionModel = .luna
    private(set) var reasoningEffort: NeoReasoningEffort = .medium
    var statusText: String {
        state == .armed ? "说「\(wakePhrase)」开始对话" : state.label
    }
    private let wake: WakeWordListening
    private let call: NeoRealtimeCalling
    private let microphoneAccess: () async -> Bool
    private var wakeEnabled = false
    private var suspended = false
    private var generation = UUID()
    private var operation: Task<Void, Never>?
    private var deadline: Task<Void, Never>?
    private var idle: Task<Void, Never>?
    private var lastActivity = ProcessInfo.processInfo.systemUptime
    private var agentWorking = false
    private var retryStartup: (() -> Void)?

    init(
        wake: WakeWordListening = NativeWakeWordService(),
        call: NeoRealtimeCalling = CodexRealtimeService(),
        microphoneAccess: @escaping () async -> Bool = { await AVCaptureDevice.requestAccess(for: .audio) }
    ) {
        self.wake = wake
        self.call = call
        self.microphoneAccess = microphoneAccess
    }

    func setWakeEnabled(_ enabled: Bool) {
        wakeEnabled = enabled
        guard !state.inConversation else { return }
        reset()
        arm()
    }

    func setWakePhrase(_ phrase: String) {
        guard let phrase = AppSettings.normalizedNeoWakePhrase(phrase), phrase != wakePhrase else { return }
        wakePhrase = phrase
        guard !state.inConversation else { return }
        reset()
        arm()
    }

    func setVoice(_ voice: NeoVoice) {
        self.voice = voice
    }

    func setSpeechGuidance(_ guidance: String) {
        speechGuidance = guidance
    }

    func setExecution(model: NeoExecutionModel, reasoningEffort: NeoReasoningEffort) {
        executionModel = model
        self.reasoningEffort = reasoningEffort
    }

    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value
        reset()
        arm()
    }

    func startConversation() {
        guard !suspended, !state.inConversation else { return }
        connect(voice: voice, speechGuidance: speechGuidance, model: executionModel, effort: reasoningEffort, retryAllowed: true)
    }

    private func connect(voice selectedVoice: NeoVoice, speechGuidance selectedSpeechGuidance: String,
                         model selectedExecutionModel: NeoExecutionModel, effort selectedReasoningEffort: NeoReasoningEffort,
                         retryAllowed: Bool) {
        reset()
        let id = generation
        if retryAllowed {
            retryStartup = { [weak self] in
                self?.connect(voice: selectedVoice, speechGuidance: selectedSpeechGuidance,
                              model: selectedExecutionModel, effort: selectedReasoningEffort, retryAllowed: false)
            }
        }
        state = .connecting
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                guard await self.microphoneAccess() else { throw NeoVoiceError.microphonePermission }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                self.deadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    guard let self, self.generation == id, self.state == .connecting else { return }
                    self.fail(NeoVoiceError.timedOut)
                }
                try await self.call.start(
                    voice: selectedVoice, speechGuidance: selectedSpeechGuidance,
                    executionModel: selectedExecutionModel, reasoningEffort: selectedReasoningEffort
                ) { [weak self] event in
                    guard let self, self.generation == id else { return }
                    self.receive(event, id: id)
                }
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.handleCallFailure(error)
            }
        }
    }

    func endConversation() {
        reset()
        arm(delay: 1.5)
    }

    func shutdown() {
        suspended = true
        reset()
    }

    private func arm(delay: Double = 0) {
        guard wakeEnabled, !suspended else { return }
        let id = generation
        state = .arming
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                guard self.generation == id else { return }
                try await self.wake.start(phrase: self.wakePhrase, onWake: { [weak self] in
                    guard let self, self.generation == id else { return }
                    self.startConversation()
                }, onFailure: { [weak self] error in
                    guard let self, self.generation == id else { return }
                    self.reset()
                    self.state = .unavailable(error.localizedDescription)
                })
                guard self.generation == id, !Task.isCancelled else { return }
                self.state = .armed
            } catch {
                guard self.generation == id, !Task.isCancelled else { return }
                self.reset()
                self.state = .unavailable(error.localizedDescription)
            }
        }
    }

    private func receive(_ event: NeoRealtimeEvent, id: UUID) {
        switch event {
        case .mediaViewReady: onChange?()
        case .ready:
            guard state == .connecting else { return }
            retryStartup = nil
            deadline?.cancel()
            state = .listening
            call.greet()
            lastActivity = ProcessInfo.processInfo.systemUptime
            idle?.cancel()
            idle = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard let self, self.generation == id else { return }
                    if !self.agentWorking, ProcessInfo.processInfo.systemUptime - self.lastActivity >= 45 {
                        self.endConversation()
                        return
                    }
                }
            }
        case .level(let value, let speaking):
            guard state == .listening || state == .speaking || state == .working || state == .ending else { return }
            level = value.isFinite ? min(1, max(0, value)) : 0
            guard state != .ending else { return }
            if value > 0.04 { lastActivity = ProcessInfo.processInfo.systemUptime }
            let next: NeoVoiceState = speaking ? .speaking : (agentWorking ? .working : .listening)
            if state != next { state = next }
        case .working(let working):
            // Never restart once the backend may have acted on a spoken request.
            if working { retryStartup = nil }
            guard state != .ending else { return }
            agentWorking = working
            lastActivity = ProcessInfo.processInfo.systemUptime
            if state == .listening || state == .working { state = working ? .working : .listening }
        case .endRequested:
            guard state == .listening || state == .speaking || state == .working else { return }
            idle?.cancel()
            state = .ending
            call.finishAfterReply()
        case .playbackEnded:
            if state == .ending { endConversation() }
        case .failed(let error):
            if state == .ending { endConversation() } else { handleCallFailure(error) }
        }
    }

    private func handleCallFailure(_ error: Error) {
        if state == .connecting, let voiceError = error as? NeoVoiceError,
           case .connectionLost = voiceError, let retry = retryStartup {
            retryStartup = nil
            Self.logger.notice("startup_retry attempt=2 reason=connection_lost")
            retry()
        } else { fail(error) }
    }

    private func fail(_ error: Error) {
        reset()
        state = .failed(error.localizedDescription)
    }

    private func reset() {
        generation = UUID()
        operation?.cancel()
        deadline?.cancel()
        idle?.cancel()
        operation = nil
        deadline = nil
        idle = nil
        retryStartup = nil
        wake.stop()
        call.stop()
        agentWorking = false
        level = 0
        state = .off
    }
}
