import Foundation

enum LLMRefinementError: LocalizedError {
    case invalidBaseURL
    case missingConfiguration
    case invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "The LLM API Base URL is invalid."
        case .missingConfiguration:
            return "Base URL, API Key, and Model are all required before LLM refinement can run."
        case .invalidResponse:
            return "The LLM service returned an invalid response."
        case .requestFailed(let statusCode, let body):
            if body.isEmpty {
                return "The LLM service returned HTTP \(statusCode)."
            }
            return "The LLM service returned HTTP \(statusCode): \(body)"
        }
    }
}

actor LLMRefinementService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func refine(_ transcript: String, with draft: LLMSettingsDraft) async throws -> String {
        guard draft.isConfigured else {
            throw LLMRefinementError.missingConfiguration
        }

        let refined = try await performChatCompletion(
            using: draft,
            messages: [
                ChatMessage(role: "system", content: Self.refinementPrompt),
                ChatMessage(role: "user", content: transcript),
            ],
            maxTokens: 512
        ).trimmed

        return refined.isEmpty ? transcript : refined
    }

    func testConnection(using draft: LLMSettingsDraft) async throws {
        guard draft.isConfigured else {
            throw LLMRefinementError.missingConfiguration
        }

        let content = try await performChatCompletion(
            using: draft,
            messages: [
                ChatMessage(role: "system", content: "Reply with exactly OK."),
                ChatMessage(role: "user", content: "ping"),
            ],
            maxTokens: 8
        )

        guard content.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().contains("OK") else {
            throw LLMRefinementError.invalidResponse
        }
    }

    private func performChatCompletion(
        using draft: LLMSettingsDraft,
        messages: [ChatMessage],
        maxTokens: Int
    ) async throws -> String {
        guard let url = Self.chatCompletionsURL(from: draft.baseURL) else {
            throw LLMRefinementError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(draft.apiKey.trimmed)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        request.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(
                model: draft.model.trimmed,
                messages: messages,
                temperature: 0,
                maxTokens: maxTokens
            )
        )

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMRefinementError.invalidResponse
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw LLMRefinementError.requestFailed(
                httpResponse.statusCode,
                String(data: data, encoding: .utf8)?.trimmed ?? ""
            )
        }

        let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        guard let choice = decoded.choices.first else {
            throw LLMRefinementError.invalidResponse
        }
        return choice.message.content.text
    }

    private static func chatCompletionsURL(from baseURL: String) -> URL? {
        let trimmed = baseURL.trimmed
        guard var components = URLComponents(string: trimmed) else {
            return nil
        }

        if components.path.hasSuffix("/chat/completions") {
            return components.url
        }

        let normalizedPath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = normalizedPath.isEmpty ? "/chat/completions" : "/\(normalizedPath)/chat/completions"
        return components.url
    }

    private static let refinementPrompt = """
    你是一个极度保守的语音转写纠错器。你的唯一任务是修复非常明显的语音识别错误。

    规则：
    1. 只修复明显错误，例如中文谐音误识别、英文技术术语被误写成中文近音词，或明显缺失/多出的空格。
    2. 不要改写、润色、压缩、扩写、总结或重组句子。
    3. 不要删除任何看起来已经正确的内容。
    4. 如果输入看起来已经正确，必须原样返回。
    5. 只输出最终文本本身，不要输出解释、引号、前后缀或 Markdown。
    """
}

private struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [ChatMessage]
    let temperature: Double
    let maxTokens: Int

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
    }
}

private struct ChatMessage: Codable {
    let role: String
    let content: String
}

private struct ChatCompletionResponse: Decodable {
    let choices: [Choice]

    struct Choice: Decodable {
        let message: Message
    }

    struct Message: Decodable {
        let content: MessageContent
    }
}

private enum MessageContent: Decodable {
    case string(String)
    case parts([Part])

    struct Part: Decodable {
        let text: String?
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .parts(try container.decode([Part].self))
    }

    var text: String {
        switch self {
        case .string(let value):
            value
        case .parts(let parts):
            parts.compactMap(\.text).joined()
        }
    }
}
