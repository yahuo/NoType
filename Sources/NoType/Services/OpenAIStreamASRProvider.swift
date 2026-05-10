import Foundation

private let openAIRealtimeTranscriptionURL = URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!
private let openAITranscriptionModel = "gpt-4o-mini-transcribe"
private let openAIAudioSampleRate = 24_000

@MainActor
final class OpenAIStreamASRProvider: NSObject, ASRProvider {
    var eventHandler: ((ASRProviderEvent) -> Void)?
    let audioSampleRate = openAIAudioSampleRate

    nonisolated static var serviceURL: URL { openAIRealtimeTranscriptionURL }
    nonisolated static var transcriptionModel: String { openAITranscriptionModel }
    nonisolated static var defaultBaseURL: String { AppSettings.defaults.openAIBaseURL }

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var delegateAdapter: OpenAIWebSocketDelegateAdapter?
    private var hasStarted = false
    private var hasOpened = false
    private var isFinishing = false
    private var latestTranscript = ""
    private var openContinuation: CheckedContinuation<Void, Error>?
    private var setupContinuation: CheckedContinuation<Void, Error>?

    func startSession(config: ASRSessionConfig) async throws {
        guard !config.openAIAPIKey.trimmed.isEmpty else { throw ASRProviderError.notConfigured }

        cancel()
        isFinishing = false
        latestTranscript = ""
        hasOpened = false

        let request = try Self.makeWebSocketRequest(
            apiKey: config.openAIAPIKey,
            baseURL: config.openAIBaseURL,
            userID: config.userID
        )
        let adapter = OpenAIWebSocketDelegateAdapter()
        adapter.onOpen = { [weak self] in
            Task { @MainActor in self?.handleOpen() }
        }
        adapter.onComplete = { [weak self] error, response in
            Task { @MainActor in self?.handleComplete(error: error, response: response) }
        }
        delegateAdapter = adapter

        let session = URLSession(configuration: .default, delegate: adapter, delegateQueue: nil)
        urlSession = session
        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.openContinuation = cont
        }

