import Foundation

final class SettingsStore {
    private let userDefaults: UserDefaults
    private let settingsKey = "notype.settings"
    private let accessTokenPresenceKey = "notype.access-token-present"
    private let llmAPIKeyPresenceKey = "notype.llm-api-key-present"

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> AppSettings {
        guard
            let data = userDefaults.data(forKey: settingsKey),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else {
            return .defaults
        }
        return settings
    }

    func save(_ settings: AppSettings) throws {
        let data = try JSONEncoder().encode(settings)
        userDefaults.set(data, forKey: settingsKey)
    }

    func storedAccessTokenPresence() -> Bool? {
        userDefaults.object(forKey: accessTokenPresenceKey) as? Bool
    }

    func setHasStoredAccessToken(_ present: Bool) {
        userDefaults.set(present, forKey: accessTokenPresenceKey)
    }

    func clearStoredAccessTokenPresence() {
        userDefaults.removeObject(forKey: accessTokenPresenceKey)
    }

    func storedLLMAPIKeyPresence() -> Bool? {
        userDefaults.object(forKey: llmAPIKeyPresenceKey) as? Bool
    }

    func setHasStoredLLMAPIKey(_ present: Bool) {
        userDefaults.set(present, forKey: llmAPIKeyPresenceKey)
    }

    func clearStoredLLMAPIKeyPresence() {
        userDefaults.removeObject(forKey: llmAPIKeyPresenceKey)
    }
}
