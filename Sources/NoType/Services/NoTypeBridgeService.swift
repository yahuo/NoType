import Darwin
import Foundation
import Network

enum NoTypeBridgeProtocol {
    static let version = 1
    static let maximumFrameBytes = 1_048_576
    static let pingMethod = "ping"
    static let translateMethod = "translate"
    static let translateEditorMethod = "translate_editor"
}

struct NoTypeBridgeRequest: Codable, Equatable, Sendable {
    let version: Int
    let id: String
    let method: String
    let client: String?
    let text: String?
    let token: String?
    let processID: Int32?
    let parentProcessID: Int32?
    let terminal: String?
    let trigger: String?

    init(
        version: Int = NoTypeBridgeProtocol.version,
        id: String = UUID().uuidString,
        method: String,
        client: String? = nil,
        text: String? = nil,
        token: String? = nil,
        processID: Int32? = nil,
        parentProcessID: Int32? = nil,
        terminal: String? = nil,
        trigger: String? = nil
    ) {
        self.version = version
        self.id = id
        self.method = method
        self.client = client
        self.text = text
        self.token = token
        self.processID = processID
        self.parentProcessID = parentProcessID
        self.terminal = terminal
        self.trigger = trigger
    }
}

struct NoTypeBridgeResponse: Codable, Equatable, Sendable {
    struct Failure: Codable, Equatable, Sendable {
        let code: String
        let message: String
    }

    let version: Int
    let id: String
    let ok: Bool
    let text: String?
    let error: Failure?

    static func success(id: String, text: String? = nil) -> NoTypeBridgeResponse {
        NoTypeBridgeResponse(
            version: NoTypeBridgeProtocol.version,
            id: id,
            ok: true,
            text: text,
            error: nil
        )
    }

    static func failure(id: String, code: String, message: String) -> NoTypeBridgeResponse {
        NoTypeBridgeResponse(
            version: NoTypeBridgeProtocol.version,
            id: id,
            ok: false,
            text: nil,
            error: Failure(code: code, message: message)
        )
    }
}

enum NoTypeBridgeFrameError: LocalizedError, Equatable {
    case emptyFrame
    case frameTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .emptyFrame:
            "The NoType bridge received an empty frame."
        case .frameTooLarge(let byteCount):
            "The NoType bridge frame is too large (\(byteCount) bytes)."
        }
    }
}

struct NoTypeBridgeFrameCodec {
    static func encode<T: Encodable>(
        _ value: T,
        encoder: JSONEncoder = JSONEncoder()
    ) throws -> Data {
        let payload = try encoder.encode(value)
        guard !payload.isEmpty else {
            throw NoTypeBridgeFrameError.emptyFrame
        }
        guard payload.count <= NoTypeBridgeProtocol.maximumFrameBytes else {
            throw NoTypeBridgeFrameError.frameTooLarge(payload.count)
        }

        let byteCount = UInt32(payload.count)
        var frame = Data(capacity: 4 + payload.count)
        frame.append(UInt8((byteCount >> 24) & 0xFF))
        frame.append(UInt8((byteCount >> 16) & 0xFF))
        frame.append(UInt8((byteCount >> 8) & 0xFF))
        frame.append(UInt8(byteCount & 0xFF))
        frame.append(payload)
        return frame
    }
}

struct NoTypeBridgeFrameDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) throws -> Data? {
        buffer.append(data)
        guard buffer.count >= 4 else { return nil }

        let header = buffer.prefix(4)
        let payloadLength = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let payloadByteCount = Int(payloadLength)

        guard payloadByteCount > 0 else {
            throw NoTypeBridgeFrameError.emptyFrame
        }
        guard payloadByteCount <= NoTypeBridgeProtocol.maximumFrameBytes else {
            throw NoTypeBridgeFrameError.frameTooLarge(payloadByteCount)
        }
        guard buffer.count >= 4 + payloadByteCount else { return nil }

        return Data(buffer[4..<(4 + payloadByteCount)])
    }
}

enum NoTypeBridgeServiceError: LocalizedError {
    case alreadyStarted
    case anotherInstanceIsListening
    case invalidRuntimeDirectory(String)
    case socketPathTooLong(String)
    case unableToCreateLock(String)

    var errorDescription: String? {
        switch self {
        case .alreadyStarted:
            "The NoType bridge is already running."
        case .anotherInstanceIsListening:
            "Another NoType instance already owns the local bridge."
        case .invalidRuntimeDirectory(let path):
            "The NoType bridge runtime directory is not private or is not owned by this user: \(path)"
        case .socketPathTooLong(let path):
            "The NoType bridge socket path is too long: \(path)"
        case .unableToCreateLock(let message):
            "Unable to create the NoType bridge lock: \(message)"
        }
    }
}

