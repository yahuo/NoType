import Foundation
import OSLog
import AVFoundation

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
            "Codex 语音转写请求被拒绝（HTTP 403）。请稍后重试；若持续出现，请检查 Codex 登录和网络。"
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
        self.session = session ?? URLSession(configuration: configuration)
        self.authStore = authStore
    }

    nonisolated func checkCredentials() throws {
        _ = try currentCredentials()
    }

    nonisolated func currentCredentials() throws -> CodexOAuthCredentials {
        let credentials = try authStore.loadCredentials()
        guard !credentials.isExpired else { throw AIRewriteError.codexAuthExpired }
        return credentials
    }

    func transcribe(pcm: Data) async throws -> String {
        let id = UUID().uuidString
        let started = ProcessInfo.processInfo.systemUptime
        CodexTranscriptionDiagnostics.record("request_start", id: id,
            fields: "pcm_bytes=\(pcm.count) audio_ms=\(pcm.count * 1000 / 32000)")
        do {
            try Task.checkCancellation()
            let request = try Self.makeRequest(pcm: pcm, credentials: currentCredentials(), compress: true)
            try Task.checkCancellation()
            CodexTranscriptionDiagnostics.record("audio_prepared", id: id,
                fields: "body_bytes=\(request.httpBody?.count ?? 0) elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started))")
            let (data, response) = try await session.data(
                for: request, delegate: CodexTranscriptionTaskDelegate(id: id)
            )
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else {
                throw CodexTranscriptionError.invalidResponse
            }
            CodexTranscriptionDiagnostics.record("http_response", id: id,
                fields: CodexTranscriptionDiagnostics.responseSummary(response, byteCount: data.count))
            guard (200..<300).contains(response.statusCode) else {
                throw CodexTranscriptionError.requestFailed(response.statusCode)
            }
            guard let result = try? JSONDecoder().decode(TranscriptionResponse.self, from: data) else {
                throw CodexTranscriptionError.invalidResponse
            }
            let text = result.text.trimmed
            guard !text.isEmpty else { throw CodexTranscriptionError.noSpeech }
            CodexTranscriptionDiagnostics.record("request_end", id: id,
                fields: "outcome=success elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started)) characters=\(text.count)")
            return text
        } catch {
            CodexTranscriptionDiagnostics.record("request_end", id: id,
                fields: "outcome=\(CodexTranscriptionDiagnostics.failureCategory(error)) elapsed_ms=\(CodexTranscriptionDiagnostics.elapsed(since: started))")
            throw error
        }
    }

    static func makeRequest(
        pcm: Data,
        credentials: CodexOAuthCredentials,
        boundary: String = "----notype-\(UUID().uuidString)",
        compress: Bool = false
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

        var audio = wav
        var format = "wav"
        if compress, let flac = try? compressPCM(pcm), flac.count < wav.count {
            audio = flac
            format = "flac"
        }
        var body = Data(("--\(boundary)\r\n"
            + "Content-Disposition: form-data; name=\"file\"; filename=\"dictation.\(format)\"\r\n"
            + "Content-Type: audio/\(format)\r\n\r\n").utf8)
        body.append(audio)
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

    static func compressPCM(_ pcm: Data) throws -> Data {
        guard !pcm.isEmpty, pcm.count.isMultiple(of: 2), pcm.count <= Int(UInt32.max) - 36 else {
            throw CodexTranscriptionError.invalidAudio
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("notype-\(UUID()).flac")
        defer { try? FileManager.default.removeItem(at: url) }
        func writeFile() throws {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatFLAC,
                AVSampleRateKey: PCMUtilities.sampleRate,
                AVNumberOfChannelsKey: PCMUtilities.channelCount,
                AVEncoderBitDepthHintKey: PCMUtilities.bitsPerSample
            ], commonFormat: .pcmFormatInt16, interleaved: true)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
                  let destination = buffer.mutableAudioBufferList.pointee.mBuffers.mData else {
                throw CodexTranscriptionError.invalidAudio
            }
            buffer.frameLength = buffer.frameCapacity
            pcm.withUnsafeBytes { destination.copyMemory(from: $0.baseAddress!, byteCount: pcm.count) }
            try file.write(from: buffer)
        }
        try writeFile() // Closing the writer finalizes the FLAC header before reading it.
        return try Data(contentsOf: url)
    }
}

enum CodexTranscriptionDiagnostics {
    private static let logger = Logger(subsystem: "com.opensource.notype", category: "CodexDictation")

    static func record(_ event: String, id: String, fields: String) {
        logger.notice("\(event, privacy: .public) operation=\(id, privacy: .public) \(fields, privacy: .public)")
    }

    static func elapsed(since started: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - started) * 1000)
    }

    static func safeIdentifier(_ value: String?) -> String {
        guard let value else { return "none" }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.:")
        guard !value.isEmpty, value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "invalid" }
        return value
    }

    static func responseSummary(_ response: HTTPURLResponse, byteCount: Int) -> String {
        let format: String
        switch response.mimeType?.lowercased() {
        case "application/json": format = "json"
        case "text/html": format = "html"
        default: format = "other"
        }
        let requestID = safeIdentifier(response.value(forHTTPHeaderField: "X-Request-Id"))
        let ray = safeIdentifier(response.value(forHTTPHeaderField: "CF-Ray"))
        let challenge = response.value(forHTTPHeaderField: "CF-Mitigated") == "challenge"
        return "status=\(response.statusCode) response_bytes=\(byteCount) format=\(format) request_id=\(requestID) cf_ray=\(ray) challenge=\(challenge)"
    }

    static func failureCategory(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "cancelled"
        case let error as URLError: return "network_\(error.code.rawValue)"
        case CodexTranscriptionError.requestFailed(let status): return "http_\(status)"
        case CodexTranscriptionError.noSpeech: return "no_speech"
        case CodexTranscriptionError.invalidAudio: return "invalid_audio"
        case CodexTranscriptionError.invalidResponse: return "invalid_response"
        case is AIRewriteError: return "authentication"
        default: return "local_error"
        }
    }
}

final class CodexTranscriptionTaskDelegate: NSObject, URLSessionTaskDelegate {
    private let id: String

    init(id: String) { self.id = id }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        func milliseconds(_ start: Date?, _ end: Date?) -> Int {
            guard let start, let end else { return -1 }
            return Int(end.timeIntervalSince(start) * 1000)
        }
        for transaction in metrics.transactionMetrics {
            let connect = milliseconds(transaction.connectStartDate, transaction.connectEndDate)
            let upload = milliseconds(transaction.requestStartDate, transaction.requestEndDate)
            let wait = milliseconds(transaction.requestEndDate, transaction.responseStartDate)
            let download = milliseconds(transaction.responseStartDate, transaction.responseEndDate)
            CodexTranscriptionDiagnostics.record("network_metrics", id: id,
                fields: "connect_ms=\(connect) upload_ms=\(upload) wait_ms=\(wait) download_ms=\(download) reused=\(transaction.isReusedConnection)")
        }
    }

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
