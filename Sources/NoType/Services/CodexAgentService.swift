import AppKit
import Foundation

enum NeoAgentEvent {
    case ready, working(Bool), reply(String), failed(Error)
}

@MainActor
protocol NeoAgentSession: AnyObject {
    func start(onEvent: @escaping (NeoAgentEvent) -> Void) async throws -> String
    func attach(callID: String) async throws
    func speak(_ text: String) async throws
    func interrupt()
    func stop()
}

enum CodexAgentError: LocalizedError {
    case missingRuntime, invalidResponse, persistentThread, disconnected, requestFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingRuntime: "请先在本机安装并登录 Codex 桌面应用。"
        case .invalidResponse: "Codex 执行服务返回了无法处理的响应。"
        case .persistentThread: "Codex 未创建临时会话，Neo 已停止连接。"
        case .disconnected: "Codex 执行服务已断开，请重新唤醒 Neo。"
        case .requestFailed(let method): "Codex 执行服务请求失败（\(method)），请检查 Codex 登录和网络。"
        }
    }
}

/// Owns one in-memory Codex thread and its stdio transport for a single voice call.
/// Codex loads the user's existing login, model, permissions and installed tools.
@MainActor
final class CodexAgentService: NeoAgentSession {
    private let processFactory: () throws -> Process
    private let workspace: URL
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var sequence = 0
    private var generation = UUID()
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var deadlines: [Int: Task<Void, Never>] = [:]
    private var threadID: String?
    private var turnID: String?
    private var finalReply = ""
    private var onEvent: ((NeoAgentEvent) -> Void)?
    private var alerts: [(alert: NSAlert, parent: NSWindow)] = []

    init(workspace: URL? = nil, processFactory: (() throws -> Process)? = nil) {
        self.workspace = workspace ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/NoType/Neo", isDirectory: true)
        self.processFactory = processFactory ?? Self.makeProcess
    }

    static let launchArguments = [
        "app-server", "--stdio", "--enable", "realtime_conversation",
        "-c", "features.hooks=false", "-c", "features.memories=false", "-c", "features.chronicle=false",
    ]

