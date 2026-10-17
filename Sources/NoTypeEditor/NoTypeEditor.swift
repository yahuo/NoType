import Darwin
import Foundation
import NoTypeEditorCore

@main
struct NoTypeEditorMain {
    private static let maximumBufferBytes = 1_048_576
    private static let triggerLifetimeMilliseconds: Int64 = 5_000
    /// `notype-editor --translate`: the Claude Code mod sends its draft on stdin and reads the
    /// English translation from stdout.
    private static let translateArgument = "--translate"
    private static let claudeCodeClient = "claude-code"

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let environment = ProcessInfo.processInfo.environment

        if arguments == [translateArgument] {
            Darwin.exit(translateStandardInput(environment: environment))
        }

        guard let fileURL = editableFileURL(from: arguments),
              let trigger = loadPendingTrigger(environment: environment)
        else {
            executeFallbackEditor(arguments: arguments, environment: environment)
        }

        guard let terminal = terminalPath(),
              let content = readEditorBuffer(at: fileURL),
              let buffer = NoTypeEditorBuffer.parseTriggeredBuffer(content)
        else {
            writeError("NoType: automatic translation validation failed; the draft was left unchanged.\n")
            return
        }

        if NoTypeEditorBufferPath.isClaude(fileURL) {
            writeError("NoType: translating…\n")
        }

        do {
            let translated = try NoTypeEditorBridgeClient(
                socketURL: bridgeSocketURL(environment: environment)
            ).translate(
                sourceText: buffer.sourceText,
                trigger: trigger,
                processID: getpid(),
                parentProcessID: getppid(),
                terminal: terminal
            )
            try replaceEditorBuffer(
                at: fileURL,
                with: buffer.replacingSource(with: translated)
            )
        } catch {
            // A failed automatic translation must leave the agent's temporary file untouched.
            writeError("NoType: \(error.localizedDescription)\n")
        }
    }

    private static func translateStandardInput(environment: [String: String]) -> Int32 {
        let data = FileHandle.standardInput.readData(ofLength: maximumBufferBytes + 1)
        guard data.count <= maximumBufferBytes,
              let sourceText = String(data: data, encoding: .utf8),
              !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            writeError("NoType: the draft is empty, too large, or not UTF-8.\n")
            return 1
        }

        do {
            let translated = try NoTypeEditorBridgeClient(
                socketURL: bridgeSocketURL(environment: environment)
            ).translate(sourceText: sourceText, client: claudeCodeClient)
            FileHandle.standardOutput.write(Data(translated.utf8))
            return 0
        } catch {
            writeError("NoType: \(error.localizedDescription)\n")
            return 1
        }
    }

    private static func editableFileURL(from arguments: [String]) -> URL? {
        guard let path = arguments.last, !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path)
        guard NoTypeEditorBufferPath.supports(url) else { return nil }

        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= maximumBufferBytes
        else {
            return nil
        }
        return url
    }

    private static func readEditorBuffer(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe),
              data.count <= maximumBufferBytes
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func replaceEditorBuffer(at url: URL, with content: String) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let permissions = attributes[.posixPermissions] as? NSNumber
        try Data(content.utf8).write(to: url, options: .atomic)
        if let permissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions],
                ofItemAtPath: url.path
            )
        }
    }

    private static func loadPendingTrigger(
        environment: [String: String]
    ) -> NoTypeEditorPendingTrigger? {
        let url = pendingTriggerURL(environment: environment)
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
              (metadata.st_mode & S_IFMT) == S_IFREG,
              (metadata.st_mode & 0o077) == 0,
              metadata.st_uid == geteuid(),
              metadata.st_size >= 0,
              metadata.st_size <= 4_096,
              let data = try? Data(contentsOf: url),
              data.count <= 4_096,
              let trigger = try? JSONDecoder().decode(NoTypeEditorPendingTrigger.self, from: data),
              trigger.version == 1,
              UUID(uuidString: trigger.token) != nil,
              trigger.targetProcessID > 0,
              !trigger.targetBundleIdentifier.isEmpty
        else {
            return nil
        }

        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let age = now - trigger.createdAtMilliseconds
        guard age >= -1_000, age <= triggerLifetimeMilliseconds else {
            return nil
        }
        return trigger
    }

    private static func pendingTriggerURL(environment: [String: String]) -> URL {
        if let override = environment["NOTYPE_EDITOR_TRIGGER_FILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return runtimeDirectory().appendingPathComponent("editor-trigger.json")
    }

    private static func bridgeSocketURL(environment: [String: String]) -> URL {
        if let override = environment["NOTYPE_BRIDGE_SOCKET"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return runtimeDirectory().appendingPathComponent("bridge.sock")
    }

    private static func runtimeDirectory() -> URL {
        userTemporaryDirectory()
            .appendingPathComponent("com.opensource.notype", isDirectory: true)
    }

    /// A terminal can inherit a stale TMPDIR; ask for the per-user directory NoType itself uses.
    private static func userTemporaryDirectory() -> URL {
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        if length > 0 {
            var buffer = [CChar](repeating: 0, count: length)
            if confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, length) > 0 {
                let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                let path = String(decoding: bytes, as: UTF8.self)
                if path.hasPrefix("/") {
                    return URL(fileURLWithPath: path, isDirectory: true)
                }
            }
        }
        return FileManager.default.temporaryDirectory
    }

    private static func terminalPath() -> String? {
        for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
            guard let value = ttyname(descriptor) else { continue }
            let path = String(cString: value)
            guard path.hasPrefix("/dev/") else { continue }

            var metadata = stat()
            guard stat(path, &metadata) == 0, metadata.st_uid == geteuid() else {
                continue
            }
            return path
        }
        return nil
    }

    private static func executeFallbackEditor(
        arguments: [String],
        environment: [String: String]
    ) -> Never {
        let candidates = [
            environment["NOTYPE_REAL_VISUAL"],
            environment["NOTYPE_REAL_EDITOR"],
            environment["NOTYPE_EDITOR_FALLBACK"],
        ]
        var command = candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && !isEditorProxyCommand($0) }
            ?? "/usr/bin/vi"

        if command.isEmpty || command.contains("\n") || command.contains("\r") {
            command = "/usr/bin/vi"
        }

        let shellArguments = [
            "/bin/sh",
            "-c",
            "exec \(command) \"$@\"",
            "notype-editor",
        ] + arguments
        let pointers = shellArguments.map { strdup($0) } + [nil]
        defer {
            for pointer in pointers where pointer != nil {
                free(pointer)
            }
        }

        execv("/bin/sh", pointers)
        writeError("NoType: unable to launch the fallback editor: \(String(cString: strerror(errno)))\n")
        Darwin.exit(127)
    }

    private static func isEditorProxyCommand(_ command: String) -> Bool {
        command.range(
            of: #"(?:^|[/\s'\"])notype-?editor(?:$|[\s'\"])"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }
}
