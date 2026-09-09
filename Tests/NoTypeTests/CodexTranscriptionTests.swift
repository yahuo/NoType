import Foundation
import Testing
@testable import NoType

@Test
func codexTranscriptionDiagnosticsKeepOnlySafeResponseMetadata() throws {
    let response = try #require(HTTPURLResponse(
        url: URL(string: "https://chatgpt.com/backend-api/transcribe")!,
        statusCode: 403, httpVersion: "HTTP/2", headerFields: [
            "Content-Type": "text/html; charset=utf-8",
            "X-Request-Id": "req-123",
            "CF-Ray": "123abc-SJC",
            "CF-Mitigated": "challenge",
            "Set-Cookie": "secret-cookie",
            "Authorization": "secret-token"
        ]
    ))
    let summary = CodexTranscriptionDiagnostics.responseSummary(response, byteCount: 66021)
    #expect(summary.contains("status=403"))
    #expect(summary.contains("format=html"))
    #expect(summary.contains("request_id=req-123"))
    #expect(summary.contains("challenge=true"))
    #expect(!summary.contains("secret"))
    #expect(CodexTranscriptionDiagnostics.safeIdentifier("id\ninjected=true") == "invalid")
    #expect(CodexTranscriptionDiagnostics.safeIdentifier(String(repeating: "x", count: 200)) == "invalid")
    #expect(CodexTranscriptionError.requestFailed(403).errorDescription?.contains("账号无法") == false)
}

@Test
func codexDictationSkipsRewriteAndPreservesTheDoubaoPreference() throws {
    var settings = AppSettings.defaults
    #expect(settings.speechProvider == .codex)
    settings.llmRefinementEnabled = true
    #expect(!settings.shouldRewriteDictation)
    settings.speechProvider = .doubao
    #expect(settings.shouldRewriteDictation)

    let legacy = try JSONDecoder().decode(AppSettings.self, from: Data(
        #"{"appID":"existing-app","llmRefinementEnabled":true}"#.utf8
    ))
    #expect(legacy.speechProvider == .doubao)
    #expect(legacy.shouldRewriteDictation)

    settings.speechProvider = .codex
    let restored = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
    #expect(restored == settings)
    #expect(!restored.shouldRewriteDictation)
}

@Test
func codexTranscriptionUploadsCompletePCMAsWavUsingOnlyCodexAuth() throws {
    let pcm = Data([0x01, 0x02, 0xFF, 0x7F])
    let credentials = CodexOAuthCredentials(
        accessToken: "test-token", chatGPTAccountID: "test-account", expiresAt: nil
    )
    let request = try CodexTranscriptionService.makeRequest(
        pcm: pcm, credentials: credentials, boundary: "test-boundary"
    )
    #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/transcribe")
    #expect(request.httpMethod == "POST")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
    #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
    #expect(request.value(forHTTPHeaderField: "originator") == "Codex Desktop")
    let body = try #require(request.httpBody)
    let fileStart = try #require(body.range(of: Data("\r\n\r\n".utf8))).upperBound
    let wav = Data(body[fileStart..<(fileStart + 44 + pcm.count)])
    #expect(String(decoding: wav.prefix(4), as: UTF8.self) == "RIFF")
    #expect(Array(wav[4..<8]) == [40, 0, 0, 0])
    #expect(String(decoding: wav[8..<16], as: UTF8.self) == "WAVEfmt ")
    #expect(Array(wav[20..<24]) == [1, 0, 1, 0]) // PCM, mono
    #expect(Array(wav[24..<28]) == [0x80, 0x3E, 0, 0]) // 16 kHz
    #expect(Array(wav[32..<36]) == [2, 0, 16, 0]) // block alignment, bit depth
    #expect(Array(wav[40..<44]) == [4, 0, 0, 0])
    #expect(wav.dropFirst(44) == pcm)
    #expect(body.suffix(Data("\r\n--test-boundary--\r\n".utf8).count)
        == Data("\r\n--test-boundary--\r\n".utf8))
    #expect(!String(decoding: body, as: UTF8.self).contains("name=\"model\""))
}

