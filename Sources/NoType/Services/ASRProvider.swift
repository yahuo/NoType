import Foundation

enum ASRProviderError: LocalizedError {
    case notConfigured
    case sessionNotStarted
    case invalidResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            "ASR configuration is incomplete."
        case .sessionNotStarted:
            "ASR session has not started."
        case .invalidResponse:
            "ASR service returned an unexpected response."
        case .transport(let message):
            message
        }
    }
}

@MainActor
protocol ASRProvider: AnyObject {
    var eventHandler: ((ASRProviderEvent) -> Void)? { get set }

    func startSession(config: ASRSessionConfig) async throws
    func sendAudioFrame(_ data: Data, isFinal: Bool) async throws
    func finish() async throws
    func cancel()
}
