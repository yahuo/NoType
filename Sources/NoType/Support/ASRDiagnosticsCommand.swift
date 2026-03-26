import Foundation
import AppKit

enum ASRDiagnosticsCommand {
    static var shouldRun: Bool {
        CommandLine.arguments.contains("--diagnose-asr")
    }

    @MainActor
    static func run() async -> Int32 {
        let settings = SettingsStore().load()
        let keychain = KeychainClient()
        let environment = ProcessInfo.processInfo.environment

        let appID = environment["NOTYPE_APP_ID"]?.trimmed.isEmpty == false
            ? environment["NOTYPE_APP_ID"]!.trimmed
            : settings.appID.trimmed
        let resourceID = environment["NOTYPE_RESOURCE_ID"]?.trimmed.isEmpty == false
            ? environment["NOTYPE_RESOURCE_ID"]!.trimmed
            : settings.resourceID.trimmed

        let token: String
        if let overrideToken = environment["NOTYPE_ACCESS_TOKEN"]?.trimmed, !overrideToken.isEmpty {
            token = overrideToken
            print("Using Access Token from NOTYPE_ACCESS_TOKEN.")
        } else {
            do {
                token = try keychain.read(account: "doubao.access-token")
            } catch {
                print("Failed to read Access Token from Keychain: \(error.localizedDescription)")
                return 1
            }
        }

        guard !appID.isEmpty, !resourceID.isEmpty, !token.trimmed.isEmpty else {
            print("No complete ASR configuration found in local settings.")
            return 1
        }

        let config = ASRSessionConfig(
            appID: appID,
            accessToken: token.trimmed,
            resourceID: resourceID,
            userID: ProcessInfo.processInfo.hostName,
            language: settings.language,
            workflow: "audio_in,resample,partition,vad,fe,decode,itn,nlu_punctuate",
            utteranceMode: true
        )

        print("Diagnosing ASR with AppID=\(config.appID), ResourceID=\(config.resourceID)")

        let requestID = UUID().uuidString.lowercased()
        let session = URLSession(configuration: .default)
        defer { session.invalidateAndCancel() }

        let request = DoubaoStreamingASRProvider.makeWebSocketRequest(
            for: config,
            connectID: requestID,
            userAgent: "NoType/diag"
        )

        let task = session.webSocketTask(with: request)
        task.resume()

        do {
            try await task.send(.data(DoubaoStreamingASRProvider.makeFullClientRequest(for: config, requestID: requestID)))
            print("Sent full client request.")

            if let message = try await receiveMessage(task: task, timeoutNanoseconds: 5_000_000_000) {
                try printMessage(message, label: "Response after full request")
            } else {
                print("No response after full request within timeout.")
            }

            let silence = Data(repeating: 0, count: PCMUtilities.chunkByteCount)
            try await task.send(.data(DoubaoStreamingASRProvider.makeAudioRequest(audioData: silence, isFinal: true)))
            print("Sent final silent audio frame (\(silence.count) bytes).")

            var received = 0
            while received < 3 {
                do {
                    guard let message = try await receiveMessage(task: task, timeoutNanoseconds: 5_000_000_000) else {
                        print("No more responses within timeout.")
                        if received > 0 {
                            print("Transport looks healthy: server responded after the final audio frame.")
                            task.cancel(with: .normalClosure, reason: nil)
                            return 0
                        }
                        break
                    }
                    received += 1
                    try printMessage(message, label: "Audio response #\(received)")
                } catch {
                    if received > 0, error.localizedDescription.contains("Socket is not connected") {
                        print("Server closed the socket after responding to the final audio frame; treating this as healthy.")
                        task.cancel(with: .normalClosure, reason: nil)
                        return 0
                    }
                    throw error
                }
            }

            task.cancel(with: .normalClosure, reason: nil)
            return 0
        } catch {
            print("ASR diagnostic failed: \(error.localizedDescription)")
            task.cancel(with: .goingAway, reason: nil)
            return 1
        }
    }

    private static func receiveMessage(
        task: URLSessionWebSocketTask,
        timeoutNanoseconds: UInt64
    ) async throws -> URLSessionWebSocketTask.Message? {
        try await withThrowingTaskGroup(of: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask {
                try await task.receive()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                return nil
            }

            let value = try await group.next() ?? nil
            group.cancelAll()
            return value
        }
    }

    private static func printMessage(
        _ message: URLSessionWebSocketTask.Message,
        label: String
    ) throws {
        switch message {
        case .string(let value):
            print("\(label): string message -> \(value)")
        case .data(let data):
            print("\(label): raw bytes=\(data.count), prefix=\(hexPrefix(data, limit: 48))")

            if data.count >= 4 {
                let bytes = [UInt8](data.prefix(4))
                let messageType = bytes[1] >> 4
                let flags = bytes[1] & 0x0F
                let compression = bytes[2] & 0x0F
                print("header guess: version=\(bytes[0] >> 4), headerSizeWords=\(bytes[0] & 0x0F), type=0x\(String(messageType, radix: 16)), flags=0x\(String(flags, radix: 16)), compression=\(compression)")
            }

            do {
                let metadata = try DoubaoStreamingASRProvider.parseMetadata(data)
                print("\(label): parsed payloadSize=\(metadata.payloadSize)")
                let parsed = try DoubaoStreamingASRProvider.parseServerMessage(data)
                print("parsed message: transcript=\(parsed.transcript ?? "nil"), definite=\(parsed.isDefinite), error=\(parsed.errorMessage ?? "nil")")
            } catch {
                print("parse error: \(error.localizedDescription)")
            }
        @unknown default:
            print("\(label): unsupported message kind")
        }
    }

    private static func hexPrefix(_ data: Data, limit: Int = 32) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined()
    }
}
