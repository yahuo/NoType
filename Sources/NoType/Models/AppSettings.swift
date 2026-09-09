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

enum SpeechProvider: String, Codable, CaseIterable, Identifiable {
    case codex
    case doubao

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: "Codex"
        case .doubao: "Doubao"
        }
    }
}

enum NeoVoice: String, Codable, CaseIterable, Identifiable {
    case juniper, maple, spruce, ember, vale, breeze, arbor, sol, cove

    var id: String { rawValue }
    var displayName: String { rawValue.capitalized }

    var description: String {
        switch self {
        case .juniper: "开朗且乐观"
        case .maple: "开朗而直率"
        case .spruce: "平静而肯定"
        case .ember: "自信且乐观"
        case .vale: "明快而好奇"
        case .breeze: "生动而真诚"
        case .arbor: "随和且百搭"
        case .sol: "聪慧而从容"
        case .cove: "沉稳而直接"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var speechProvider: SpeechProvider
    var appID: String
    var resourceID: String
    var hotkey: HotkeyOption
    var language: DictationLanguage
    var llmRefinementEnabled: Bool
    var agentTUITranslationEnabled: Bool
    var neoWakeEnabled: Bool = false
    var neoWakePhrase = AppSettings.defaultNeoWakePhrase
    var neoVoice: NeoVoice = .juniper

    static let defaultNeoWakePhrase = "Hey Neo"

    static func normalizedNeoWakePhrase(_ value: String) -> String? {
        let phrase = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return phrase.contains(where: { $0.isLetter }) ? phrase : nil
    }

    static let defaults = AppSettings(
        appID: "",
        resourceID: "volc.seedasr.sauc.duration",
        hotkey: .optionSpace,
        language: .zhCN,
        llmRefinementEnabled: false,
        agentTUITranslationEnabled: false
    )

    var hasValidASRConfiguration: Bool {
        !appID.trimmed.isEmpty && !resourceID.trimmed.isEmpty
    }

    var shouldRewriteDictation: Bool {
        speechProvider == .doubao && llmRefinementEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case speechProvider
        case appID
        case resourceID
        case cluster
        case hotkey
        case language
        case llmRefinementEnabled
        case agentTUITranslationEnabled
        case neoWakeEnabled
        case neoWakePhrase
        case neoVoice
    }

    init(
        appID: String,
        resourceID: String,
        hotkey: HotkeyOption,
        language: DictationLanguage,
        llmRefinementEnabled: Bool,
        agentTUITranslationEnabled: Bool,
        speechProvider: SpeechProvider = .codex
    ) {
        self.speechProvider = speechProvider
        self.appID = appID
        self.resourceID = resourceID
        self.hotkey = hotkey
        self.language = language
        self.llmRefinementEnabled = llmRefinementEnabled
        self.agentTUITranslationEnabled = agentTUITranslationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Existing installations keep their current speech backend until switched explicitly.
        speechProvider = try container.decodeIfPresent(SpeechProvider.self, forKey: .speechProvider) ?? .doubao
        neoWakeEnabled = try container.decodeIfPresent(Bool.self, forKey: .neoWakeEnabled) ?? false
        neoWakePhrase = Self.normalizedNeoWakePhrase(try container.decodeIfPresent(String.self, forKey: .neoWakePhrase) ?? "") ?? Self.defaultNeoWakePhrase
        neoVoice = NeoVoice(rawValue: try container.decodeIfPresent(String.self, forKey: .neoVoice) ?? "") ?? .juniper
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""

        let decodedResourceID =
            try container.decodeIfPresent(String.self, forKey: .resourceID)
            ?? container.decodeIfPresent(String.self, forKey: .cluster)
            ?? AppSettings.defaults.resourceID
        resourceID = decodedResourceID.trimmed.isEmpty ? AppSettings.defaults.resourceID : decodedResourceID

        hotkey = try container.decodeIfPresent(HotkeyOption.self, forKey: .hotkey) ?? .optionSpace
        language = try container.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? .zhCN
        llmRefinementEnabled = try container.decodeIfPresent(Bool.self, forKey: .llmRefinementEnabled) ?? false
        agentTUITranslationEnabled = try container.decodeIfPresent(
            Bool.self,
            forKey: .agentTUITranslationEnabled
        ) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(neoWakeEnabled, forKey: .neoWakeEnabled)
        try container.encode(neoWakePhrase, forKey: .neoWakePhrase)
        try container.encode(neoVoice, forKey: .neoVoice)
        try container.encode(speechProvider, forKey: .speechProvider)
        try container.encode(appID.trimmed, forKey: .appID)
        try container.encode(resourceID.trimmed, forKey: .resourceID)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(language, forKey: .language)
        try container.encode(llmRefinementEnabled, forKey: .llmRefinementEnabled)
        try container.encode(agentTUITranslationEnabled, forKey: .agentTUITranslationEnabled)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