    private static func makeProcess() throws -> Process {
        let candidates = [
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.appendingPathComponent("Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/Applications/Codex.app/Contents/Resources/codex"),
        ].compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CodexAgentError.missingRuntime
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = launchArguments
        var environment = ProcessInfo.processInfo.environment
        // A GUI launch has a shorter PATH than the terminal; installed MCP launchers may use Node.
        environment["PATH"] = (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":/opt/homebrew/bin:/usr/local/bin"
        for key in ["OPENAI_API_KEY", "OPENAI_BASE_URL", "CODEX_THREAD_ID", "CODEX_SESSION_ID", "CODEX_APP_TOOLS_PIPE_PATH"] {
            environment.removeValue(forKey: key)
        }
        process.environment = environment
        return process
    }

    static func threadParameters(workspace: URL) -> [String: Any] {
        [
            "ephemeral": true, "cwd": workspace.path, "modelProvider": "openai",
            "threadSource": "notype_voice",
            "config": ["web_search": "live"],
            "dynamicTools": [[
                "type": "function", "name": "neo_frontmost_app",
                "description": "读取此刻真正位于前台的 macOS 应用名称与 bundle ID。用户提到当前屏幕或这个应用时先调用，再使用 cua_repl 的 cua.getApp(bundle ID) 读取窗口或截图；不要凭应用列表顺序猜测。",
                "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false],
            ]],
            "developerInstructions": """
            你是 NoType Neo 语音助手的 Codex 执行代理。使用现有联网搜索、文件、浏览器、Computer Use 和已安装插件完成用户的语音请求，简短中文回复实际结果。用户提到屏幕或当前应用时先用 Computer Use 读取实际状态；应用控制遵循该工具文档，不猜测屏幕，也不假装操作完成。涉及发送消息、发布、付款或删除等行为，必须有用户针对该行为的明确授权。需要补充信息时提出一个简短问题。本次是临时语音会话，不创建聊天记录或新记忆；只在用户要求生成文件时保存相应产物。结束语音时停止尚未完成的工作。
            """,
        ]
    }

    func start(onEvent: @escaping (NeoAgentEvent) -> Void) async throws -> String {
        stop()
        let id = generation
        self.onEvent = onEvent
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let process = try processFactory()
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        // Never persist transcripts or raw tool output in a diagnostic log.
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = workspace
        self.process = process
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        output?.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.receive(data)
            }
        }
        process.terminationHandler = { @Sendable [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == id else { return }
                self.fail(CodexAgentError.disconnected)
            }
        }
        do {
            try process.run()
            _ = try await request("initialize", [
                "clientInfo": ["name": "notype_neo", "title": "NoType Neo", "version": "0.1"],
                "capabilities": ["experimentalApi": true],
            ])
            try send(["method": "initialized", "params": [:]])
            let result = try await request("thread/start", Self.threadParameters(workspace: workspace))
            guard let thread = result["thread"] as? [String: Any], let threadID = thread["id"] as? String else {
                throw CodexAgentError.invalidResponse
            }
            guard thread["ephemeral"] as? Bool == true, thread["path"] == nil || thread["path"] is NSNull else {
                throw CodexAgentError.persistentThread
            }
            try Task.checkCancellation()
            guard generation == id else { throw CancellationError() }
            self.threadID = threadID
            return threadID
        } catch {
            if generation == id { stop() }
            throw error
        }
    }

    func attach(callID: String) async throws {
        guard let threadID else { throw CodexAgentError.disconnected }
        _ = try await request("thread/realtime/start", [
            "threadId": threadID, "version": "v3", "outputModality": "audio",
            "includeStartupContext": false, "flushTranscriptTailOnSessionEnd": false,
            "clientManagedHandoffs": true,
            "transport": ["type": "existingCall", "callId": callID],
        ])
    }

    func speak(_ text: String) async throws {
        guard let threadID else { throw CodexAgentError.disconnected }
        _ = try await request("thread/realtime/appendSpeech", ["threadId": threadID, "text": text])
    }

    private func request(_ method: String, _ params: [String: Any]) async throws -> [String: Any] {
        try Task.checkCancellation()
        sequence += 1
        let requestID = sequence
        let data: Data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[requestID] = continuation
                do { try send(["id": requestID, "method": method, "params": params]) }
                catch { resolve(requestID, result: .failure(error)); return }
                deadlines[requestID] = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(25)) } catch { return }
                    self?.resolve(requestID, result: .failure(CodexAgentError.requestFailed(method)))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(requestID, result: .failure(CancellationError())) }
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexAgentError.invalidResponse
        }
        return result
    }

    private func send(_ value: [String: Any]) throws {
        guard let input, process?.isRunning == true else { throw CodexAgentError.disconnected }
        var data = try JSONSerialization.data(withJSONObject: value)
        data.append(10)
        try input.write(contentsOf: data)
    }

    private func resolve(_ id: Int, result: Result<Data, Error>) {
        deadlines.removeValue(forKey: id)?.cancel()
        pending.removeValue(forKey: id)?.resume(with: result)
    }

    private func receive(_ data: Data) {
        guard !data.isEmpty else { fail(CodexAgentError.disconnected); return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 10) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                fail(CodexAgentError.invalidResponse); return
            }
            if let method = message["method"] as? String {
                let params = message["params"] as? [String: Any] ?? [:]
                if let requestID = message["id"] {
                    handleClientRequest(method, params: params, requestID: requestID)
                } else if params["threadId"] as? String == threadID {
                    switch method {
                    case "thread/realtime/started": onEvent?(.ready)
                    case "thread/realtime/error", "thread/realtime/closed": fail(CodexAgentError.disconnected)
                    case "turn/started":
                        turnID = (params["turn"] as? [String: Any])?["id"] as? String
                        finalReply = ""
                        onEvent?(.working(true))
                    case "item/completed":
                        if let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                           item["phase"] as? String == "final_answer", let text = item["text"] as? String {
                            finalReply += text
                        }
                    case "turn/completed":
                        turnID = nil
                        let turn = params["turn"] as? [String: Any]
                        if turn?["status"] as? String == "failed" {
                            onEvent?(.reply("这次操作失败了，请重试。"))
                        } else if turn?["status"] as? String != "interrupted" {
                            onEvent?(.reply(finalReply.isEmpty ? "这次没有收到可播报的结果，请重试。" : finalReply))
                        }
                        finalReply = ""
                        onEvent?(.working(false))
                    default: break
                    }
                }
            } else if let requestID = message["id"] as? Int {
                if message["error"] != nil {
                    resolve(requestID, result: .failure(CodexAgentError.requestFailed("RPC \(requestID)")))
                } else {
                    if let result = try? JSONSerialization.data(withJSONObject: message["result"] as? [String: Any] ?? [:]) {
                        resolve(requestID, result: .success(result))
                    } else { resolve(requestID, result: .failure(CodexAgentError.invalidResponse)) }
                }
            }
        }
        if buffer.count > 32 * 1024 * 1024 { fail(CodexAgentError.invalidResponse) }
    }

    private func handleClientRequest(_ method: String, params: [String: Any], requestID: Any) {
        if method == "item/tool/call", params["tool"] as? String == "neo_frontmost_app" {
            let application = NSWorkspace.shared.frontmostApplication
            let info = ["name": application?.localizedName ?? "", "bundleID": application?.bundleIdentifier ?? ""]
            let text = (try? JSONSerialization.data(withJSONObject: info)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            try? send(["id": requestID, "result": [
                "success": application != nil,
                "contentItems": [["type": "inputText", "text": text]],
            ]])
            return
        }
        guard method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval" else {
            try? send(["id": requestID, "error": ["code": -32601, "message": "此交互需要在 Codex 中完成，请向用户说明具体需要的信息或授权。"]])
            return
        }
        let id = generation
        guard let parent = NSApp.windows.first(where: { $0.isVisible }) else {
            try? send(["id": requestID, "result": ["decision": "cancel"]])
            return
        }
        let alert = NSAlert()
        alert.messageText = "Neo 需要操作确认"
        alert.informativeText = [params["reason"] as? String, params["command"] as? String]
            .compactMap { $0 }.joined(separator: "\n\n")
        alert.addButton(withTitle: "允许这一次")
        alert.addButton(withTitle: "取消")
        alerts.append((alert, parent))
        NSApp.activate(ignoringOtherApps: true)
        alert.beginSheetModal(for: parent) { [weak self, weak alert] response in
            guard let self, self.generation == id else { return }
            self.alerts.removeAll { $0.alert === alert }
            try? self.send(["id": requestID, "result": ["decision": response == .alertFirstButtonReturn ? "accept" : "cancel"]])
        }
    }

    private func fail(_ error: Error) {
        let callback = onEvent
        stop()
        callback?(.failed(error))
    }

    func interrupt() {
        guard let threadID else { return }
        if let turnID {
            sequence += 1
            try? send(["id": sequence, "method": "turn/interrupt", "params": ["threadId": threadID, "turnId": turnID]])
        }
        sequence += 1
        try? send(["id": sequence, "method": "thread/backgroundTerminals/clean", "params": ["threadId": threadID]])
    }

    func stop() {
        generation = UUID()
        onEvent = nil
        if let threadID {
            var requests: [(String, [String: Any])] = [("thread/realtime/stop", ["threadId": threadID])]
            if let turnID { requests.insert(("turn/interrupt", ["threadId": threadID, "turnId": turnID]), at: 0) }
            requests.append(("thread/backgroundTerminals/clean", ["threadId": threadID]))
            for (method, params) in requests {
                sequence += 1
                try? send(["id": sequence, "method": method, "params": params])
            }
        }
        threadID = nil
        turnID = nil
        finalReply = ""
        for id in Array(pending.keys) { resolve(id, result: .failure(CancellationError())) }
        for item in alerts { item.parent.endSheet(item.alert.window, returnCode: .cancel) }
        alerts.removeAll()
        let oldProcess = process, oldOutput = output
        oldProcess?.terminationHandler = nil
        oldOutput?.readabilityHandler = nil
        try? input?.close()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        guard let oldProcess else { return }
        Task {
            // EOF lets Codex cancel its thread and stop child tools before forced termination.
            try? await Task.sleep(for: .seconds(2))
            if oldProcess.isRunning { oldProcess.terminate() }
            try? await Task.sleep(for: .seconds(2))
            if oldProcess.isRunning { kill(oldProcess.processIdentifier, SIGKILL) }
            try? oldOutput?.close()
        }
    }
}
