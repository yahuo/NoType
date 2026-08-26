import Carbon
import CoreGraphics
import Darwin
import Foundation

struct AgentEditorPendingTrigger: Codable, Equatable {
    static let version = 1
    static let lifetimeMilliseconds: Int64 = 5_000

    let version: Int
    let token: String
    let createdAtMilliseconds: Int64
    let targetProcessID: Int32
    let targetBundleIdentifier: String

    init(
        token: String = UUID().uuidString,
        createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000),
        targetProcessID: Int32,
        targetBundleIdentifier: String
    ) {
        version = Self.version
        self.token = token
        self.createdAtMilliseconds = createdAtMilliseconds
        self.targetProcessID = targetProcessID
        self.targetBundleIdentifier = targetBundleIdentifier
    }

    nonisolated func accepts(token candidate: String, nowMilliseconds: Int64) -> Bool {
        let age = nowMilliseconds - createdAtMilliseconds
        return version == Self.version
            && candidate == token
            && UUID(uuidString: candidate) != nil
            && age >= -1_000
            && age <= Self.lifetimeMilliseconds
    }
}

enum AgentEditorIntegrationServiceError: LocalizedError {
    case unsupportedTerminal(String)
    case targetChanged
    case unableToSecureTrigger
    case shortcutSynthesisFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedTerminal(let name):
            "NoType agent editor integration does not support \(name)."
        case .targetChanged:
            "The focused terminal changed before NoType could open the agent editor."
        case .unableToSecureTrigger:
            "Unable to create a private NoType agent editor trigger."
        case .shortcutSynthesisFailed:
            "Unable to synthesize the agent external-editor shortcut."
        }
    }
}

@MainActor
final class AgentEditorIntegrationService {
    let triggerURL: URL

    private let runtimeDirectory: URL
    private var pendingTrigger: AgentEditorPendingTrigger?
    private var expirationTask: Task<Void, Never>?

    init(runtimeDirectory: URL = NoTypeBridgeService.defaultRuntimeDirectory) {
        self.runtimeDirectory = runtimeDirectory
        triggerURL = runtimeDirectory.appendingPathComponent(
            "editor-trigger.json",
            isDirectory: false
        )
    }

    func triggerExternalEditor(for target: DictationTargetContext) throws {
        guard Self.supportsTerminal(target) else {
            throw AgentEditorIntegrationServiceError.unsupportedTerminal(target.localizedName)
        }
        guard target.processIdentifier > 0,
              DictationTargetContext.currentFrontmost().processIdentifier == target.processIdentifier
        else {
            throw AgentEditorIntegrationServiceError.targetChanged
        }

        clearPendingTrigger()
        let trigger = AgentEditorPendingTrigger(
            targetProcessID: target.processIdentifier,
            targetBundleIdentifier: target.bundleIdentifier
        )
        try persist(trigger)
        pendingTrigger = trigger
        scheduleExpiration(for: trigger.token)

        guard Self.postControlG(to: target.processIdentifier) else {
            clearPendingTrigger()
            throw AgentEditorIntegrationServiceError.shortcutSynthesisFailed
        }
    }

    func consumePendingTrigger(
        token: String,
        processID: Int32,
        parentProcessID: Int32,
        terminal: String,
        nowMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1_000)
    ) -> Bool {
        guard let pendingTrigger,
              pendingTrigger.accepts(token: token, nowMilliseconds: nowMilliseconds)
        else {
            return false
        }
        defer { clearPendingTrigger() }

        guard processID > 1,
              parentProcessID > 1,
              Self.processExists(processID),
              Self.processExists(parentProcessID),
              Self.isPrivateTerminal(terminal)
        else {
            return false
        }

        let frontmost = DictationTargetContext.currentFrontmost()
        return frontmost.processIdentifier == pendingTrigger.targetProcessID
            && frontmost.bundleIdentifier == pendingTrigger.targetBundleIdentifier
    }

    func shutdown() {
        clearPendingTrigger()
    }

    nonisolated static func supportsTerminal(_ target: DictationTargetContext) -> Bool {
        if supportedTerminalBundleIdentifiers.contains(target.bundleIdentifier) {
            return true
        }

        let name = target.localizedName.lowercased()
        return ["ghostty", "iterm", "terminal", "herdr"].contains { name.contains($0) }
    }

    private func persist(_ trigger: AgentEditorPendingTrigger) throws {
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)]
            )
            guard chmod(runtimeDirectory.path, S_IRWXU) == 0 else {
                throw AgentEditorIntegrationServiceError.unableToSecureTrigger
            }

            let data = try JSONEncoder().encode(trigger)
            try data.write(to: triggerURL, options: .atomic)
            guard chmod(triggerURL.path, S_IRUSR | S_IWUSR) == 0 else {
                throw AgentEditorIntegrationServiceError.unableToSecureTrigger
            }
        } catch let error as AgentEditorIntegrationServiceError {
            try? FileManager.default.removeItem(at: triggerURL)
            throw error
        } catch {
            try? FileManager.default.removeItem(at: triggerURL)
            throw AgentEditorIntegrationServiceError.unableToSecureTrigger
        }
    }

    private func scheduleExpiration(for token: String) {
        expirationTask?.cancel()
        expirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                for: .milliseconds(AgentEditorPendingTrigger.lifetimeMilliseconds)
            )
            guard !Task.isCancelled, self?.pendingTrigger?.token == token else { return }
            self?.clearPendingTrigger()
        }
    }

    private func clearPendingTrigger() {
        expirationTask?.cancel()
        expirationTask = nil
        pendingTrigger = nil
        try? FileManager.default.removeItem(at: triggerURL)
    }

    private nonisolated static func postControlG(to processIdentifier: Int32) -> Bool {
        guard processIdentifier > 0,
              let keyDown = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: CGKeyCode(kVK_ANSI_G),
                  keyDown: true
              ), let keyUp = CGEvent(
                  keyboardEventSource: nil,
                  virtualKey: CGKeyCode(kVK_ANSI_G),
                  keyDown: false
              )
        else {
            return false
        }

        keyDown.flags = .maskControl
        keyUp.flags = .maskControl
        keyDown.postToPid(pid_t(processIdentifier))
        keyUp.postToPid(pid_t(processIdentifier))
        return true
    }

    private nonisolated static func processExists(_ processID: Int32) -> Bool {
        if kill(processID, 0) == 0 { return true }
        return errno == EPERM
    }

    private nonisolated static func isPrivateTerminal(_ path: String) -> Bool {
        guard path.hasPrefix("/dev/") else { return false }

        var metadata = stat()
        guard lstat(path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFCHR,
              metadata.st_uid == geteuid()
        else {
            return false
        }
        return true
    }

    private nonisolated static let supportedTerminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
    ]
}
