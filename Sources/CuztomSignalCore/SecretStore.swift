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

    /// Values already read in this process, keyed by account.
    ///
    /// A Keychain read of an item created by a *different* code signature makes
    /// macOS show an authorization prompt. Reading the same item again in the
    /// same process prompts again, so a second read of an already-resolved key
    /// costs the user another click for no new information. Caching means each
    /// account is read at most once per launch, and the prompt count becomes the
    /// number of distinct keys rather than the number of call sites.
    ///
    /// Cleared explicitly on logout, because a relink must be able to read a
    /// freshly written key rather than the one this process resolved earlier.
    private static let resolved = NSLock()
    nonisolated(unsafe) private static var cache: [String: Data] = [:]

    /// Counts every Keychain operation in this process.
    ///
    /// An item created under a different code signature makes macOS show an
    /// authorization prompt, and the prompt count is the number that matters to
    /// the user. It cannot be derived from the code, only observed, so every
    /// operation is numbered in the log.
    private static let operationCounter = NSLock()
    nonisolated(unsafe) private static var operationCount = 0

    static func noteOperation(_ kind: String, key: String) {
        operationCounter.lock()
        operationCount += 1
        let index = operationCount
        operationCounter.unlock()
        Log.info("[keychain] op=\(index) \(kind) account=\(key)")
    }

    static func resetOperationCount() {
        operationCounter.lock()
        operationCount = 0
        operationCounter.unlock()
    }

    public init(service: String = "top.furryfemboys.cuztom-signal") {
        self.service = service
    }

    /// Forget every cached value. Called on logout and relink so the next
    /// database open re-reads the Keychain rather than trusting this process.
    public static func invalidateResolvedSecrets() {
        resolved.lock()
        cache.removeAll()
        resolved.unlock()
    }

    public func load(key: String) async -> Data? {
        try? loadStrict(key: key)
    }

    /// Unlike the protocol's intentionally lossy `load`, this distinguishes a
    /// genuinely missing item from a locked/inaccessible Keychain. Callers
    /// must never generate replacement encryption material on the latter.
    public func loadStrict(key: String) throws -> Data? {
        Self.noteOperation("read", key: key)
        let cacheKey = "\(service)/\(key)"
        Self.resolved.lock()
        if let cached = Self.cache[cacheKey] {
            Self.resolved.unlock()
            return cached
        }
        Self.resolved.unlock()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        Log.info("[keychain] read \(key) -> OSStatus \(status)")
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw SignalError.storage("keychain returned an invalid value")
            }
            Self.remember(cacheKey, data)
            return data
        case errSecItemNotFound:
            // Not cached: a missing item may be created moments later by
            // `loadOrCreateRandom`, and caching the absence would make that
            // look like a second missing read.
            Log.info("[keychain] no item for \(key)")
            return nil
        default:
            // Not cached either, so a transient failure does not become a
            // sticky "no key" for the rest of the process.
            throw SignalError.storage("keychain read failed: \(status) for \(key)")
        }
    }

    private static func remember(_ cacheKey: String, _ data: Data) {
        resolved.lock()
        cache[cacheKey] = data
        resolved.unlock()
        Log.info("[keychain] resolved \(cacheKey) (\(data.count) bytes)")
    }

    /// Return the existing secret or create one only when the item is truly
    /// absent. This is synchronous so initialization can be serialized without
    /// holding a lock across an `await`.
    ///
    /// A caller that has just read the item will not cause a second prompt: the
    /// value it resolved is cached, and a read of an absent item does not
    /// trigger an authorization check.
    public func loadOrCreateRandom(key: String, count: Int = 32) throws -> Data {
        guard count > 0 else { throw SignalError.storage("keychain secret length is invalid") }
        if let found = try loadStrict(key: key) {
            guard found.count == count else {
                throw SignalError.storage("keychain secret has an invalid length")
            }
            return found
        }
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        guard status == errSecSuccess else {
            throw SignalError.storage("secure random generation failed: \(status)")
        }
        let data = Data(bytes)
        if let won = try addIfAbsent(key: key, value: data) {
            return won
        }
        // The item now exists and this process created it, so remember it rather
        // than reading it back.
        Self.remember("\(service)/\(key)", data)
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
        Self.noteOperation("add", key: key)
        let status = SecItemAdd(query as CFDictionary, nil)
        Log.info("[keychain] add \(key) -> OSStatus \(status)")
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
        Self.noteOperation("delete", key: key)
        let status = SecItemDelete(query as CFDictionary)
        // Forget the cached copy first: leaving it would let the rest of this
        // process keep opening a database with a key that no longer exists.
        Self.resolved.lock()
        Self.cache.removeValue(forKey: "\(service)/\(key)")
        Self.resolved.unlock()
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
