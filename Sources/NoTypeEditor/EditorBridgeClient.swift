import Darwin
import Foundation

private enum EditorBridgeProtocol {
    static let version = 1
    static let maximumFrameBytes = 1_048_576
    static let translateEditorMethod = "translate_editor"
}

struct NoTypeEditorPendingTrigger: Codable, Equatable {
    let version: Int
    let token: String
    let createdAtMilliseconds: Int64
    let targetProcessID: Int32
    let targetBundleIdentifier: String
}

private struct EditorBridgeRequest: Encodable {
    let version: Int
    let id: String
    let method: String
    let client: String
    let text: String
    let token: String
    let processID: Int32
    let parentProcessID: Int32
    let terminal: String
    let trigger: String
}

private struct EditorBridgeResponse: Decodable {
    struct Failure: Decodable {
        let code: String
        let message: String
    }

    let version: Int
    let id: String
    let ok: Bool
    let text: String?
    let error: Failure?
}

enum NoTypeEditorBridgeError: LocalizedError {
    case invalidRequest(String)
    case connectionFailed(String)
    case transportFailed(String)
    case invalidResponse(String)
    case translationFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message):
            "Invalid NoType editor request: \(message)"
        case .connectionFailed(let message):
            "Unable to connect to NoType: \(message)"
        case .transportFailed(let message):
            "NoType editor transport failed: \(message)"
        case .invalidResponse(let message):
            "NoType returned an invalid editor response: \(message)"
        case .translationFailed(let message):
            message
        }
    }
}

struct NoTypeEditorBridgeClient {
    let socketURL: URL
    let timeout: TimeInterval

    init(socketURL: URL, timeout: TimeInterval = 30) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    func translate(
        sourceText: String,
        trigger: NoTypeEditorPendingTrigger,
        processID: Int32,
        parentProcessID: Int32,
        terminal: String
    ) throws -> String {
        let requestID = UUID().uuidString
        let request = EditorBridgeRequest(
            version: EditorBridgeProtocol.version,
            id: requestID,
            method: EditorBridgeProtocol.translateEditorMethod,
            client: "agent-editor",
            text: sourceText,
            token: trigger.token,
            processID: processID,
            parentProcessID: parentProcessID,
            terminal: terminal,
            trigger: "triple-space"
        )
        let response = try send(request)

        guard response.version == EditorBridgeProtocol.version,
              response.id == requestID
        else {
            throw NoTypeEditorBridgeError.invalidResponse("response ID or version mismatch")
        }
        guard response.ok else {
            throw NoTypeEditorBridgeError.translationFailed(
                response.error?.message ?? "NoType translation failed."
            )
        }
        guard let translated = response.text,
              !translated.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw NoTypeEditorBridgeError.invalidResponse("translation is empty")
        }
        return translated
    }

    private func send(_ request: EditorBridgeRequest) throws -> EditorBridgeResponse {
        let path = socketURL.path
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else {
            throw NoTypeEditorBridgeError.invalidRequest("socket path is too long")
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NoTypeEditorBridgeError.connectionFailed(Self.errnoMessage())
        }
        defer { close(descriptor) }

        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size)
            )
        }

        let boundedTimeout = max(0.1, timeout)
        var socketTimeout = timeval(
            tv_sec: Int(boundedTimeout),
            tv_usec: Int32((boundedTimeout.truncatingRemainder(dividingBy: 1)) * 1_000_000)
        )
        _ = withUnsafePointer(to: &socketTimeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        _ = withUnsafePointer(to: &socketTimeout) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_SNDTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }

        let connectResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(
                    descriptor,
                    socketAddress,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard connectResult == 0 else {
            throw NoTypeEditorBridgeError.connectionFailed(Self.errnoMessage())
        }

        let payload = try JSONEncoder().encode(request)
        guard !payload.isEmpty, payload.count <= EditorBridgeProtocol.maximumFrameBytes else {
            throw NoTypeEditorBridgeError.invalidRequest("payload is too large")
        }

        var frame = Data(capacity: 4 + payload.count)
        let byteCount = UInt32(payload.count)
        frame.append(UInt8((byteCount >> 24) & 0xFF))
        frame.append(UInt8((byteCount >> 16) & 0xFF))
        frame.append(UInt8((byteCount >> 8) & 0xFF))
        frame.append(UInt8(byteCount & 0xFF))
        frame.append(payload)
        try Self.writeAll(frame, to: descriptor)

        let header = try Self.readExactly(4, from: descriptor)
        let responseByteCount = Int(header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        })
        guard responseByteCount > 0,
              responseByteCount <= EditorBridgeProtocol.maximumFrameBytes
        else {
            throw NoTypeEditorBridgeError.invalidResponse(
                "invalid frame length \(responseByteCount)"
            )
        }

        let responsePayload = Data(try Self.readExactly(responseByteCount, from: descriptor))
        do {
            return try JSONDecoder().decode(EditorBridgeResponse.self, from: responsePayload)
        } catch {
            throw NoTypeEditorBridgeError.invalidResponse(error.localizedDescription)
        }
    }

    private static func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0

            while bytesWritten < rawBuffer.count {
                let result = Darwin.send(
                    descriptor,
                    baseAddress.advanced(by: bytesWritten),
                    rawBuffer.count - bytesWritten,
                    0
                )
                if result > 0 {
                    bytesWritten += result
                } else if result < 0, errno == EINTR {
                    continue
                } else {
                    throw NoTypeEditorBridgeError.transportFailed(errnoMessage())
                }
            }
        }
    }

    private static func readExactly(_ byteCount: Int, from descriptor: Int32) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        var bytesRead = 0

        while bytesRead < byteCount {
            let result = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.recv(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: bytesRead),
                    byteCount - bytesRead,
                    0
                )
            }
            if result > 0 {
                bytesRead += result
            } else if result < 0, errno == EINTR {
                continue
            } else if result == 0 {
                throw NoTypeEditorBridgeError.transportFailed(
                    "connection closed before the response was complete"
                )
            } else {
                throw NoTypeEditorBridgeError.transportFailed(errnoMessage())
            }
        }
        return bytes
    }

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
