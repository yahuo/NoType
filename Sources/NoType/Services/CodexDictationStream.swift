import Foundation

struct CodexStreamTranscript: Sendable {
    struct Event: Decodable, Sendable {
        struct Session: Decodable, Sendable { let status: String? }
        let type: String
        let utterance_id: String?
        let revision: Int?
        let text: String?
        let fatal: Bool?
        let session: Session?
    }

    private struct Utterance: Sendable {
        var revision = -1
        var text = ""
        var isFinal = false
    }

    private var order: [String] = []
    private var utterances: [String: Utterance] = [:]
    var text: String { order.compactMap { utterances[$0]?.text.trimmed }.filter { !$0.isEmpty }.joined(separator: " ") }
    var isComplete: Bool { !order.isEmpty && utterances.values.allSatisfy(\.isFinal) }

    @discardableResult
    mutating func apply(_ data: Data) throws -> Event {
        guard let event = try? JSONDecoder().decode(Event.self, from: data) else {
            throw CodexTranscriptionError.invalidResponse
        }
        if event.type == "transcript.failed" || (event.type == "session.error" && event.fatal == true) {
            throw CodexTranscriptionError.invalidResponse
        }
        switch event.type {
        case "speech.started", "speech.stopped", "transcript.delta", "transcript.segment", "transcript.final":
            guard let id = event.utterance_id else { throw CodexTranscriptionError.invalidResponse }
            if utterances[id] == nil {
                order.append(id)
                utterances[id] = Utterance()
            }
            if event.type.hasPrefix("transcript.") {
                guard let revision = event.revision, let text = event.text else {
                    throw CodexTranscriptionError.invalidResponse
                }
                if var current = utterances[id], !current.isFinal, revision >= current.revision {
                    current.revision = revision
                    current.text = text
                    current.isFinal = event.type == "transcript.final"
                    utterances[id] = current
                }
            }
        default: break
        }
        return event
    }

    func finalText(sentBytes: Int, expectedBytes: Int) throws -> String {
        guard sentBytes == expectedBytes else { throw CodexTranscriptionError.invalidAudio }
        guard !text.isEmpty else { throw CodexTranscriptionError.noSpeech }
        guard isComplete else { throw CodexTranscriptionError.invalidResponse }
        return text
    }
}

// One ordered audio queue is fed directly by the capture callback. The complete
// PCM file remains available to the caller if this optional stream fails.
struct CodexDictationStream: Sendable {
    private enum Part: Sendable {
        case sentBytes(Int)
        case transcript(CodexStreamTranscript)
    }

    let audioInput: AsyncThrowingStream<Data, Error>.Continuation
    private let socket: URLSessionWebSocketTask
    private let operation: Task<(CodexStreamTranscript, Int), Error>
    let id: String

