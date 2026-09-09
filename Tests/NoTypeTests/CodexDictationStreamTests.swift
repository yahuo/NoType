import Foundation
import Testing
@testable import NoType

@Test
func codexStreamKeepsUtteranceOrderAndReplacesRevisions() throws {
    var transcript = CodexStreamTranscript()
    try transcript.apply(Data(#"{"type":"speech.started","utterance_id":"first"}"#.utf8))
    try transcript.apply(Data(#"{"type":"speech.started","utterance_id":"second"}"#.utf8))
    try transcript.apply(Data(#"{"type":"transcript.final","utterance_id":"second","revision":3,"text":"保留快捷键。"}"#.utf8))
    try transcript.apply(Data(#"{"type":"transcript.segment","utterance_id":"first","revision":2,"text":"改成五秒。"}"#.utf8))
    try transcript.apply(Data(#"{"type":"transcript.delta","utterance_id":"first","revision":1,"text":"旧结果"}"#.utf8))
    #expect(transcript.text == "改成五秒。 保留快捷键。")
    #expect(!transcript.isComplete)
    try transcript.apply(Data(#"{"type":"transcript.final","utterance_id":"first","revision":3,"text":"改成十秒。"}"#.utf8))
    try transcript.apply(Data(#"{"type":"transcript.segment","utterance_id":"first","revision":4,"text":"迟到的结果"}"#.utf8))
    #expect(transcript.text == "改成十秒。 保留快捷键。")
    #expect(transcript.isComplete)
}

@Test
func codexStreamRejectsIncompleteAndFailedSessions() throws {
    var transcript = CodexStreamTranscript()
    #expect(throws: CodexTranscriptionError.noSpeech) {
        try transcript.finalText(sentBytes: 100, expectedBytes: 100)
    }
    try transcript.apply(Data(#"{"type":"transcript.segment","utterance_id":"one","revision":1,"text":"未完成"}"#.utf8))
    #expect(throws: CodexTranscriptionError.invalidResponse) {
        try transcript.finalText(sentBytes: 100, expectedBytes: 100)
    }
    try transcript.apply(Data(#"{"type":"transcript.final","utterance_id":"one","revision":2,"text":"完整"}"#.utf8))
    #expect(throws: CodexTranscriptionError.invalidAudio) {
        try transcript.finalText(sentBytes: 98, expectedBytes: 100)
    }
    #expect(try transcript.finalText(sentBytes: 100, expectedBytes: 100) == "完整")
    #expect(throws: CodexTranscriptionError.invalidResponse) {
        try transcript.apply(Data(#"{"type":"session.error","fatal":true,"error":{"message":"private details"}}"#.utf8))
    }
    #expect(throws: CodexTranscriptionError.invalidResponse) {
        try transcript.apply(Data(#"{"type":"transcript.final","text":"missing utterance"}"#.utf8))
    }
}

@Test
func codexStreamUsesTheInternalEndpointAndExistingLogin() throws {
    let credentials = CodexOAuthCredentials(accessToken: "test-token", chatGPTAccountID: nil, expiresAt: nil)
    let request = CodexDictationStream.makeRequest(credentials: credentials)
    #expect(request.url?.absoluteString == "wss://chatgpt.com/backend-api/dictation/stream")
    #expect(request.value(forHTTPHeaderField: "Origin") == "app://-")
    #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "chatgpt-dictation, openai-bearer.test-token, codex-desktop")
    let start = try #require(JSONSerialization.jsonObject(with: CodexDictationStream.sessionStart) as? [String: Any])
    let config = try #require(start["config"] as? [String: Any])
    #expect(config["sample_rate_hz"] as? Int == 16000)
    #expect(config["input_audio_format"] as? String == "pcm16")
}

// Uses only the synthetic/non-sensitive fixture explicitly selected by the caller.
@Test(.enabled(if: ProcessInfo.processInfo.environment["NOTYPE_CODEX_SMOKE_PCM"] != nil))
func codexDictationStreamLiveSmoke() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["NOTYPE_CODEX_SMOKE_PCM"])
    let pcm = try Data(contentsOf: URL(fileURLWithPath: path))
    let stream = CodexDictationStream(credentials: try CodexTranscriptionService().currentCredentials()) { _ in }
    defer { stream.cancel() }
    let wholeBytes = pcm.count / PCMUtilities.chunkByteCount * PCMUtilities.chunkByteCount
    for offset in stride(from: 0, to: wholeBytes, by: PCMUtilities.chunkByteCount) {
        if case .dropped = stream.audioInput.yield(Data(pcm[offset..<(offset + PCMUtilities.chunkByteCount)])) {
            Issue.record("Live stream queue overflowed")
        }
        try await Task.sleep(for: .milliseconds(PCMUtilities.chunkDurationMilliseconds))
    }
    let stopped = ProcessInfo.processInfo.systemUptime
    let text = try await stream.finish(remainder: Data(pcm[wholeBytes...]), expectedBytes: pcm.count)
    #expect(!text.isEmpty)
    print("Codex live stream stop-to-final (\(ProcessInfo.processInfo.systemUptime - stopped)s): \(text)")
}
