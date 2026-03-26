import Foundation

struct DoubaoHandshakeProbeResult {
    let requestURL: URL
    let statusCode: Int
    let headers: [String: String]
    let body: String

    var statusLine: String {
        "HTTP \(statusCode) \(HTTPURLResponse.localizedString(forStatusCode: statusCode))"
    }

    var logID: String? {
        headers.first { $0.key.caseInsensitiveCompare("X-Tt-Logid") == .orderedSame }?.value
    }
}

enum DoubaoHandshakeProbeError: LocalizedError {
    case invalidRequest
    case invalidHTTPResponse
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            "Invalid WebSocket request."
        case .invalidHTTPResponse:
            "Could not parse HTTP response for handshake probe."
        case .transport(let message):
            message
        }
    }
}

enum DoubaoHandshakeProbe {
    static func probe(webSocketRequest: URLRequest) async throws -> DoubaoHandshakeProbeResult {
        let request = try makeHTTPRequest(from: webSocketRequest)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw DoubaoHandshakeProbeError.invalidHTTPResponse
            }

            let body = String(data: data, encoding: .utf8) ?? data.base64EncodedString()
            var headers: [String: String] = [:]
            for (key, value) in httpResponse.allHeaderFields {
                headers[String(describing: key)] = String(describing: value)
            }

            return DoubaoHandshakeProbeResult(
                requestURL: request.url ?? webSocketRequest.url ?? URL(string: "https://openspeech.bytedance.com")!,
                statusCode: httpResponse.statusCode,
                headers: headers,
                body: body
            )
        } catch {
            throw DoubaoHandshakeProbeError.transport(error.localizedDescription)
        }
    }

    static func makeHTTPRequest(from webSocketRequest: URLRequest) throws -> URLRequest {
        guard let webSocketURL = webSocketRequest.url else {
            throw DoubaoHandshakeProbeError.invalidRequest
        }

        guard var components = URLComponents(url: webSocketURL, resolvingAgainstBaseURL: false) else {
            throw DoubaoHandshakeProbeError.invalidRequest
        }

        switch components.scheme?.lowercased() {
        case "wss":
            components.scheme = "https"
        case "ws":
            components.scheme = "http"
        default:
            throw DoubaoHandshakeProbeError.invalidRequest
        }

        guard let httpURL = components.url else {
            throw DoubaoHandshakeProbeError.invalidRequest
        }

        var request = URLRequest(url: httpURL)
        request.httpMethod = "GET"
        request.timeoutInterval = webSocketRequest.timeoutInterval

        for (key, value) in webSocketRequest.allHTTPHeaderFields ?? [:] {
            request.setValue(value, forHTTPHeaderField: key)
        }

        request.setValue("websocket", forHTTPHeaderField: "Upgrade")
        request.setValue("Upgrade", forHTTPHeaderField: "Connection")
        request.setValue(Data((0..<16).map { _ in UInt8.random(in: 0...255) }).base64EncodedString(), forHTTPHeaderField: "Sec-WebSocket-Key")
        request.setValue("13", forHTTPHeaderField: "Sec-WebSocket-Version")
        return request
    }
}