    init(credentials: CodexOAuthCredentials, onPartial: @escaping @Sendable (String) -> Void) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 330
        let id = UUID().uuidString
        let session = URLSession(configuration: configuration, delegate: CodexTranscriptionTaskDelegate(id: id), delegateQueue: nil)
        let socket = session.webSocketTask(with: Self.makeRequest(credentials: credentials))
        let (audio, input) = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        self.id = id
        self.socket = socket
        self.audioInput = input
        socket.resume()
        operation = Task {
            defer {
                input.finish()
                socket.cancel(with: .normalClosure, reason: nil)
                session.invalidateAndCancel()
            }
            let started = ProcessInfo.processInfo.systemUptime
            CodexTranscriptionDiagnostics.record("stream_start", id: id, fields: "")
            do {
                return try await Self.run(socket: socket, audio: audio, id: id, started: started, onPartial: onPartial)
            } catch {
                if let response = socket.response as? HTTPURLResponse {
                    CodexTranscriptionDiagnostics.record("stream_response", id: id,
                        fields: CodexTranscriptionDiagnostics.responseSummary(response, byteCount: 0))
                }
                CodexTranscriptionDiagnostics.record("stream_failed", id: id,
                    fields: "outcome=\(CodexTranscriptionDiagnostics.failureCategory(error)) elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started))")
                throw error
            }
        }
    }

    func finish(remainder: Data?, expectedBytes: Int) async throws -> String {
        let started = ProcessInfo.processInfo.systemUptime
        CodexTranscriptionDiagnostics.record("stream_finish", id: id, fields: "pcm_bytes=\(expectedBytes)")
        if let remainder, !remainder.isEmpty,
           case .dropped = audioInput.yield(remainder) {
            audioInput.finish(throwing: CodexTranscriptionError.invalidAudio)
        }
        audioInput.finish()
        let deadline = Task {
            try await Task.sleep(for: .seconds(8))
            cancel()
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            let (transcript, sentBytes) = try await operation.value
            try Task.checkCancellation()
            let text = try transcript.finalText(sentBytes: sentBytes, expectedBytes: expectedBytes)
            CodexTranscriptionDiagnostics.record("stream_complete", id: id,
                fields: "stop_to_final_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started)) characters=\(text.count)")
            return text
        } onCancel: {
            cancel()
        }
    }

    func cancel() {
        audioInput.finish(throwing: CancellationError())
        operation.cancel()
        socket.cancel(with: .goingAway, reason: nil)
    }

    private static func run(
        socket: URLSessionWebSocketTask, audio: AsyncThrowingStream<Data, Error>,
        id: String, started: TimeInterval, onPartial: @escaping @Sendable (String) -> Void
    ) async throws -> (CodexStreamTranscript, Int) {
        let startupDeadline = Task {
            try await Task.sleep(for: .seconds(10))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { startupDeadline.cancel() }
        try await socket.send(.string(String(decoding: sessionStart, as: UTF8.self)))
        var initial = CodexStreamTranscript()
        while try initial.apply(await receive(socket)).type != "session.started" {
            try Task.checkCancellation()
        }
        startupDeadline.cancel()
        CodexTranscriptionDiagnostics.record("stream_ready", id: id,
            fields: "elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started))")

        return try await withThrowingTaskGroup(of: Part.self) { group in
            defer {
                group.cancelAll()
                socket.cancel(with: .normalClosure, reason: nil)
            }
            group.addTask {
                var sentBytes = 0
                for try await frame in audio {
                    try Task.checkCancellation()
                    let data = try JSONSerialization.data(withJSONObject: ["type": "audio.append", "audio": frame.base64EncodedString()])
                    try await socket.send(.string(String(decoding: data, as: UTF8.self)))
                    sentBytes += frame.count
                }
                try Task.checkCancellation()
                CodexTranscriptionDiagnostics.record("stream_audio_sent", id: id,
                    fields: "pcm_bytes=\(sentBytes) elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started))")
                try await socket.send(.string(#"{"type":"session.close"}"#))
                return .sentBytes(sentBytes)
            }
            group.addTask {
                var transcript = CodexStreamTranscript()
                while true {
                    let previous = transcript.text
                    let event = try transcript.apply(await receive(socket))
                    if transcript.text != previous { onPartial(transcript.text) }
                    if event.type == "session.updated", event.session?.status == "closed" {
                        return .transcript(transcript)
                    }
                }
            }
            var sentBytes = 0
            var transcript = CodexStreamTranscript()
            for try await part in group {
                switch part {
                case .sentBytes(let count): sentBytes = count
                case .transcript(let result): transcript = result
                }
            }
            return (transcript, sentBytes)
        }
    }

    private static func receive(_ socket: URLSessionWebSocketTask) async throws -> Data {
        switch try await socket.receive() {
        case .data(let data): return data
        case .string(let text): return Data(text.utf8)
        @unknown default: throw CodexTranscriptionError.invalidResponse
        }
    }

    static func makeRequest(credentials: CodexOAuthCredentials) -> URLRequest {
        var request = URLRequest(url: URL(string: "wss://chatgpt.com/backend-api/dictation/stream")!)
        request.timeoutInterval = 12
        request.setValue("app://-", forHTTPHeaderField: "Origin")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/142.0.0.0 Safari/537.36 NoType/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("chatgpt-dictation, openai-bearer.\(credentials.accessToken), codex-desktop", forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    static let sessionStart = Data(#"{"type":"session.start","config":{"input_audio_format":"pcm16","sample_rate_hz":16000,"num_channels":1,"max_buffer_size_bytes":4194304,"max_utterance_duration_ms":30000,"session_ttl_ms":300000,"provider_mode":"streaming_sse","transcript_delivery_mode":"delta","vad":{"type":"server_vad","threshold":0.5,"prefix_padding_ms":300,"silence_duration_ms":500}}}"#.utf8)
}