@Test
func codexTranscriptionRejectsEmptyOrTruncatedAudio() {
    let credentials = CodexOAuthCredentials(accessToken: "test", chatGPTAccountID: nil, expiresAt: nil)
    #expect(throws: CodexTranscriptionError.noSpeech) {
        try CodexTranscriptionService.makeRequest(pcm: Data(), credentials: credentials)
    }
    #expect(throws: CodexTranscriptionError.invalidAudio) {
        try CodexTranscriptionService.makeRequest(pcm: Data([1]), credentials: credentials)
    }
}

private final class TranscriptionProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let scenario = request.value(forHTTPHeaderField: "X-NoType-Test") ?? "success"
        if scenario == "waiting" { return }
        let status = Int(scenario) ?? 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!, cacheStoragePolicy: .notAllowed)
        let body: String
        switch scenario {
        case "empty": body = #"{"text":"  "}"#
        case "invalid": body = #"{"other":"value"}"#
        default: body = #"{"text":"  嗯，五秒，不对，十秒。\n不要修改翻译。  "}"#
        }
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func withTranscriptionService(
    scenario: String = "success",
    _ body: (CodexTranscriptionService) async throws -> Void
) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try Data(#"{"tokens":{"access_token":"test-only-token"}}"#.utf8)
        .write(to: directory.appendingPathComponent("auth.json"))
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [TranscriptionProtocol.self]
    configuration.httpAdditionalHeaders = ["X-NoType-Test": scenario]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    try await body(CodexTranscriptionService(session: session, authStore: CodexAuthStore(codexHome: directory)))
}

@Test
func codexTranscriptionPreservesTextWithoutRewritingIt() async throws {
    try await withTranscriptionService { service in
        let text = try await service.transcribe(pcm: Data([0, 0]))
        #expect(text == "嗯，五秒，不对，十秒。\n不要修改翻译。")
    }
}

@Test(arguments: ["401", "403", "429", "500", "302", "empty", "invalid"])
func codexTranscriptionRejectsFailedOrEmptyResponses(scenario: String) async throws {
    try await withTranscriptionService(scenario: scenario) { service in
        do {
            _ = try await service.transcribe(pcm: Data([0, 0]))
            Issue.record("Expected transcription to fail")
        } catch let error as CodexTranscriptionError {
            if scenario == "empty" {
                #expect(error == .noSpeech)
            } else if scenario == "invalid" {
                #expect(error == .invalidResponse)
            } else {
                #expect(error == .requestFailed(Int(scenario)!))
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func codexTranscriptionCanCancelAnInFlightRequest() async throws {
    try await withTranscriptionService(scenario: "waiting") { service in
        let task = Task { try await service.transcribe(pcm: Data([0, 0])) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Cancelled transcription unexpectedly completed")
        } catch is CancellationError {
        } catch let error as URLError {
            #expect(error.code == .cancelled)
        }
    }
}

@Test
func codexTranscriptionRejectsMissingAndExpiredLoginBeforeUploading() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = CodexTranscriptionService(authStore: CodexAuthStore(codexHome: directory))
    do {
        try service.checkCredentials()
        Issue.record("Missing Codex auth was accepted")
    } catch AIRewriteError.missingCodexAuth {
    }

    let payload = Data(#"{"exp":1}"#.utf8).base64EncodedString()
    let expired = #"{"tokens":{"access_token":"header.\#(payload).signature"}}"#
    try Data(expired.utf8).write(to: directory.appendingPathComponent("auth.json"))
    do {
        _ = try await service.transcribe(pcm: Data([0, 0]))
        Issue.record("Expired Codex auth was accepted")
    } catch AIRewriteError.codexAuthExpired {
    }
}

// Opt-in only: uploads the specified 16 kHz mono PCM16 file to the real Codex
// endpoint. Use a synthetic/non-sensitive fixture; prints the returned text.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOTYPE_CODEX_SMOKE_PCM"] != nil))
func codexTranscriptionLiveSmoke() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NOTYPE_CODEX_SMOKE_PCM"])
    let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
    let started = Date()
    let text = try await CodexTranscriptionService().transcribe(pcm: pcm)
    #expect(!text.isEmpty)
    print("Codex live transcription (\(Date().timeIntervalSince(started))s): \(text)")
}
