import Foundation

enum CodexTranscriptionError: LocalizedError, Equatable {
    case noSpeech
    case invalidAudio
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .noSpeech:
            "没有检测到有效语音。"
        case .invalidAudio:
            "录音数据不完整，无法转写。"
        case .invalidResponse:
            "Codex 语音转写返回了无效结果。"
        case .requestFailed(401):
            "Codex 登录已失效。请打开 Codex 刷新登录后重试。"
        case .requestFailed(403):
            "当前 Codex 账号无法使用语音转写。请先确认 Codex 中的听写可用。"
        case .requestFailed(429):
            "Codex 语音转写已限流，请稍后重试。"
        case .requestFailed(let status):
            "Codex 语音转写失败（HTTP \(status)）。"
        }
    }
}

actor CodexTranscriptionService {
    private struct TranscriptionResponse: Decodable {
        let text: String
    }

    private let session: URLSession
    private let authStore: CodexAuthStore

    init(session: URLSession? = nil, authStore: CodexAuthStore = CodexAuthStore()) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(
            configuration: configuration,
            delegate: CodexTranscriptionRedirectDelegate(),
            delegateQueue: nil
        )
        self.authStore = authStore
    }

    nonisolated func checkCredentials() throws {
        _ = try currentCredentials()
    }

    private nonisolated func currentCredentials() throws -> CodexOAuthCredentials {
        let credentials = try authStore.loadCredentials()
        guard !credentials.isExpired else { throw AIRewriteError.codexAuthExpired }
        return credentials
    }

    func transcribe(pcm: Data) async throws -> String {
        try Task.checkCancellation()
        let request = try Self.makeRequest(pcm: pcm, credentials: currentCredentials())
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let response = response as? HTTPURLResponse else {
            throw CodexTranscriptionError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CodexTranscriptionError.requestFailed(response.statusCode)
        }
        guard let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
            throw CodexTranscriptionError.invalidResponse
        }
        let text = result.text.trimmed
        guard !text.isEmpty else { throw CodexTranscriptionError.noSpeech }
        return text
    }

    static func makeRequest(
        pcm: Data,
        credentials: CodexOAuthCredentials,
        boundary: String = "----notype-\(UUID().uuidString)"
    ) throws -> URLRequest {
        guard !pcm.isEmpty else { throw CodexTranscriptionError.noSpeech }
        guard pcm.count.isMultiple(of: 2), pcm.count <= Int(UInt32.max) - 36 else {
            throw CodexTranscriptionError.invalidAudio
        }

        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + pcm.count))
        wav.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1)) // Linear PCM
        append(UInt16(PCMUtilities.channelCount))
        append(UInt32(PCMUtilities.sampleRate))
        let blockAlignment = PCMUtilities.channelCount * PCMUtilities.bitsPerSample / 8
        append(UInt32(PCMUtilities.sampleRate * blockAlignment))
        append(UInt16(blockAlignment))
        append(UInt16(PCMUtilities.bitsPerSample))
        wav.append(Data("data".utf8))
        append(UInt32(pcm.count))
        wav.append(pcm)

        var body = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.wav\"\r\n"
            + "Content-Type: audio/wav\r\n\r\n").utf8)
        body.append(wav)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/transcribe")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("NoType/0.1", forHTTPHeaderField: "User-Agent")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = body
        return request
    }
}

private final class CodexTranscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
