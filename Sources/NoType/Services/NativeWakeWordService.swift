@preconcurrency import AVFoundation
@preconcurrency import Speech
import Foundation

enum NeoVoiceError: LocalizedError {
    case microphonePermission, speechPermission, offlineRecognitionUnavailable
    case connectionFailed(Int), connectionLost, timedOut, invalidResponse

    var errorDescription: String? {
        switch self {
        case .microphonePermission: "请在系统设置中允许 NoType 使用麦克风。"
        case .speechPermission: "请在系统设置的「隐私与安全性 → 语音识别」中允许 NoType。"
        case .offlineRecognitionUnavailable: "唤醒词对应的离线识别暂不可用。请在系统设置中启用中文或英文听写并下载对应语言，再重试。"
        case .connectionFailed(let status): "Neo 连接失败（HTTP \(status)）。请检查 Codex 登录、语音额度和网络。"
        case .connectionLost: "Neo 语音连接已断开，请重试。"
        case .timedOut: "Neo 连接超时，请检查网络后重试。"
        case .invalidResponse: "Neo 收到了无法处理的语音响应，请重试。"
        }
    }
}

@MainActor
protocol WakeWordListening: AnyObject {
    func start(phrase: String, onWake: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) async throws
    func stop()
}

/// Uses only Apple's local recognizer. Unsupported devices never fall back to cloud recognition.
@MainActor
final class NativeWakeWordService: WakeWordListening {
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var renewal: Task<Void, Never>?
    private var generation = UUID()
    private var consecutiveFailures = 0
    private var phrase = AppSettings.defaultNeoWakePhrase

    nonisolated static func recognitionLocaleIdentifier(for phrase: String) -> String {
        phrase.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) } ? "zh-CN" : "en-US"
    }

    nonisolated static func matches(_ text: String, phrase: String = AppSettings.defaultNeoWakePhrase) -> Bool {
        guard let phrase = AppSettings.normalizedNeoWakePhrase(phrase) else { return false }
        if recognitionLocaleIdentifier(for: phrase) == "zh-CN" {
            let target = phrase.lowercased().filter { $0.isLetter || $0.isNumber }
            let input = text.lowercased().filter { $0.isLetter || $0.isNumber }
            let prefix = target.first?.asciiValue != nil ? "(?<![a-z0-9])" : ""
            let suffix = target.last?.asciiValue != nil ? "(?![a-z0-9])" : ""
            let pattern = prefix + NSRegularExpression.escapedPattern(for: target) + suffix
            return input.range(of: pattern, options: .regularExpression) != nil
        }
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        let target = phrase.lowercased().split { !$0.isLetter && !$0.isNumber }
        guard !target.isEmpty, words.count >= target.count else { return false }
        return (0...(words.count - target.count)).contains { words[$0..<($0 + target.count)].elementsEqual(target) }
    }

    func start(phrase: String, onWake: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) async throws {
        stop()
        self.phrase = AppSettings.normalizedNeoWakePhrase(phrase) ?? AppSettings.defaultNeoWakePhrase
        consecutiveFailures = 0
        let id = generation
        let authorization = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in continuation.resume(returning: status) }
        }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        guard authorization == .authorized else { throw NeoVoiceError.speechPermission }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw NeoVoiceError.microphonePermission }
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
        try listen(id: id, onWake: onWake, onFailure: onFailure)
    }

    private func listen(id: UUID, onWake: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) throws {
        let phrase = self.phrase
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: Self.recognitionLocaleIdentifier(for: phrase))),
              recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
            throw NeoVoiceError.offlineRecognitionUnavailable
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.contextualStrings = [phrase]
        request.taskHint = .search
        self.request = request

        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            stop()
            throw NeoVoiceError.microphonePermission
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { @Sendable buffer, _ in
            request.append(buffer)
        }
        recognition = recognizer.recognitionTask(with: request) { @Sendable [weak self] result, error in
            let detected = result.map { Self.matches($0.bestTranscription.formattedString, phrase: phrase) } ?? false
            let finished = result?.isFinal == true || error != nil
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                if detected {
                    self.stop()
                    onWake()
                } else if finished {
                    if let error {
                        let nativeError = error as NSError
                        // An empty, quiet recognition window is normal while waiting for a wake word.
                        if nativeError.domain != "kAFAssistantErrorDomain" || nativeError.code != 1110 {
                            self.consecutiveFailures += 1
                            if self.consecutiveFailures >= 3 {
                                self.stop()
                                onFailure(error)
                                return
                            }
                        }
                    } else {
                        self.consecutiveFailures = 0
                    }
                    self.scheduleRenewal(after: 1, id: id, onWake: onWake, onFailure: onFailure)
                }
            }
        }
        do {
            engine.prepare()
            try engine.start()
            scheduleRenewal(after: 50, id: id, onWake: onWake, onFailure: onFailure)
        } catch {
            stop()
            throw error
        }
    }

    private func scheduleRenewal(after seconds: Double, id: UUID, onWake: @escaping @MainActor () -> Void, onFailure: @escaping @MainActor (Error) -> Void) {
        renewal?.cancel()
        renewal = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard let self, self.generation == id else { return }
            self.stop()
            do { try self.listen(id: self.generation, onWake: onWake, onFailure: onFailure) }
            catch { onFailure(error) }
        }
    }

    func stop() {
        generation = UUID()
        renewal?.cancel()
        renewal = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        request?.endAudio()
        recognition?.cancel()
        recognition = nil
        request = nil
    }
}
