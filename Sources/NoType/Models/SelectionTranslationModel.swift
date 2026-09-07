import AppKit
import Foundation

@MainActor
final class SelectionTranslationModel: ObservableObject {
    @Published private(set) var sourceText = ""
    @Published private(set) var translatedText = ""
    @Published private(set) var errorMessage: String?
    @Published private(set) var isLoading = false
    @Published private(set) var hasCopied = false

    private let readSelection: @MainActor () async throws -> String?
    private let translate: @MainActor (String, @escaping @Sendable (String) -> Void) async throws -> String
    private var task: Task<Void, Never>?
    private var requestID = UUID()
    private var isReadingSelection = false

    init(
        readSelection: @escaping @MainActor () async throws -> String?,
        translate: @escaping @MainActor (String, @escaping @Sendable (String) -> Void) async throws -> String
    ) {
        self.readSelection = readSelection
        self.translate = translate
    }

    @discardableResult
    func start(onPresent: @escaping () -> Void) -> Task<Void, Never> {
        // Copy fallback temporarily owns the clipboard; never overlap two captures.
        if isReadingSelection, let task { return task }
        cancel()
        let activeRequestID = requestID
        sourceText = ""
        translatedText = ""
        errorMessage = nil
        hasCopied = false
        isLoading = true
        isReadingSelection = true

        let task = Task { @MainActor in
            guard requestID == activeRequestID, !Task.isCancelled else {
                isReadingSelection = false
                return
            }
            do {
                let selection = try await captureSelection()
                guard requestID == activeRequestID, !Task.isCancelled else { return }
                sourceText = selection ?? ""
                // Present only after capture so the panel cannot become the copy target.
                onPresent()
                guard !sourceText.trimmed.isEmpty else {
                    errorMessage = "未读取到选中文字。请先选中一段文本，再按 Option + Control + Space。"
                    isLoading = false
                    return
                }

                let result = try await translate(sourceText) { [weak self] partial in
                    Task { @MainActor in
                        guard let self, self.requestID == activeRequestID, self.isLoading else { return }
                        self.translatedText = partial
                    }
                }
                guard requestID == activeRequestID, !Task.isCancelled else { return }
                guard !result.trimmed.isEmpty else { throw AIRewriteError.invalidResponse }
                translatedText = result.trimmed
                isLoading = false
            } catch {
                guard requestID == activeRequestID, !Task.isCancelled else { return }
                translatedText = ""
                errorMessage = error.localizedDescription
                isLoading = false
                onPresent()
            }
        }
        self.task = task
        return task
    }

    func cancel() {
        requestID = UUID()
        task?.cancel()
        isLoading = false
    }

    private func captureSelection() async throws -> String? {
        defer { isReadingSelection = false }
        return try await readSelection()
    }

    func copyTranslation(to pasteboard: NSPasteboard = .general) {
        guard !isLoading, errorMessage == nil, !translatedText.isEmpty else { return }
        pasteboard.clearContents()
        hasCopied = pasteboard.setString(translatedText, forType: .string)
    }
}
