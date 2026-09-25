import Foundation

/// Secret storage boundary. Production uses Keychain; tests/UI previews
/// use the in-memory actor. Keeps identity keys out of SQLite.
public protocol SecretStoring: Sendable {
    func load(key: String) async -> Data?
    func save(key: String, value: Data) async throws
    func delete(key: String) async
    /// Delete all stored secrets. Used on logout.
    func clearAll() async
}

public actor InMemorySecretStore: SecretStoring {
    private var bag: [String: Data] = [:]
    public init() {}

    public func load(key: String) async -> Data? { bag[key] }
    public func save(key: String, value: Data) async throws { bag[key] = value }
    public func delete(key: String) async { bag.removeValue(forKey: key) }
    public func clearAll() async { bag.removeAll() }
}

#if canImport(Security)
import Security

/// Minimal Keychain wrapper (kSecClassGenericPassword, this app's access group).
/// M1 will move identity + session blobs here instead of `config/` files
/// like signal-bridge-V2 used (`config/instagram_session.json` + bind mounts).
public struct KeychainSecretStore: SecretStoring {
    private let service: String
    public init(service: String = "top.furryfemboys.cuztom-signal") {
        self.service = service
    }

    public func load(key: String) async -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    public func save(key: String, value: Data) async throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = value
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw SignalError.storage("keychain add failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw SignalError.storage("keychain update failed: \(status)")
        }
    }

    public func delete(key: String) async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    public func clearAll() async {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