@MainActor
final class NoTypeBridgeService {
    typealias RequestHandler = @Sendable (NoTypeBridgeRequest) async -> NoTypeBridgeResponse
    typealias FailureHandler = @Sendable (String) -> Void

    nonisolated static var defaultRuntimeDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("com.opensource.notype", isDirectory: true)
    }

    nonisolated static var defaultSocketURL: URL {
        defaultRuntimeDirectory.appendingPathComponent("bridge.sock", isDirectory: false)
    }

    let socketURL: URL

    private let runtimeDirectory: URL
    private let lockURL: URL
    private let queue = DispatchQueue(label: "com.opensource.notype.bridge", qos: .userInitiated)
    private var listener: NWListener?
    private var lockFileDescriptor: Int32 = -1
    private var failureHandler: FailureHandler?

    init(runtimeDirectory: URL = NoTypeBridgeService.defaultRuntimeDirectory) {
        self.runtimeDirectory = runtimeDirectory
        socketURL = runtimeDirectory.appendingPathComponent("bridge.sock", isDirectory: false)
        lockURL = runtimeDirectory.appendingPathComponent("bridge.lock", isDirectory: false)
    }

    func start(
        requestHandler: @escaping RequestHandler,
        failureHandler: @escaping FailureHandler = { _ in }
    ) throws {
        guard listener == nil else {
            throw NoTypeBridgeServiceError.alreadyStarted
        }

        try prepareRuntimeDirectory()
        try acquireRuntimeLock()

        do {
            try removeStaleSocket()
            try validateSocketPath()

            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
            let listener = try NWListener(using: parameters)
            listener.newConnectionLimit = 16
            listener.newConnectionHandler = { connection in
                NoTypeBridgeConnection(
                    connection: connection,
                    queue: DispatchQueue(
                        label: "com.opensource.notype.bridge.connection.\(UUID().uuidString)",
                        qos: .userInitiated
                    ),
                    requestHandler: requestHandler
                ).start()
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleListenerState(state)
                }
            }

            self.failureHandler = failureHandler
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            try? FileManager.default.removeItem(at: socketURL)
            releaseRuntimeLock()
            throw error
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        failureHandler = nil
        try? FileManager.default.removeItem(at: socketURL)
        releaseRuntimeLock()
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard chmod(socketURL.path, S_IRUSR | S_IWUSR) == 0 else {
                reportListenerFailure("Unable to secure the NoType bridge socket: \(Self.errnoMessage())")
                return
            }
        case .failed(let error):
            reportListenerFailure(error.localizedDescription)
        case .setup, .waiting, .cancelled:
            break
        @unknown default:
            break
        }
    }

    private func prepareRuntimeDirectory() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: 0o700)]
        )

        var metadata = stat()
        guard lstat(runtimeDirectory.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFDIR,
              metadata.st_uid == geteuid()
        else {
            throw NoTypeBridgeServiceError.invalidRuntimeDirectory(runtimeDirectory.path)
        }

        guard chmod(runtimeDirectory.path, S_IRWXU) == 0 else {
            throw NoTypeBridgeServiceError.invalidRuntimeDirectory(runtimeDirectory.path)
        }
    }

    private func acquireRuntimeLock() throws {
        let descriptor = open(
            lockURL.path,
            O_CREAT | O_RDWR | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw NoTypeBridgeServiceError.unableToCreateLock(
                String(cString: strerror(errno))
            )
        }

        guard fchmod(descriptor, S_IRUSR | S_IWUSR) == 0 else {
            let message = Self.errnoMessage()
            close(descriptor)
            throw NoTypeBridgeServiceError.unableToCreateLock(message)
        }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            close(descriptor)
            if lockError == EWOULDBLOCK {
                throw NoTypeBridgeServiceError.anotherInstanceIsListening
            }
            throw NoTypeBridgeServiceError.unableToCreateLock(
                String(cString: strerror(lockError))
            )
        }

        lockFileDescriptor = descriptor
    }

    private func reportListenerFailure(_ message: String) {
        let failureHandler = self.failureHandler
        stop()
        failureHandler?(message)
    }

    private func releaseRuntimeLock() {
        guard lockFileDescriptor >= 0 else { return }
        _ = flock(lockFileDescriptor, LOCK_UN)
        close(lockFileDescriptor)
        lockFileDescriptor = -1
    }

    private func removeStaleSocket() throws {
        guard FileManager.default.fileExists(atPath: socketURL.path) else { return }
        try FileManager.default.removeItem(at: socketURL)
    }

    private func validateSocketPath() throws {
        // Darwin sockaddr_un.sun_path has room for 104 bytes including the terminator.
        guard socketURL.path.utf8.count < 104 else {
            throw NoTypeBridgeServiceError.socketPathTooLong(socketURL.path)
        }
    }

    private nonisolated static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}

