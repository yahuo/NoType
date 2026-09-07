import Darwin
import Foundation
import Testing
@testable import NoType

@Test @MainActor
func bridgeAcceptsMoreThanSixteenSequentialConnections() async throws {
    let directory = URL(fileURLWithPath: "/tmp/nt-many-\(UUID().uuidString.prefix(8))")
    let service = NoTypeBridgeService(runtimeDirectory: directory)
    defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
    try service.start { request, _ in .success(id: request.id, text: "pong") }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: service.socketURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    for index in 0..<32 {
        let response = try await NoTypeBridgeClient(socketURL: service.socketURL, timeout: 0.5)
            .send(.init(id: "ping-\(index)", method: "ping"))
        #expect(response.id == "ping-\(index)")
        #expect(response.ok)
    }
}

@Test
func bridgeDecoderConsumesCoalescedAndFragmentedFrames() throws {
    let first = try NoTypeBridgeFrameCodec.encode(NoTypeBridgeRequest(id: "first", method: "ping"))
    let second = try NoTypeBridgeFrameCodec.encode(NoTypeBridgeRequest(id: "second", method: "ping"))
    var decoder = NoTypeBridgeFrameDecoder()
    #expect(try decoder.append(first.prefix(2)) == nil)
    let payload = try #require(try decoder.append(first.dropFirst(2) + second))
    #expect(try JSONDecoder().decode(NoTypeBridgeRequest.self, from: payload).id == "first")
    let next = try #require(try decoder.append(Data()))
    #expect(try JSONDecoder().decode(NoTypeBridgeRequest.self, from: next).id == "second")
    #expect(try decoder.append(Data()) == nil)
}

private final class BridgeTestSocket {
    let fd: Int32
    init(_ path: String) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSignal: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: Array(path.utf8))
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result != 0 { close(fd); throw POSIXError(.ECONNREFUSED) }
    }
    deinit { close(fd) }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
    }
    func read(_ length: Int) throws -> Data {
        var data = Data(count: length)
        try data.withUnsafeMutableBytes { bytes in
            var offset = 0
            while offset < length {
                let count = recv(fd, bytes.baseAddress!.advanced(by: offset), length - offset, 0)
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
        }
        return data
    }
    func response() throws -> NoTypeBridgeResponse {
        let length = try read(4).reduce(0) { ($0 << 8) | Int($1) }
        return try JSONDecoder().decode(NoTypeBridgeResponse.self, from: read(length))
    }
    func expectClosed() {
        var byte: UInt8 = 0
        #expect(recv(fd, &byte, 1, 0) == 0)
    }
}

@Test @MainActor
func browserConnectionStreamsOneHundredBatchesAndLegacyStillCloses() async throws {
    let directory = URL(fileURLWithPath: "/tmp/nt-reuse-\(UUID().uuidString.prefix(8))")
    let service = NoTypeBridgeService(runtimeDirectory: directory)
    defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
    try service.start { request, progress in
        var partial = NoTypeBridgeResponse.success(id: request.id, text: "部分")
        partial.partial = true
        progress(partial)
        return .success(id: request.id, text: "完整")
    }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: service.socketURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let path = service.socketURL.path
    try await Task.detached {
        let socket = try BridgeTestSocket(path)
        for index in 0..<100 {
            var request = NoTypeBridgeRequest(id: "batch-\(index)", method: "translate_chinese_batch", client: "browser")
            request.keepAlive = true
            let frame = try NoTypeBridgeFrameCodec.encode(request)
            try socket.write(frame.prefix(2))
            try socket.write(frame.dropFirst(2))
            let partial = try socket.response()
            let final = try socket.response()
            #expect(partial.id == request.id && partial.partial == true)
            #expect(final.id == request.id && final.text == "完整" && final.partial == nil)
        }
        let legacy = NoTypeBridgeRequest(id: "legacy", method: "translate")
        try socket.write(NoTypeBridgeFrameCodec.encode(legacy))
        _ = try socket.response()
        #expect(try socket.response().id == "legacy")
        socket.expectClosed()
        let malformed = try BridgeTestSocket(path)
        try malformed.write(Data([0, 0, 0, 1, 123]))
        #expect(try malformed.response().error?.code == "invalid_request")
        malformed.expectClosed()
    }.value
}

@Test @MainActor
func bridgeStopClosesIdlePersistentConnection() async throws {
    let directory = URL(fileURLWithPath: "/tmp/nt-stop-\(UUID().uuidString.prefix(8))")
    let service = NoTypeBridgeService(runtimeDirectory: directory)
    defer { service.stop(); try? FileManager.default.removeItem(at: directory) }
    try service.start { request, _ in .success(id: request.id, text: "pong") }
    for _ in 0..<100 where !FileManager.default.fileExists(atPath: service.socketURL.path) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let path = service.socketURL.path
    try await Task.detached {
        let socket = try BridgeTestSocket(path)
        var request = NoTypeBridgeRequest(method: "ping", client: "browser")
        request.keepAlive = true
        try socket.write(NoTypeBridgeFrameCodec.encode(request))
        #expect(try socket.response().ok)
        await service.stop()
        socket.expectClosed()
    }.value
}
