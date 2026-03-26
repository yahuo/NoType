import Foundation

private let doubaoASRServiceURL = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_async")!

@MainActor
final class DoubaoStreamingASRProvider: NSObject, ASRProvider {
    var eventHandler: ((ASRProviderEvent) -> Void)?

    nonisolated static var serviceURL: URL { doubaoASRServiceURL }

    private var urlSession: URLSession?
    private var webSocketTask: URLSessionWebSocketTask?
    private var config: ASRSessionConfig?
    private var hasStarted = false
    private var hasSentFinalAudio = false
    private var isAwaitingFinalResponse = false
    private var didEmitFinal = false
    private var didReceiveResponseAfterFinalAudio = false
    private var latestTranscript = ""
    private var sessionRequestID = UUID().uuidString.lowercased()

    func startSession(config: ASRSessionConfig) async throws {
        guard !config.appID.trimmed.isEmpty, !config.accessToken.trimmed.isEmpty, !config.resourceID.trimmed.isEmpty else {
            throw ASRProviderError.notConfigured
        }

        cancel()

        self.config = config
        sessionRequestID = UUID().uuidString.lowercased()
        latestTranscript = ""
        hasSentFinalAudio = false
        isAwaitingFinalResponse = false
        didEmitFinal = false
        didReceiveResponseAfterFinalAudio = false

        let session = URLSession(configuration: .default, delegate: nil, delegateQueue: nil)
        urlSession = session

        let request = Self.makeWebSocketRequest(
            for: config,
            connectID: sessionRequestID,
            userAgent: "NoType/0.1"
        )

        let task = session.webSocketTask(with: request)
        webSocketTask = task
        task.resume()

        try await send(message: .data(Self.makeFullClientRequest(for: config, requestID: sessionRequestID)))
        hasStarted = true
        receiveLoop()
    }

    func sendAudioFrame(_ data: Data, isFinal: Bool = false) async throws {
        guard hasStarted else {
            throw ASRProviderError.sessionNotStarted
        }

        if isFinal {
            hasSentFinalAudio = true
            isAwaitingFinalResponse = true
        }

        let payload = Self.makeAudioRequest(audioData: data, isFinal: isFinal)
        try await send(message: .data(payload))
    }

    func finish() async throws {
        guard hasStarted else { return }
        guard !hasSentFinalAudio else { return }
        try await sendAudioFrame(Data(), isFinal: true)
    }

    func cancel() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        urlSession?.invalidateAndCancel()
        urlSession = nil
        hasStarted = false
        hasSentFinalAudio = false
        isAwaitingFinalResponse = false
        didReceiveResponseAfterFinalAudio = false
    }

    private func send(message: URLSessionWebSocketTask.Message) async throws {
        guard let webSocketTask else {
            throw ASRProviderError.sessionNotStarted
        }
        try await webSocketTask.send(message)
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
                case .failure(let error):
                    if self.isAwaitingFinalResponse && self.didReceiveResponseAfterFinalAudio {
                        self.didEmitFinal = true
                        self.emit(.finalTranscript(self.latestTranscript))
                    } else if !self.didEmitFinal {
                        self.emit(.error(error.localizedDescription))
                    }
                    self.cancel()
                }
            }
        }
    }

    private func handle(message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let value):
            data = value
        case .string(let stringValue):
            data = Data(stringValue.utf8)
        @unknown default:
            throw ASRProviderError.invalidResponse
        }

        if isAwaitingFinalResponse {
            didReceiveResponseAfterFinalAudio = true
        }

        let response = try Self.parseServerMessage(data)
        if let error = response.errorMessage {
            emit(.error(error))
            cancel()
            return
        }

        if let transcript = response.transcript, !transcript.trimmed.isEmpty {
            latestTranscript = transcript
            if isAwaitingFinalResponse && response.isDefinite {
                didEmitFinal = true
                emit(.finalTranscript(transcript))
                cancel()
            } else {
                emit(.partialTranscript(transcript))
            }
        } else if isAwaitingFinalResponse, !latestTranscript.trimmed.isEmpty {
            didEmitFinal = true
            emit(.finalTranscript(latestTranscript))
            cancel()
        }
    }

    private func emit(_ event: ASRProviderEvent) {
        eventHandler?(event)
    }
}

extension DoubaoStreamingASRProvider {
    struct MessageMetadata {
        var headerSize: Int
        var messageType: UInt8
        var messageFlags: UInt8
        var compression: UInt8
        var payloadSize: Int
        var sequenceNumber: Int32?
    }

    struct ParsedServerMessage {
        var transcript: String?
        var isDefinite: Bool
        var errorMessage: String?
    }

    private struct ServerPayload: Decodable {
        struct ResultPayload: Decodable {
            let text: String?
            let utterances: [Candidate.Utterance]?
        }

        struct Candidate: Decodable {
            struct Utterance: Decodable {
                let text: String?
                let definite: Bool?
            }

            let text: String?
            let utterances: [Utterance]?
        }

        let reqid: String?
        let code: Int?
        let message: String?
        let result: ResultPayload?

        var bestTranscript: String? {
            result?.text
        }

        var isDefinite: Bool {
            guard let utterances = result?.utterances, !utterances.isEmpty else {
                return false
            }
            return utterances.allSatisfy { $0.definite ?? false }
        }
    }

