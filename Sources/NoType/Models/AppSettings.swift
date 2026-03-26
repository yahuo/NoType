import Carbon
import Foundation

enum DictationLanguage: String, Codable, CaseIterable, Identifiable {
    case zhCN = "zh-CN"
    case enUS = "en-US"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .zhCN:
            "简体中文"
        case .enUS:
            "English"
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
    var microphoneID: String?
    var autoInsert: Bool
    var showDockIcon: Bool
    var historyRetentionDays: Int
    var launchAtLogin: Bool
    var hotkey: HotkeyOption
    var language: DictationLanguage

    static let defaults = AppSettings(
        appID: "",
        resourceID: "volc.seedasr.sauc.duration",
        microphoneID: nil,
        autoInsert: true,
        showDockIcon: true,
        historyRetentionDays: 30,
        launchAtLogin: false,
        hotkey: .optionSpace,
        language: .zhCN
    )

    var hasValidASRConfiguration: Bool {
        !appID.trimmed.isEmpty && !resourceID.trimmed.isEmpty
    }

    private enum CodingKeys: String, CodingKey {
        case appID
        case resourceID
        case cluster
        case microphoneID
        case autoInsert
        case showDockIcon
        case historyRetentionDays
        case launchAtLogin
        case hotkey
        case language
    }

    init(
        appID: String,
        resourceID: String,
        microphoneID: String?,
        autoInsert: Bool,
        showDockIcon: Bool,
        historyRetentionDays: Int,
        launchAtLogin: Bool,
        hotkey: HotkeyOption,
        language: DictationLanguage
    ) {
        self.appID = appID
        self.resourceID = resourceID
        self.microphoneID = microphoneID
        self.autoInsert = autoInsert
        self.showDockIcon = showDockIcon
        self.historyRetentionDays = historyRetentionDays
        self.launchAtLogin = launchAtLogin
        self.hotkey = hotkey
        self.language = language
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        appID = try container.decodeIfPresent(String.self, forKey: .appID) ?? ""
        let decodedResourceID =
            try container.decodeIfPresent(String.self, forKey: .resourceID)
            ?? container.decodeIfPresent(String.self, forKey: .cluster)
            ?? AppSettings.defaults.resourceID
        resourceID = decodedResourceID.trimmed.isEmpty ? AppSettings.defaults.resourceID : decodedResourceID
        microphoneID = try container.decodeIfPresent(String.self, forKey: .microphoneID)
        autoInsert = try container.decodeIfPresent(Bool.self, forKey: .autoInsert) ?? true
        showDockIcon = try container.decodeIfPresent(Bool.self, forKey: .showDockIcon) ?? false
        historyRetentionDays = try container.decodeIfPresent(Int.self, forKey: .historyRetentionDays) ?? 30
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        hotkey = try container.decodeIfPresent(HotkeyOption.self, forKey: .hotkey) ?? .optionSpace
        language = try container.decodeIfPresent(DictationLanguage.self, forKey: .language) ?? .zhCN
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(appID, forKey: .appID)
        try container.encode(resourceID, forKey: .resourceID)
        try container.encodeIfPresent(microphoneID, forKey: .microphoneID)
        try container.encode(autoInsert, forKey: .autoInsert)
        try container.encode(showDockIcon, forKey: .showDockIcon)
        try container.encode(historyRetentionDays, forKey: .historyRetentionDays)
        try container.encode(launchAtLogin, forKey: .launchAtLogin)
        try container.encode(hotkey, forKey: .hotkey)
        try container.encode(language, forKey: .language)
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
