@preconcurrency import WebKit
import Foundation

enum NeoRealtimeEvent {
    case mediaViewReady
    case ready
    case working(Bool)
    case level(Double, speaking: Bool)
    case endRequested
    case playbackEnded
    case failed(Error)
}

@MainActor
protocol NeoRealtimeCalling: AnyObject {
    var mediaView: WKWebView? { get }
    func start(onEvent: @escaping (NeoRealtimeEvent) -> Void) async throws
    func greet()
    func finishAfterReply()
    func stop()
}

/// WebKit supplies WebRTC, Opus, echo cancellation and audio playback without a bundled SDK.
/// OAuth stays in Swift; the private, nonpersistent page only receives SDP and media events.
@MainActor
final class CodexRealtimeService: NSObject, NeoRealtimeCalling, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
    private var webView: WKWebView?
    private var loaded: CheckedContinuation<Void, Error>?
    private var session: URLSession?
    private var onEvent: ((NeoRealtimeEvent) -> Void)?
    private var generation = UUID()
    private let agent: NeoAgentSession
    private var mediaReady = false
    private var agentReady = false
    private var finishing = false
    private var replyTask: Task<Void, Never>?

    init(agent: NeoAgentSession = CodexAgentService()) {
        self.agent = agent
        super.init()
    }

    var mediaView: WKWebView? { webView }

    static func makeRequest(sdp: String, credentials: CodexOAuthCredentials, threadID: String) throws -> URLRequest {
        guard !credentials.isExpired else { throw AIRewriteError.codexAuthExpired }
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/realtime/calls?intent=quicksilver&architecture=avas")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(credentials.chatGPTAccountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("quicksilver=v2", forHTTPHeaderField: "OpenAI-Alpha")
        request.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        request.setValue("26.901.51231", forHTTPHeaderField: "X-OpenAI-Codex-Client-Version")
        request.setValue("Codex Desktop/26.901.51231 (Mac OS; arm64)", forHTTPHeaderField: "User-Agent")
        request.setValue(threadID, forHTTPHeaderField: "Thread-Id")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sdp": sdp,
            "session": [
                "model": "gpt-live-1-codex",
                "instructions": """
                You are Neo, a concise Chinese voice assistant connected to a capable Codex backend.
                Immediately delegate every task, action, current-information question, web search, screen reading, or app-control request to the backend. Only answer directly for simple conversation.
                The backend can access the user's existing local Codex memories. Always delegate questions or discussions about the user's preferences, projects, past conversations, decisions, or remembered context. Never invent personal memories or claim they are unavailable before checking with the backend.
                You cannot see the screen or execute actions yourself. After delegating, you may briefly acknowledge the request, then wait silently for the backend result. Never guess screen content, numbers, search results, or whether an action succeeded. A progress update such as 'I will check' is not a result.
                Backend messages are marked [BACKEND] and may contain [COMMENTARY] progress or [FINAL] results. Report only facts actually returned by the backend, in concise Chinese. Do not add unsupported details or read out these internal tags.
                Immediately delegate user corrections and new instructions to steer ongoing work. When the user says 结束会话 or 结束对话, say a short Chinese goodbye directly without delegation.
                """,
                "audio": ["output": ["voice": "juniper"]],
                "delegation": ["type": "client"],
            ],
        ])
        return request
    }

    nonisolated static func isEndCommand(_ text: String) -> Bool {
        let normalized = text.lowercased().filter { $0.isLetter }
        return ["结束会话", "结束对话", "结束聊天", "goodbyeneo", "再见neo"].contains(normalized)
    }

    func start(onEvent: @escaping (NeoRealtimeEvent) -> Void) async throws {
        stop()
        let id = generation
        self.onEvent = onEvent
        let credentials = try CodexAuthStore().loadCredentials()
        guard !credentials.isExpired else { throw AIRewriteError.codexAuthExpired }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.userContentController.add(self, name: "neo")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.underPageBackgroundColor = .black
        web.navigationDelegate = self
        web.uiDelegate = self
        webView = web
        onEvent(.mediaViewReady)
        try await withCheckedThrowingContinuation { continuation in
            loaded = continuation
            web.loadHTMLString(Self.page, baseURL: URL(string: "https://notype.local"))
        }
        try checkActive(id)
        let offer = try await web.callAsyncJavaScript("return await neo.offer();", arguments: [:], in: nil, contentWorld: .page)
        try checkActive(id)
        guard let sdp = offer as? String, sdp.hasPrefix("v=0") else { throw NeoVoiceError.invalidResponse }
        let threadID = try await agent.start { [weak self] event in
            guard let self, self.generation == id else { return }
            switch event {
            case .ready:
                self.agentReady = true
                self.emitReadyIfConnected()
            case .working(let working):
                if self.finishing { if working { self.agent.interrupt() } }
                else {
                    if working {
                        self.replyTask?.cancel()
                        self.webView?.evaluateJavaScript("neo.blockReply();", completionHandler: nil)
                    }
                    self.onEvent?(.working(working))
                }
            case .reply(let text):
                self.speakReply(text, id: id)
            case .failed(let error): self.onEvent?(.failed(error))
            }
        }
        try checkActive(id)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: RealtimeRedirectDelegate(), delegateQueue: nil)
        self.session = session
        let (data, response) = try await session.data(for: Self.makeRequest(sdp: sdp, credentials: credentials, threadID: threadID))
        try checkActive(id)
        guard let response = response as? HTTPURLResponse else { throw NeoVoiceError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else { throw NeoVoiceError.connectionFailed(response.statusCode) }
        guard let answer = String(data: data, encoding: .utf8), answer.hasPrefix("v=0") else { throw NeoVoiceError.invalidResponse }
        guard let location = response.value(forHTTPHeaderField: "Location"),
              let callID = URL(string: location)?.lastPathComponent,
              callID.range(of: #"^rtc_[A-Za-z0-9_-]+$"#, options: .regularExpression) != nil else { throw NeoVoiceError.invalidResponse }
        _ = try await web.callAsyncJavaScript("await neo.answer(sdp);", arguments: ["sdp": answer], in: nil, contentWorld: .page)
        try checkActive(id)
        try await agent.attach(callID: callID)
        try checkActive(id)
    }

    private func emitReadyIfConnected() {
        if mediaReady && agentReady && !finishing { onEvent?(.ready) }
    }

    private func checkActive(_ id: UUID) throws {
        try Task.checkCancellation()
        guard generation == id else { throw CancellationError() }
    }

    private func speakReply(_ text: String, id: UUID) {
        guard !finishing, let web = webView else { return }
        replyTask?.cancel()
        replyTask = Task { [weak self] in
            guard let self else { return }
            do {
                try self.checkActive(id)
                guard !self.finishing else { return }
                // Drain any speculative speech while muted, then explicitly speak the actual result.
                let ready = try await web.callAsyncJavaScript("return await neo.prepareReply();", arguments: [:], in: nil, contentWorld: .page)
                try self.checkActive(id)
                guard !self.finishing, ready as? Bool == true else { return }
                try await self.agent.speak(text)
            } catch {
                if self.generation == id, !Task.isCancelled, !self.finishing { self.onEvent?(.failed(error)) }
            }
        }
    }

    func finishAfterReply() {
        finishing = true
        replyTask?.cancel()
        agent.interrupt()
        guard let web = webView else { return }
        web.evaluateJavaScript("neo.finishAfterReply();") { [weak self, weak web] _, error in
            guard let self, let web, self.webView === web, error != nil else { return }
            self.onEvent?(.failed(NeoVoiceError.connectionLost))
        }
    }

    func greet() {
        guard let web = webView else { return }
        web.evaluateJavaScript("neo.greet();") { [weak self, weak web] _, error in
            guard let self, let web, self.webView === web, error != nil else { return }
            self.onEvent?(.failed(NeoVoiceError.connectionLost))
        }
    }

    func stop() {
        generation = UUID()
        onEvent = nil
        mediaReady = false
        agentReady = false
        finishing = false
        replyTask?.cancel()
        replyTask = nil
        agent.stop()
        loaded?.resume(throwing: CancellationError())
        loaded = nil
        session?.invalidateAndCancel()
        session = nil
        if let web = webView {
            web.configuration.userContentController.removeScriptMessageHandler(forName: "neo")
            web.navigationDelegate = nil
            web.uiDelegate = nil
            web.evaluateJavaScript("if (typeof neo !== 'undefined') neo.stop();") { _, _ in
                web.loadHTMLString("", baseURL: nil)
            }
        }
        webView = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        loaded?.resume()
        loaded = nil
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        loaded?.resume(throwing: error)
        loaded = nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        onEvent?(.failed(NeoVoiceError.connectionLost))
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void) {
        decisionHandler(webView === self.webView && origin.host == "notype.local" && frame.isMainFrame && type == .microphone ? .grant : .deny)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.webView === webView, message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any], let kind = body["type"] as? String else { return }
        switch kind {
        case "ready":
            mediaReady = true
            emitReadyIfConnected()
        case "level": onEvent?(.level(body["level"] as? Double ?? 0, speaking: body["speaking"] as? Bool ?? false))
        case "userTurn":
            if let text = body["text"] as? String, Self.isEndCommand(text) { onEvent?(.endRequested) }
        case "playbackEnded": onEvent?(.playbackEnded)
        case "error": onEvent?(.failed(NeoVoiceError.connectionLost))
        default: break
        }
    }

    static let page = #"""
    <!doctype html><meta charset="utf-8">
    <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; media-src blob:; connect-src 'none'">
    <script>
    const neo = (() => {
      let pc, dc, mic, remote, context, timer, closed = false;
      const post = (type, extra = {}) => { if (!closed) window.webkit.messageHandlers.neo.postMessage({type, ...extra}); };
      const fail = () => post('error');
      let inputMeter, outputMeter;
      let userTurn, assistantTurn, ending, lastOutputAt = -Infinity;
      let greeted = false;
      function greet() {
        if (closed || greeted || dc?.readyState !== 'open') return;
        greeted = true;
        dc.send(JSON.stringify({type: 'session.context.append', channel: 'speakable',
          content: [{type: 'input_text', text: '我在，请说。'}]}));
      }
      let blocked = false, blockedAt = -Infinity, pendingReply;
      function blockReply() {
        if (closed || ending) return;
        pendingReply?.resolve(false); pendingReply = null;
        if (!blocked) blockedAt = performance.now();
        blocked = true;
        if (remote) remote.muted = true;
      }
      function prepareReply() {
        if (closed || ending) return Promise.resolve(false);
        pendingReply?.resolve(false);
        return new Promise((resolve, reject) => { pendingReply = {resolve, reject, startedAt: performance.now()}; });
      }
      function checkReplyReady(now) {
        if (!pendingReply) return;
        const speechDone = lastOutputAt < blockedAt || assistantTurn?.at >= blockedAt;
        if (speechDone && now - lastOutputAt >= 800) {
          blocked = false;
          if (remote) remote.muted = false;
          pendingReply.resolve(true); pendingReply = null;
        } else if (now - pendingReply.startedAt >= 10000) {
          pendingReply.reject(new Error('reply playback stalled')); pendingReply = null;
        }
      }
      function finishAfterReply() {
        if (closed || ending) return;
        pendingReply?.resolve(false); pendingReply = null;
        blocked = false;
        if (remote) remote.muted = false;
        ending = {startedAt: performance.now(), userTurn, completed: false};
      }
      function checkPlaybackEnd(now, output) {
        if (output > 0.003) lastOutputAt = now;
        if (!ending || ending.completed) return;
        const replyDone = assistantTurn && (Number.isFinite(assistantTurn.end) && Number.isFinite(ending.userTurn?.end)
          ? assistantTurn.end > ending.userTurn.end
          : assistantTurn.at >= (ending.userTurn?.at ?? ending.startedAt));
        // turn.done may arrive before the last audio reaches the output device.
        const drained = replyDone && now - Math.max(ending.startedAt, assistantTurn.at, lastOutputAt) >= 800;
        const noReply = now - Math.max(ending.startedAt, lastOutputAt) >= 10000;
        if (drained || noReply) {
          ending.completed = true;
          post('playbackEnded');
        }
      }
      function meter(stream) {
        const analyser = context.createAnalyser(); analyser.fftSize = 256;
        context.createMediaStreamSource(stream).connect(analyser);
        return analyser;
      }
      function level(analyser) {
        if (!analyser) return 0;
        const values = new Float32Array(analyser.fftSize); analyser.getFloatTimeDomainData(values);
        return Math.sqrt(values.reduce((sum, x) => sum + x * x, 0) / values.length);
      }
      async function offer() {
        mic = await navigator.mediaDevices.getUserMedia({audio: {echoCancellation: true, noiseSuppression: true, autoGainControl: true}, video: false});
        if (closed) { mic.getTracks().forEach(t => t.stop()); throw new Error('closed'); }
        context = new AudioContext(); await context.resume(); inputMeter = meter(mic);
        pc = new RTCPeerConnection({iceServers: []});
        mic.getTracks().forEach(t => pc.addTrack(t, mic));
        pc.onconnectionstatechange = () => { if (['failed', 'disconnected'].includes(pc.connectionState)) fail(); };
        pc.ontrack = async event => {
          if (closed) return;
          const stream = event.streams[0] || new MediaStream([event.track]);
          outputMeter = meter(stream);
          remote = new Audio(); remote.srcObject = stream; remote.autoplay = true; remote.muted = blocked;
          try { await remote.play(); } catch { fail(); }
        };
        dc = pc.createDataChannel('oai-events');
        dc.onopen = () => post('ready'); dc.onerror = fail;
        dc.onclose = () => { if (!closed) fail(); };
        dc.onmessage = event => {
          if (closed) return;
          let value; try { value = JSON.parse(event.data); } catch { return; }
          if (value.type === 'error') fail();
          if (value.type === 'delegation.created') blockReply();
          if (value.type === 'turn.done') {
            const turn = {end: value.turn?.end_ms, at: performance.now()};
            if (value.turn?.role === 'assistant') assistantTurn = turn;
            if (value.turn?.role === 'user') {
              userTurn = turn;
              post('userTurn', {text: value.turn.transcript || ''});
            }
          }
          // Codex's sideband handles delegation and returns actual tool results to this call.
        };
        timer = setInterval(() => {
          const input = level(inputMeter), output = level(outputMeter);
          checkPlaybackEnd(performance.now(), output);
          checkReplyReady(performance.now());
          const audible = blocked ? 0 : output;
          post('level', {level: Math.min(1, Math.max(input, audible) * 4), speaking: audible > 0.015});
        }, 100);
        await pc.setLocalDescription(await pc.createOffer());
        if (pc.iceGatheringState !== 'complete') await new Promise(resolve => {
          const timeout = setTimeout(resolve, 2000);
          pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') { clearTimeout(timeout); resolve(); } });
        });
        if (closed) throw new Error('closed');
        return pc.localDescription.sdp;
      }
      async function answer(sdp) { if (!closed) await pc.setRemoteDescription({type: 'answer', sdp}); }
      function stop() {
        closed = true; clearInterval(timer);
        pendingReply?.resolve(false); pendingReply = null;
        mic?.getTracks().forEach(t => t.stop());
        if (remote) { remote.pause(); remote.srcObject = null; }
        dc?.close(); pc?.close(); context?.close();
        inputMeter = outputMeter = mic = remote = null;
      }
      return {offer, answer, greet, blockReply, prepareReply, finishAfterReply, stop};
    })();
    </script>
    """#
}

private final class RealtimeRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