enum NoTypeBridgeClientError: LocalizedError {
    case socketPathTooLong(String)
    case connectionFailed(String)
    case transportFailed(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            "The NoType bridge socket path is too long: \(path)"
        case .connectionFailed(let message):
            "Unable to connect to NoType: \(message)"
        case .transportFailed(let message):
            "NoType bridge transport failed: \(message)"
        case .invalidResponse(let message):
            "NoType returned an invalid bridge response: \(message)"
        }
    }
}

struct NoTypeBridgeClient: Sendable {
    let socketURL: URL
    let timeout: TimeInterval

    init(
        socketURL: URL = NoTypeBridgeService.defaultSocketURL,
        timeout: TimeInterval = 15
    ) {
        self.socketURL = socketURL
        self.timeout = timeout
    }

    func send(_ request: NoTypeBridgeRequest) async throws -> NoTypeBridgeResponse {
        let socketURL = self.socketURL
        let timeout = self.timeout
        return try await Task.detached(priority: .userInitiated) {
            try Self.sendBlocking(request, socketURL: socketURL, timeout: timeout)
        }.value
    }

    private static func sendBlocking(
        _ request: NoTypeBridgeRequest,
        socketURL: URL,
        timeout: TimeInterval
    ) throws -> NoTypeBridgeResponse {
        let path = socketURL.path
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < 104 else {
            throw NoTypeBridgeClientError.socketPathTooLong(path)
        }

        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw NoTypeBridgeClientError.connectionFailed(errnoMessage())
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
            throw NoTypeBridgeClientError.connectionFailed(errnoMessage())
        }

        let requestFrame = try NoTypeBridgeFrameCodec.encode(request)
        try writeAll(requestFrame, to: descriptor)

        let header = try readExactly(4, from: descriptor)
        let payloadLength = header.reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }
        let payloadByteCount = Int(payloadLength)
        guard payloadByteCount > 0,
              payloadByteCount <= NoTypeBridgeProtocol.maximumFrameBytes
        else {
            throw NoTypeBridgeClientError.invalidResponse(
                "invalid frame length \(payloadByteCount)"
            )
        }

        let payload = Data(try readExactly(payloadByteCount, from: descriptor))
        do {
            return try JSONDecoder().decode(NoTypeBridgeResponse.self, from: payload)
        } catch {
            throw NoTypeBridgeClientError.invalidResponse(error.localizedDescription)
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
                    throw NoTypeBridgeClientError.transportFailed(errnoMessage())
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
                throw NoTypeBridgeClientError.transportFailed(
                    "the connection closed before the response was complete"
                )
            } else {
                throw NoTypeBridgeClientError.transportFailed(errnoMessage())
            }
        }

        return bytes
    }

    private static func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}

private final class NoTypeBridgeConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let requestHandler: NoTypeBridgeService.RequestHandler
    private var frameDecoder = NoTypeBridgeFrameDecoder()
    private var finished = false

    init(
        connection: NWConnection,
        queue: DispatchQueue,
        requestHandler: @escaping NoTypeBridgeService.RequestHandler
    ) {
        self.connection = connection
        self.queue = queue
        self.requestHandler = requestHandler
    }

    func start() {
        connection.start(queue: queue)
        receiveNextChunk()
    }

    private func receiveNextChunk() {
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 64 * 1024
        ) { [self] data, _, isComplete, error in
            guard !finished else { return }

            if let error {
                finish(error: error)
                return
            }

            do {
                if let data, !data.isEmpty,
                   let payload = try frameDecoder.append(data) {
                    try handle(payload: payload)
                    return
                }
            } catch {
                send(
                    .failure(
                        id: "",
                        code: "invalid_frame",
                        message: error.localizedDescription
                    )
                )
                return
            }

            if isComplete {
                send(
                    .failure(
                        id: "",
                        code: "incomplete_frame",
                        message: "The NoType bridge request ended before a complete frame was received."
                    )
                )
                return
            }

            receiveNextChunk()
        }
    }

    private func handle(payload: Data) throws {
        let request: NoTypeBridgeRequest
        do {
            request = try JSONDecoder().decode(NoTypeBridgeRequest.self, from: payload)
        } catch {
            send(
                .failure(
                    id: "",
                    code: "invalid_request",
                    message: "The NoType bridge request is not valid JSON."
                )
            )
            return
        }

        Task { [self] in
            let response = await requestHandler(request)
            queue.async { [self] in
                send(response)
            }
        }
    }

    private func send(_ response: NoTypeBridgeResponse) {
        guard !finished else { return }

        do {
            let frame = try NoTypeBridgeFrameCodec.encode(response)
            connection.send(
                content: frame,
                contentContext: .defaultMessage,
                isComplete: true,
                completion: .contentProcessed { [self] error in
                    queue.async { [self] in
                        finish(error: error)
                    }
                }
            )
        } catch {
            finish(error: error)
        }
    }

    private func finish(error: Error?) {
        guard !finished else { return }
        finished = true
        connection.cancel()
    }
}