    nonisolated static func makeWebSocketRequest(
        for config: ASRSessionConfig,
        connectID: String,
        userAgent: String
    ) -> URLRequest {
        var request = URLRequest(url: doubaoASRServiceURL)
        request.timeoutInterval = 30
        request.setValue(config.appID, forHTTPHeaderField: "X-Api-App-Key")
        request.setValue(config.accessToken, forHTTPHeaderField: "X-Api-Access-Key")
        request.setValue(config.resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        return request
    }

    nonisolated static func makeFullClientRequest(for config: ASRSessionConfig, requestID: String) throws -> Data {
        let payload = try JSONSerialization.data(withJSONObject: [
            "user": [
                "uid": config.userID,
                "platform": "macOS",
                "app_version": "0.1",
            ],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": PCMUtilities.sampleRate,
                "bits": PCMUtilities.bitsPerSample,
                "channel": PCMUtilities.channelCount,
                "language": config.language.rawValue,
            ],
            "request": [
                "model_name": "bigmodel",
                "enable_itn": true,
                "enable_ddc": false,
                "enable_punc": true,
                "show_utterances": config.utteranceMode,
                "end_window_size": 800,
            ],
        ], options: [])

        let header = Data([0x11, 0x10, 0x10, 0x00])
        return header + PCMUtilities.bigEndianData(for: UInt32(payload.count)) + payload
    }

    nonisolated static func makeAudioRequest(audioData: Data, isFinal: Bool) -> Data {
        let flag: UInt8 = isFinal ? 0x02 : 0x00
        let header = Data([0x11, 0x20 | flag, 0x00, 0x00])
        return header + PCMUtilities.bigEndianData(for: UInt32(audioData.count)) + audioData
    }

    nonisolated static func parseServerMessage(_ data: Data) throws -> ParsedServerMessage {
        let metadata = try parseMetadata(data)

        switch metadata.messageType {
        case 0x9:
            let unpacked = try unpackMessage(data)
            let payload = unpacked.payload
            let decoded = try JSONDecoder().decode(ServerPayload.self, from: payload)
            return ParsedServerMessage(
                transcript: decoded.bestTranscript,
                isDefinite: (unpacked.metadata.sequenceNumber ?? 0) < 0 || decoded.isDefinite,
                errorMessage: decoded.code == nil || decoded.code == 1000 ? nil : decoded.message
            )
        case 0xF:
            let errorStart = metadata.headerSize
            guard data.count >= errorStart + 8 else {
                throw ASRProviderError.invalidResponse
            }

            let errorCode = Int(PCMUtilities.uint32(from: data.subdata(in: errorStart..<(errorStart + 4))))
            let errorSize = Int(PCMUtilities.uint32(from: data.subdata(in: (errorStart + 4)..<(errorStart + 8))))
            let messageStart = errorStart + 8
            let messageEnd = messageStart + errorSize
            guard messageEnd <= data.count else {
                throw ASRProviderError.invalidResponse
            }

            let errorMessage = String(data: data.subdata(in: messageStart..<messageEnd), encoding: .utf8)
                ?? "ASR service returned error code \(errorCode)."
            return ParsedServerMessage(
                transcript: nil,
                isDefinite: false,
                errorMessage: "ASR error \(errorCode): \(errorMessage)"
            )
        default:
            throw ASRProviderError.invalidResponse
        }
    }

    nonisolated static func parseMetadata(_ data: Data) throws -> MessageMetadata {
        guard data.count >= 8 else {
            throw ASRProviderError.invalidResponse
        }

        let bytes = [UInt8](data)
        let headerSize = Int(bytes[0] & 0x0F) * 4
        let messageType = bytes[1] >> 4
        let messageFlags = bytes[1] & 0x0F
        let compression = bytes[2] & 0x0F

        let hasSequence = messageType == 0x9 && (messageFlags == 0x01 || messageFlags == 0x03)
        let sequenceNumber: Int32?
        let payloadSizeOffset: Int

        if hasSequence {
            guard data.count >= headerSize + 8 else {
                throw ASRProviderError.invalidResponse
            }
            sequenceNumber = Int32(bitPattern: PCMUtilities.uint32(from: data.subdata(in: headerSize..<(headerSize + 4))))
            payloadSizeOffset = headerSize + 4
        } else {
            sequenceNumber = nil
            payloadSizeOffset = headerSize
        }

        guard data.count >= payloadSizeOffset + 4 else {
            throw ASRProviderError.invalidResponse
        }

        return MessageMetadata(
            headerSize: headerSize,
            messageType: messageType,
            messageFlags: messageFlags,
            compression: compression,
            payloadSize: Int(PCMUtilities.uint32(from: data.subdata(in: payloadSizeOffset..<(payloadSizeOffset + 4)))),
            sequenceNumber: sequenceNumber
        )
    }

    nonisolated static func unpackMessage(_ data: Data) throws -> (metadata: MessageMetadata, payload: Data) {
        let metadata = try parseMetadata(data)
        let payloadStart = metadata.headerSize + (metadata.sequenceNumber == nil ? 4 : 8)
        let payloadEnd = payloadStart + metadata.payloadSize
        guard payloadEnd <= data.count else {
            throw ASRProviderError.invalidResponse
        }

        guard metadata.compression == 0 else {
            throw ASRProviderError.transport("Server returned compressed payload, which this MVP does not decode yet.")
        }

        return (metadata, data.subdata(in: payloadStart..<payloadEnd))
    }
}
