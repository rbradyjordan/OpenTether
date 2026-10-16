import Foundation
import Security
import TetherCore

/// Generic-password Keychain item per key. Used for the cloud device token
/// (`TokenStoring`) and for FTP destination passwords.
final class KeychainStore: @unchecked Sendable {
    let service: String
    init(service: String = "com.bradyjordan.tether") { self.service = service }

    func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ key: String, _ value: String?) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        guard let value, let data = value.data(using: .utf8) else { return }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

final class KeychainTokenStore: TokenStoring, @unchecked Sendable {
    private let keychain: KeychainStore
    private let key: String
    init(keychain: KeychainStore = KeychainStore(), key: String = "cloud.deviceToken") {
        self.keychain = keychain
        self.key = key
    }
    func token() -> String? { keychain.read(key) }
    func setToken(_ token: String?) { keychain.write(key, token) }
}
