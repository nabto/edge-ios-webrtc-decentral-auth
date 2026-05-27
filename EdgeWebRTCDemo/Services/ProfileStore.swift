import Foundation
import Security
import NabtoEdgeClient

/// Persists the Nabto Edge client private key in the iOS Keychain.
///
/// The key is generated lazily on first access via `Client.createPrivateKey()` and
/// stored under a single account; calling `regenerate()` overwrites it (which will
/// invalidate all existing device pairings, since the device-side IAM trusts a
/// specific public-key fingerprint).
final class ProfileStore {
    static let shared = ProfileStore()

    private let service = "com.nabto.EdgeWebRTCDemo"
    private let account = "nabtoEdgePrivateKey"

    private init() {}

    func privateKey(using client: Client) throws -> String {
        if let existing = try loadKey() { return existing }
        let fresh = try client.createPrivateKey()
        try saveKey(fresh)
        return fresh
    }

    func regenerate(using client: Client) throws -> String {
        let fresh = try client.createPrivateKey()
        try saveKey(fresh)
        return fresh
    }

    func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func loadKey() throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data, let string = String(data: data, encoding: .utf8) else {
            throw KeychainError.malformed
        }
        return string
    }

    private func saveKey(_ key: String) throws {
        let data = Data(key.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
            return
        }
        throw KeychainError.osStatus(status)
    }

    enum KeychainError: LocalizedError {
        case osStatus(OSStatus)
        case malformed

        var errorDescription: String? {
            switch self {
            case .osStatus(let s): return "Keychain error \(s)"
            case .malformed:       return "Keychain item could not be decoded as UTF-8"
            }
        }
    }
}
