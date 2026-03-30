import Carbon
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

    var keyCode: UInt32 {
        49
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace:
            UInt32(optionKey)
        case .controlSpace:
            UInt32(controlKey)
        case .commandShiftSpace:
            UInt32(cmdKey | shiftKey)
        }
    }
}

struct AppSettings: Codable, Equatable {
    var appID: String
    var resourceID: String
    var hotkey: HotkeyOption
    var language: DictationLanguage
    var llmRefinementEnabled: Bool
    var llmBaseURL: String
    var llmModel: String

    static let defaults = AppSettings(
        appID: "",
        resourceID: "volc.seedasr.sauc.duration",
        hotkey: .optionSpace,
        language: .zhCN,
        llmRefinementEnabled: false,
        llmBaseURL: "https://api.openai.com/v1",
        llmModel: "gpt-4.1-mini"
    )

    var hasValidASRConfiguration: Bool {
        !appID.trimmed.isEmpty && !resourceID.trimmed.isEmpty
    }

    var llmConfiguredWithoutAPIKey: Bool {
        !llmBaseURL.trimmed.isEmpty && !llmModel.trimmed.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case appID
        case resourceID
        case cluster
        case hotkey
        case language
        case llmRefinementEnabled
        case llmBaseURL
        case llmModel
    }

    init(
        appID: String,
        resourceID: String,
        hotkey: HotkeyOption,
        language: DictationLanguage,
        llmRefinementEnabled: Bool,
        llmBaseURL: String,
        llmModel: String
    ) {
        self.appID = appID
        self.resourceID = resourceID
        self.hotkey = hotkey
        self.language = language
        self.llmRefinementEnabled = llmRefinementEnabled
        self.llmBaseURL = llmBaseURL
        self.llmModel = llmModel
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""

        let decodedResourceID =
            try container.decodeIfPresent(String.self, forKey: .resourceID)
            ?? container.decodeIfPresent(String.self, forKey: .cluster)
            ?? AppSettings.defaults.resourceID
        resourceID = decodedResourceID.trimmed.isEmpty ? AppSettings.defaults.resourceID : decodedResourceID

        hotkey = try container.decodeIfPresent(HotkeyOption.self, forKey: .hotkey) ?? .optionSpace
        language = try container.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? .zhCN
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        llmBaseURL = try container.decodeIfPresent(String.self, forKey: .llmBaseURL) ?? AppSettings.defaults.llmBaseURL
        llmModel = try container.decodeIfPresent(String.self, forKey: .llmModel) ?? AppSettings.defaults.llmModel
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appID.trimmed, forKey: .appID)
        try container.encode(resourceID.trimmed, forKey: .resourceID)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(language, forKey: .language)
        try container.encode(llmRefinementEnabled, forKey: .llmRefinementEnabled)
        try container.encode(llmBaseURL.trimmed, forKey: .llmBaseURL)
        try container.encode(llmModel.trimmed, forKey: .llmModel)
    }
}

struct LLMSettingsDraft: Equatable {
    var baseURL: String
    var apiKey: String
    var model: String

    init(baseURL: String, apiKey: String, model: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }

    init(settings: AppSettings, apiKey: String) {
        self.init(
            baseURL: settings.llmBaseURL,
            apiKey: apiKey,
            model: settings.llmModel
        )
    }

    var isConfigured: Bool {
        !baseURL.trimmed.isEmpty && !apiKey.trimmed.isEmpty && !model.trimmed.isEmpty
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