        receiveLoop()
        try await send(Self.makeSessionUpdateMessage(language: config.language.openAITranscriptionLanguageCode))

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            self.setupContinuation = cont
        }

        hasStarted = true
    }

    func sendAudioFrame(_ data: Data, isFinal: Bool) async throws {
        guard hasStarted else { throw ASRProviderError.sessionNotStarted }

        if !data.isEmpty {
            try await send(Self.makeAudioAppendMessage(data: data))
        }

        if isFinal {
            try await finish()
        }
    }

    func finish() async throws {
        guard hasStarted, !isFinishing else { return }
        isFinishing = true
        try await send(Self.makeCommitMessage())
    }

    func cancel() {
        if let cont = openContinuation {
            openContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        if let cont = setupContinuation {
            setupContinuation = nil
            cont.resume(throwing: CancellationError())
        }
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        delegateAdapter = nil
        hasStarted = false
        hasOpened = false
        isFinishing = false
    }

    private func handleOpen() {
        hasOpened = true
        guard let cont = openContinuation else { return }
        openContinuation = nil
        cont.resume()
    }

    private func handleComplete(error: Error?, response: URLResponse?) {
        let resolved = Self.resolveCompletionError(error: error, response: response, hasOpened: hasOpened)

        if let cont = openContinuation {
            openContinuation = nil
            cont.resume(throwing: resolved ?? ASRProviderError.transport("WebSocket closed before opening"))
            return
        }

        if let cont = setupContinuation {
            setupContinuation = nil
            cont.resume(throwing: resolved ?? ASRProviderError.transport("WebSocket closed before setup ack"))
            return
        }

        guard let resolved else { return }
        emit(.error(resolved.localizedDescription))
    }

    private func send(_ payload: [String: Any]) async throws {
        guard let webSocketTask else { throw ASRProviderError.sessionNotStarted }
        let data = try JSONSerialization.data(withJSONObject: payload)
        guard let string = String(data: data, encoding: .utf8) else { throw ASRProviderError.invalidResponse }
        try await webSocketTask.send(.string(string))
    }

    private func receiveLoop() {
        webSocketTask?.receive { [weak self] result in
            guard let self else { return }
            Task { @MainActor in
                switch result {
                case .success(let message):
                    do {
                        try self.handle(message: message)
                        if self.webSocketTask != nil {
                            self.receiveLoop()
                        }
                    } catch {
                        self.emit(.error(error.localizedDescription))
                        self.cancel()
                    }
                case .failure:
                    return
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let d): data = d
        case .string(let s): data = Data(s.utf8)
        @unknown default: throw ASRProviderError.invalidResponse
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        guard let type = json["type"] as? String else { return }

        switch type {
        case "transcription_session.updated", "session.updated":
            if let cont = setupContinuation {
                setupContinuation = nil
                cont.resume()
            }
        case "conversation.item.input_audio_transcription.delta":
            guard let delta = json["delta"] as? String, !delta.trimmed.isEmpty else { return }
            emit(.partialTranscript(latestTranscript + delta))
        case "conversation.item.input_audio_transcription.completed":
            guard let transcript = json["transcript"] as? String else { return }
            latestTranscript = transcript
            if isFinishing {
                emit(.finalTranscript(latestTranscript))
                cancel()
            } else if !latestTranscript.trimmed.isEmpty {
                emit(.partialTranscript(latestTranscript))
            }
        case "error":
            let message = Self.errorMessage(from: json)
            if isFinishing, !latestTranscript.trimmed.isEmpty {
                emit(.finalTranscript(latestTranscript))
                cancel()
            } else {
                emit(.error(message))
                cancel()
            }
        default:
            return
        }
    }

    private func emit(_ event: ASRProviderEvent) {
        eventHandler?(event)
    }
}

extension OpenAIStreamASRProvider {
    nonisolated static func makeWebSocketRequest(apiKey: String, baseURL: String, userID: String) throws -> URLRequest {
        var request = URLRequest(url: try makeRealtimeWebSocketURL(from: baseURL))
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !userID.trimmed.isEmpty {
            request.setValue(userID, forHTTPHeaderField: "OpenAI-Safety-Identifier")
        }
        return request
    }

    nonisolated static func makeRealtimeWebSocketURL(from baseURL: String) throws -> URL {
        let trimmed = baseURL.trimmed.isEmpty ? defaultBaseURL : baseURL.trimmed
        guard var components = URLComponents(string: trimmed) else {
            throw ASRProviderError.transport("OpenAI API Base URL is invalid.")
        }

        switch components.scheme {
        case "https":
            components.scheme = "wss"
        case "http":
            components.scheme = "ws"
        case "wss", "ws":
            break
        default:
            throw ASRProviderError.transport("OpenAI API Base URL must start with http://, https://, ws://, or wss://.")
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if normalizedPath.isEmpty {
            components.path = "/v1/realtime"
        } else if normalizedPath.hasSuffix("realtime") {
            components.path = "/" + normalizedPath
        } else {
            components.path = "/" + normalizedPath + "/realtime"
        }

        var queryItems = components.queryItems ?? []
        if !queryItems.contains(where: { $0.name == "intent" }) {
            queryItems.append(URLQueryItem(name: "intent", value: "transcription"))
        }
        components.queryItems = queryItems

        guard let url = components.url else {
            throw ASRProviderError.transport("OpenAI API Base URL is invalid.")
        }
        return url
    }

    nonisolated static func makeSessionUpdateMessage(language: String?) -> [String: Any] {
        var transcription: [String: Any] = [
            "model": openAITranscriptionModel,
            "prompt": ""
        ]
        if let language, !language.isEmpty {
            transcription["language"] = language
        }

        return [
            "type": "transcription_session.update",
            "input_audio_format": "pcm16",
            "input_audio_transcription": transcription,
            "turn_detection": NSNull(),
            "input_audio_noise_reduction": [
                "type": "near_field"
            ]
        ]
    }

    nonisolated static func makeAudioAppendMessage(data: Data) -> [String: Any] {
        [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString()
        ]
    }

    nonisolated static func makeCommitMessage() -> [String: Any] {
        ["type": "input_audio_buffer.commit"]
    }

    nonisolated static func resolveCompletionError(error: Error?, response: URLResponse?, hasOpened: Bool) -> Error? {
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            return ASRProviderError.transport("WebSocket handshake failed: HTTP \(http.statusCode)")
        }
        if let error {
            return ASRProviderError.transport(error.localizedDescription)
        }
        return hasOpened ? nil : ASRProviderError.transport("WebSocket closed before opening")
    }

    nonisolated static func testConnection(apiKey: String, baseURL: String, userID: String, language: String?) async throws {
        guard !apiKey.trimmed.isEmpty else { throw ASRProviderError.notConfigured }

        let request = try makeWebSocketRequest(apiKey: apiKey, baseURL: baseURL, userID: userID)
        let adapter = OpenAIWebSocketDelegateAdapter()
        let openSignal = OpenAIAsyncOnceSignal()
        adapter.onOpen = { openSignal.send(.success(())) }
        adapter.onComplete = { error, response in
            let resolved = resolveCompletionError(error: error, response: response, hasOpened: false)
                ?? ASRProviderError.transport("WebSocket closed before opening")
            openSignal.send(.failure(resolved))
        }

        let session = URLSession(configuration: .default, delegate: adapter, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: request)
        task.resume()

        try await openSignal.wait()

        let setupData = try JSONSerialization.data(withJSONObject: makeSessionUpdateMessage(language: language))
        guard let setupString = String(data: setupData, encoding: .utf8) else { throw ASRProviderError.invalidResponse }
        try await task.send(.string(setupString))

        let response = try await task.receive()
        let responseData: Data
        switch response {
        case .data(let d): responseData = d
        case .string(let s): responseData = Data(s.utf8)
        @unknown default: throw ASRProviderError.invalidResponse
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let type = json["type"] as? String,
            type == "transcription_session.updated" || type == "session.updated"
        else {
            throw ASRProviderError.invalidResponse
        }

        task.cancel(with: .goingAway, reason: nil)
    }

    nonisolated static func errorMessage(from json: [String: Any]) -> String {
        if let error = json["error"] as? [String: Any] {
            if let message = error["message"] as? String {
                return message
            }
            if let code = error["code"] as? String {
                return code
            }
        }
        return "OpenAI transcription returned an error."
    }
}

extension DictationLanguage {
    var openAITranscriptionLanguageCode: String? {
        switch self {
        case .zhCN, .zhTW:
            "zh"
        case .enUS:
            "en"
        case .jaJP:
            "ja"
        case .koKR:
            "ko"
        }
    }
}

private final class OpenAIWebSocketDelegateAdapter: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    var onOpen: (@Sendable () -> Void)?
    var onComplete: (@Sendable (Error?, URLResponse?) -> Void)?

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        onOpen?()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onComplete?(error, task.response)
    }
}

private final class OpenAIAsyncOnceSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var pending: Result<Void, Error>?
    private var settled = false

    func wait() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if let pending {
                self.pending = nil
                lock.unlock()
                resume(cont, with: pending)
            } else if settled {
                lock.unlock()
                cont.resume()
            } else {
                continuation = cont
                lock.unlock()
            }
        }
    }

    func send(_ result: Result<Void, Error>) {
        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        settled = true
        if let cont = continuation {
            continuation = nil
            lock.unlock()
            resume(cont, with: result)
        } else {
            pending = result
            lock.unlock()
        }
    }

    private func resume(_ cont: CheckedContinuation<Void, Error>, with result: Result<Void, Error>) {
        switch result {
        case .success: cont.resume()
        case .failure(let error): cont.resume(throwing: error)
        }
    }
}
