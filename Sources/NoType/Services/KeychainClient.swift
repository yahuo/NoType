import Foundation
import Security

enum KeychainClientError: LocalizedError {
    case unhandled(OSStatus)
    case invalidValue

    var errorDescription: String? {
        switch self {
        case .unhandled(let status):
            "Keychain error: \(status)"
        case .invalidValue:
            "Keychain returned invalid data."
        }
    }
}

final class KeychainClient {
    private let service = "com.notype.app"

    func save(_ value: String, for account: String) throws {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = baseQuery(for: account)

        if trimmedValue.isEmpty {
            let deleteStatus = SecItemDelete(query as CFDictionary)
            guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
                throw KeychainClientError.unhandled(deleteStatus)
            }
            return
        }

        let data = Data(trimmedValue.utf8)
        let attributesToUpdate = [
            kSecValueData as String: data,
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainClientError.unhandled(updateStatus)
        }

        var payload = query
        payload[kSecValueData as String] = data

        let status = SecItemAdd(payload as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainClientError.unhandled(status)
        }
    }

    func read(account: String) throws -> String {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else {
            return ""
        }
        guard status == errSecSuccess else {
            throw KeychainClientError.unhandled(status)
        }
        guard
            let data = item as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            throw KeychainClientError.invalidValue
        }
        return value
    }

    func delete(account: String) {
        let query = baseQuery(for: account)
        SecItemDelete(query as CFDictionary)
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
    }
}
