import Foundation

enum DictationLanguage: String, Codable, CaseIterable, Identifiable {
    case zhCN = "zh-CN"
    case enUS = "en-US"
    case zhTW = "zh-TW"
    case jaJP = "ja-JP"
    case koKR = "ko-KR"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhCN:
            "简体中文"
        case .enUS:
            "English"
        case .zhTW:
            "繁體中文"
        case .jaJP:
            "日本語"
        case .koKR:
            "한국어"
        }
    }

    var locale: Locale {
        Locale(identifier: rawValue)
    }

    var usesChineseCopy: Bool {
        switch self {
        case .zhCN, .zhTW:
            true
        case .enUS, .jaJP, .koKR:
            false
        }
    }
}

enum HotkeyOption: String, Codable, CaseIterable, Identifiable {
    case optionSpace
    case controlSpace
    case commandShiftSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .optionSpace:
            "Option + Space"
        case .controlSpace:
            "Control + Space"
        case .commandShiftSpace:
            "Command + Shift + Space"
        }
    }

}

enum ASRProviderOption: String, Codable, CaseIterable, Identifiable {
    case doubao
    case openAI

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .doubao:
            "Doubao"
        case .openAI:
            "OpenAI"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var asrProvider: ASRProviderOption
    var appID: String
    var resourceID: String
    var openAIBaseURL: String
    var hotkey: HotkeyOption
    var language: DictationLanguage
    var llmRefinementEnabled: Bool

    static let defaults = AppSettings(
        asrProvider: .doubao,
        appID: "",
        resourceID: "volc.seedasr.sauc.duration",
        openAIBaseURL: "https://api.openai.com/v1",
        hotkey: .optionSpace,
        language: .zhCN,
        llmRefinementEnabled: false
    )

    var hasValidDoubaoConfiguration: Bool {
        !appID.trimmed.isEmpty && !resourceID.trimmed.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case asrProvider
        case appID
        case resourceID
        case openAIBaseURL
        case cluster
        case hotkey
        case language
        case llmRefinementEnabled
    }

    init(
        asrProvider: ASRProviderOption = .doubao,
        appID: String,
        resourceID: String,
        openAIBaseURL: String = AppSettings.defaults.openAIBaseURL,
        hotkey: HotkeyOption,
        language: DictationLanguage,
        llmRefinementEnabled: Bool
    ) {
        self.asrProvider = asrProvider
        self.appID = appID
        self.resourceID = resourceID
        self.openAIBaseURL = openAIBaseURL
        self.hotkey = hotkey
        self.language = language
        self.llmRefinementEnabled = llmRefinementEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        asrProvider = try container.decodeIfPresent(ASRProviderOption.self, forKey: .asrProvider) ?? .doubao
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""

        let decodedResourceID =
            try container.decodeIfPresent(String.self, forKey: .resourceID)
            ?? container.decodeIfPresent(String.self, forKey: .cluster)
            ?? AppSettings.defaults.resourceID
        resourceID = decodedResourceID.trimmed.isEmpty ? AppSettings.defaults.resourceID : decodedResourceID
        let decodedOpenAIBaseURL =
            try container.decodeIfPresent(String.self, forKey: .openAIBaseURL)
            ?? AppSettings.defaults.openAIBaseURL
        openAIBaseURL = decodedOpenAIBaseURL.trimmed.isEmpty ? AppSettings.defaults.openAIBaseURL : decodedOpenAIBaseURL

        hotkey = try container.decodeIfPresent(HotkeyOption.self, forKey: .hotkey) ?? .optionSpace
        language = try container.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? .zhCN
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(asrProvider, forKey: .asrProvider)
        try container.encode(appID.trimmed, forKey: .appID)
        try container.encode(resourceID.trimmed, forKey: .resourceID)
        try container.encode(openAIBaseURL.trimmed, forKey: .openAIBaseURL)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(language, forKey: .language)
        try container.encode(llmRefinementEnabled, forKey: .llmRefinementEnabled)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
