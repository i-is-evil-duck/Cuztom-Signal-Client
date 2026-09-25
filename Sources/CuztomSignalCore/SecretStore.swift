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
/// Values are device-only and unavailable while the device is locked.
/// M1 will move identity + session blobs here instead of `config/` files
/// like signal-bridge-V2 used (`config/instagram_session.json` + bind mounts).
public struct KeychainSecretStore: SecretStoring {
    private let service: String
    public init(service: String = "top.furryfemboys.cuztom-signal") {
        self.service = service
    }

    public func load(key: String) async -> Data? {
        try? loadStrict(key: key)
    }

    /// Unlike the protocol's intentionally lossy `load`, this distinguishes a
    /// genuinely missing item from a locked/inaccessible Keychain. Callers
    /// must never generate replacement encryption material on the latter.
    public func loadStrict(key: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SignalError.storage("keychain returned an invalid value")
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw SignalError.storage("keychain read failed: \(status)")
        }
    }

    /// Return the existing secret or create one only when the item is truly
    /// absent. This is synchronous so initialization can be serialized without
    /// holding a lock across an `await`.
    public func loadOrCreateRandom(key: String, count: Int = 32) throws -> Data {
        guard count > 0 else { throw SignalError.storage("keychain secret length is invalid") }
        if let existing = try loadStrict(key: key) {
            guard existing.count == count else {
                throw SignalError.storage("keychain secret has an invalid length")
            }
            return existing
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SignalError.storage("secure random generation failed: \(status)")
        }
        let data = Data(bytes)
        if let existing = try addIfAbsent(key: key, value: data) {
            return existing
        }
        return data
    }

    public func save(key: String, value: Data) async throws {
        try saveSync(key: key, value: value)
    }

    /// Add only when absent. If another process wins the race, return its
    /// value rather than overwriting it with our newly generated key.
    private func addIfAbsent(key: String, value: Data) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        switch status {
        case errSecSuccess:
            return nil
        case errSecDuplicateItem:
            guard let existing = try loadStrict(key: key) else {
                throw SignalError.storage("keychain race produced no existing secret")
            }
            return existing
        default:
            throw SignalError.storage("keychain add failed: \(status)")
        }
    }

    private func saveSync(key: String, value: Data) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let attrs: [String: Any] = [
            kSecValueData as String: value,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = value
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            if addStatus == errSecDuplicateItem {
                let retry = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
                guard retry == errSecSuccess else {
                    throw SignalError.storage("keychain update after race failed: \(retry)")
                }
            } else if addStatus != errSecSuccess {
                throw SignalError.storage("keychain add failed: \(addStatus)")
            }
        } else if status != errSecSuccess {
            throw SignalError.storage("keychain update failed: \(status)")
        }
    }

    public func delete(key: String) async {
        try? deleteStrict(key: key)
    }

    public func deleteStrict(key: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SignalError.storage("keychain delete failed: \(status)")
        }
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
