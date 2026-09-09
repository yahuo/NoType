import Foundation
import Testing
@testable import NoType

@MainActor
private final class AgentFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoTypeAgentTests-\(UUID())")
    var process: Process?
    var persistent = false
    var holdInitialize = false
    var finishTurn = false
    var turnStatus = "completed"

    func makeProcess() throws -> Process {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", #"""
        import json,sys
        def send(value):
            # Write separate chunks so the client must frame JSONL across pipe reads.
            line=json.dumps(value)+'\n'
            sys.stdout.write(line[:5]);sys.stdout.flush()
            sys.stdout.write(line[5:]);sys.stdout.flush()
        for line in sys.stdin:
            value=json.loads(line)
            with open('requests.jsonl','a') as f:f.write(line)
            method=value.get('method')
            if method is None:
                if value.get('id')=='frontmost' and sys.argv[3]=='finish':
                    for phase,text in [('commentary','我来看看'),('final_answer','结果是35')]:
                        send({'method':'item/completed','params':{'threadId':'neo-test-thread','item':{'type':'agentMessage','phase':phase,'text':text}}})
                    send({'method':'turn/completed','params':{'threadId':'neo-test-thread','turn':{'id':'turn-1','status':sys.argv[4]}}})
                continue
            if 'id' not in value:continue
            if method=='initialize' and sys.argv[2]=='hold':continue
            result={}
            if method=='thread/start':
                result={'thread':{'id':'neo-test-thread','ephemeral':sys.argv[1]!='persistent','path':None}}
            send({'id':value['id'],'result':result})
            if method=='thread/realtime/start':
                send({'method':'thread/realtime/started','params':{'threadId':'unrelated-thread'}})
                send({'method':'thread/realtime/started','params':{'threadId':'neo-test-thread'}})
                send({'method':'turn/started','params':{'threadId':'neo-test-thread','turn':{'id':'turn-1'}}})
                send({'id':'frontmost','method':'item/tool/call','params':{'threadId':'neo-test-thread','tool':'neo_frontmost_app','arguments':{},'turnId':'turn-1','callId':'call-1'}})
            if method=='thread/realtime/stop':
                send({'method':'turn/completed','params':{'threadId':'neo-test-thread'}})
        """#, persistent ? "persistent" : "temporary", holdInitialize ? "hold" : "reply", finishTurn ? "finish" : "hold", turnStatus]
        self.process = process
        return process
    }

    func requests() -> [[String: Any]] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("requests.jsonl"), encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(predicate(), "Timed out waiting for fixture")
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }
}

@MainActor @Test func neoAgentUsesTemporaryThreadAndStopsExecutingWork() async throws {
    let fixture = AgentFixture()
    let agent = CodexAgentService(workspace: fixture.directory, processFactory: fixture.makeProcess)
    defer { agent.stop(); fixture.clean() }
    var events: [String] = []
    let thread = try await agent.start {
        switch $0 {
        case .ready: events.append("ready")
        case .working(let working): events.append("working=\(working)")
        case .reply(let text): events.append("reply=\(text)")
        case .failed: events.append("failed")
        }
    }
    #expect(thread == "neo-test-thread")
    try await agent.attach(callID: "rtc_test")
    try await fixture.waitUntil { events.contains("working=true") }
    #expect(events == ["ready", "working=true"])
    let start = try #require(fixture.requests().first { $0["method"] as? String == "thread/start" })
    let parameters = try #require(start["params"] as? [String: Any])
    #expect(parameters["ephemeral"] as? Bool == true)
    #expect(parameters["selectedCapabilityRoots"] == nil)
    #expect(parameters["environments"] == nil)
    #expect(parameters["sandbox"] == nil) // Keep the user's Codex permission policy.
    #expect(parameters["model"] as? String == "gpt-5.6-luna")
    let config = try #require(parameters["config"] as? [String: String])
    #expect(config["model_reasoning_effort"] == "medium")
    #expect(config["web_search"] == "live")
    let attach = try #require(fixture.requests().first { $0["method"] as? String == "thread/realtime/start" })
    let realtime = try #require(attach["params"] as? [String: Any])
    #expect(realtime["clientManagedHandoffs"] as? Bool != true)
    #expect(realtime["codexResponseHandoffMode"] as? String == "bemTags")
    try await fixture.waitUntil { fixture.requests().contains { $0["id"] as? String == "frontmost" } }
    let frontmostReply = try #require(fixture.requests().first { $0["id"] as? String == "frontmost" })
    let result = try #require(frontmostReply["result"] as? [String: Any])
    let contents = try #require(result["contentItems"] as? [[String: String]])
    #expect(contents.first?["type"] == "inputText")
    let app = try #require(try JSONSerialization.jsonObject(with: Data((contents.first?["text"] ?? "").utf8)) as? [String: String])
    #expect(app["bundleID"] != nil)
    #expect(app["name"] != nil)
    agent.stop()
    try await fixture.waitUntil { fixture.process?.isRunning == false }
    let methods = fixture.requests().compactMap { $0["method"] as? String }
    #expect(methods.contains("turn/interrupt"))
    #expect(methods.contains("thread/realtime/stop"))
    #expect(methods.contains("thread/backgroundTerminals/clean"))
    #expect(events == ["ready", "working=true"], "A stopped process must not deliver late callbacks")
}

@MainActor @Test func neoAgentLeavesProgressAndResultsToAutomaticHandoffs() async throws {
    let fixture = AgentFixture()
    fixture.finishTurn = true
    let agent = CodexAgentService(workspace: fixture.directory, processFactory: fixture.makeProcess)
    defer { agent.stop(); fixture.clean() }
    var replies: [String] = []
    var completed = false
    _ = try await agent.start {
        if case .reply(let text) = $0 { replies.append(text) }
        if case .working(false) = $0 { completed = true }
    }
    try await agent.attach(callID: "rtc_test")
    try await fixture.waitUntil { completed }
    #expect(replies.isEmpty, "Automatic handoffs must not replay the final answer a second time")
    #expect(!fixture.requests().contains { $0["method"] as? String == "thread/realtime/appendSpeech" })
    agent.stop()
    try await fixture.waitUntil { fixture.process?.isRunning == false }
}

@MainActor @Test(arguments: ["failed", "interrupted"])
func neoAgentReportsFailureWithoutReplayingAnInterruptedResult(status: String) async throws {
    let fixture = AgentFixture()
    fixture.finishTurn = true
    fixture.turnStatus = status
    let agent = CodexAgentService(workspace: fixture.directory, processFactory: fixture.makeProcess)
    defer { agent.stop(); fixture.clean() }
    var replies: [String] = []
    var completed = false
    _ = try await agent.start {
        if case .reply(let text) = $0 { replies.append(text) }
        if case .working(false) = $0 { completed = true }
    }
    try await agent.attach(callID: "rtc_test")
    try await fixture.waitUntil { completed }
    #expect(replies == (status == "failed" ? ["这次操作失败了，请重试。"] : []))
    if let reply = replies.first {
        try await agent.speak(reply)
        let speech = try #require(fixture.requests().first { $0["method"] as? String == "thread/realtime/appendSpeech" })
        #expect((speech["params"] as? [String: Any])?["text"] as? String == reply)
    }
    agent.stop()
    try await fixture.waitUntil { fixture.process?.isRunning == false }
}

@MainActor @Test func neoAgentRefusesPersistentThread() async throws {
    let fixture = AgentFixture()
    fixture.persistent = true
    let agent = CodexAgentService(workspace: fixture.directory, processFactory: fixture.makeProcess)
    defer { agent.stop(); fixture.clean() }
    do {
        _ = try await agent.start { _ in }
        Issue.record("Persistent thread should have been rejected")
    } catch CodexAgentError.persistentThread { }
    try await fixture.waitUntil { fixture.process?.isRunning == false }
    #expect(!fixture.requests().contains { $0["method"] as? String == "thread/realtime/start" })
}

@MainActor @Test func neoAgentCancellationDuringStartupStopsTheProcess() async throws {
    let fixture = AgentFixture()
    fixture.holdInitialize = true
    let agent = CodexAgentService(workspace: fixture.directory, processFactory: fixture.makeProcess)
    defer { agent.stop(); fixture.clean() }
    let start = Task { try await agent.start { _ in } }
    try await fixture.waitUntil { !fixture.requests().isEmpty }
    start.cancel()
    do {
        _ = try await start.value
        Issue.record("Cancelled startup should not create a thread")
    } catch is CancellationError { }
    try await fixture.waitUntil { fixture.process?.isRunning == false }
    #expect(!fixture.requests().contains { $0["method"] as? String == "thread/start" })
}
