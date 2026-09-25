import Foundation
import CryptoKit
import GRDB

#if canImport(Darwin)
import Darwin
#endif

/// Security boundary for the Swift presentation database.
///
/// The presentation store uses the SQLCipher-enabled GRDB package. The
/// passphrase is created once and kept in the device-only Keychain; plaintext
/// databases are converted through SQLCipher's export API rather than
/// rekeying an existing file in place.
enum PresentationDatabaseSecurity {
    static let keychainAccountPrefix = "presentation.sqlcipher.passphrase.v1"
    private static let sqliteHeader = Data([
        0x53, 0x51, 0x4C, 0x69, 0x74, 0x65, 0x20,
        0x66, 0x6F, 0x72, 0x6D, 0x61, 0x74, 0x20, 0x33, 0x00,
    ])

    enum DatabaseKind {
        case missing
        case plaintext
        case encryptedOrUnknown
    }

    /// Prepare the on-disk database and return the canonical passphrase used
    /// for both `sqlite3_key` and SQLCipher `ATTACH ... KEY`.
    static func prepareDatabase(at url: URL, explicitPassphrase: String?) throws -> String {
        let kind = try classifyDatabase(at: url)
        let passphrase = try resolvePassphrase(for: url, kind: kind, explicit: explicitPassphrase)
        if case .plaintext = kind {
            try migratePlaintextDatabase(at: url, passphrase: passphrase)
        }
        return passphrase
    }

    static func keychainAccount(for databaseURL: URL) -> String {
        let normalized = databaseURL.standardizedFileURL.path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        let suffix = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "\(keychainAccountPrefix).\(suffix)"
    }

    static func configuration(passphrase: String) -> Configuration {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            // GRDB's SQLCipher integration calls sqlite3_key before any
            // application SQL is evaluated on the connection.
            try db.usePassphrase(passphrase)
        }
        return configuration
    }

    static func deleteKey(account: String) throws {
        #if canImport(Security)
        try KeychainSecretStore().deleteStrict(key: account)
        #endif
    }

    private static func resolvePassphrase(
        for url: URL,
        kind: DatabaseKind,
        explicit: String?
    ) throws -> String {
        if let explicit {
            guard !explicit.isEmpty else {
                throw SignalError.storage("presentation database passphrase is empty")
            }
            guard !explicit.utf8.contains(0) else {
                throw SignalError.storage("presentation database passphrase contains NUL")
            }
            return explicit
        }

        #if canImport(Security)
        let keychain = KeychainSecretStore()
        let account = keychainAccount(for: url)
        let existing = try keychain.loadStrict(key: account)
        if let existing {
            guard existing.count == 32 else {
                throw SignalError.storage("presentation database key has an invalid length")
            }
            return existing.base64EncodedString()
        }

        // A missing key is only safe to create for a new or recognized legacy
        // plaintext database. Never replace the key for an unknown/encrypted
        // file: doing so would make an existing account permanently unreadable.
        guard canCreateKey(for: kind) else {
            throw SignalError.storage(
                "presentation database key is missing for an existing database; restore Keychain access"
            )
        }
        let generated = try keychain.loadOrCreateRandom(key: account, count: 32)
        return generated.base64EncodedString()
        #else
        throw SignalError.unsupported("presentation database encryption requires Keychain support")
        #endif
    }

    private static func canCreateKey(for kind: DatabaseKind) -> Bool {
        switch kind {
        case .missing, .plaintext:
            return true
        case .encryptedOrUnknown:
            return false
        }
    }

    private static func classifyDatabase(at url: URL) throws -> DatabaseKind {
        if let metadata = try? FileManager.default.attributesOfItem(atPath: url.path),
           (metadata[.type] as? FileAttributeType) == .typeSymbolicLink {
            throw SignalError.storage("presentation database path must not be a symlink")
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A missing main file with WAL/SHM state is not a fresh store.
            if FileManager.default.fileExists(atPath: url.path + "-wal")
                || FileManager.default.fileExists(atPath: url.path + "-shm") {
                return .encryptedOrUnknown
            }
            return .missing
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            throw SignalError.storage("presentation database could not be inspected")
        }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 16), header.count == 16 else {
            return .encryptedOrUnknown
        }
        return header == sqliteHeader ? .plaintext : .encryptedOrUnknown
    }

    private static func migratePlaintextDatabase(at url: URL, passphrase: String) throws {
        let stageURL = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).sqlcipher-\(UUID().uuidString)")
        try createPrivateStage(at: stageURL)

        do {
            let source = try DatabaseQueue(path: url.path)
            do {
                try source.writeWithoutTransaction { db in
                    let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                    guard integrity == "ok" else {
                        throw SignalError.storage("presentation plaintext integrity check failed")
                    }
                    let tables = Set(try String.fetchAll(
                        db,
                        sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                    ))
                    guard tables.contains("conversations"), tables.contains("messages") else {
                        throw SignalError.storage("database is not a recognized presentation store")
                    }
                    _ = try Row.fetchAll(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)")

                    let attach = "ATTACH DATABASE \(sqlQuote(stageURL.path)) AS encrypted KEY \(sqlQuote(passphrase))"
                    try db.execute(sql: attach)
                    do {
                        // sqlcipher_export is a void function; the query being
                        // consumed successfully is the success signal.
                        _ = try Row.fetchOne(db, sql: "SELECT sqlcipher_export('encrypted')")
                        try db.execute(sql: "DETACH DATABASE encrypted")
                    } catch {
                        try? db.execute(sql: "DETACH DATABASE encrypted")
                        throw error
                    }
                }
                try source.close()
            } catch {
                try? source.close()
                throw error
            }

            try validateEncryptedStage(at: stageURL, passphrase: passphrase)
            try removeIfPresent(URL(fileURLWithPath: url.path + "-wal"))
            try removeIfPresent(URL(fileURLWithPath: url.path + "-shm"))
            try removeIfPresent(URL(fileURLWithPath: url.path + "-journal"))
            try removeIfPresent(URL(fileURLWithPath: stageURL.path + "-wal"))
            try removeIfPresent(URL(fileURLWithPath: stageURL.path + "-shm"))
            try removeIfPresent(URL(fileURLWithPath: stageURL.path + "-journal"))

            #if canImport(Darwin)
            guard rename(stageURL.path, url.path) == 0 else {
                throw SignalError.storage("presentation database replacement failed (errno \(errno))")
            }
            #else
            try FileManager.default.removeItem(at: url)
            try FileManager.default.moveItem(at: stageURL, to: url)
            #endif
            try protectFile(at: url)
        } catch {
            try? FileManager.default.removeItem(at: stageURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stageURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: stageURL.path + "-shm"))
            throw error
        }
    }

    private static func validateEncryptedStage(at url: URL, passphrase: String) throws {
        let queue = try DatabaseQueue(path: url.path, configuration: configuration(passphrase: passphrase))
        do {
            try queue.read { db in
                guard let cipherVersion = try String.fetchOne(db, sql: "PRAGMA cipher_version"),
                      !cipherVersion.isEmpty else {
                    throw SignalError.storage("presentation migration stage is not SQLCipher encrypted")
                }
                let integrity = try String.fetchOne(db, sql: "PRAGMA integrity_check")
                guard integrity == "ok" else {
                    throw SignalError.storage("presentation encrypted integrity check failed")
                }
                if let cipherIntegrity = try String.fetchOne(db, sql: "PRAGMA cipher_integrity_check"),
                   cipherIntegrity != "ok" {
                    throw SignalError.storage("presentation encrypted cipher integrity check failed")
                }
                let tables = Set(try String.fetchAll(
                    db,
                    sql: "SELECT name FROM sqlite_master WHERE type = 'table'"
                ))
                guard tables.contains("conversations"), tables.contains("messages") else {
                    throw SignalError.storage("presentation migration schema is incomplete")
                }
            }
            try queue.close()
        } catch {
            try? queue.close()
            throw error
        }
        let header = try readHeader(at: url)
        guard header != sqliteHeader else {
            throw SignalError.storage("presentation migration stage retained a plaintext header")
        }
    }

    private static func readHeader(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try handle.read(upToCount: sqliteHeader.count) ?? Data()
    }

    private static func createPrivateStage(at url: URL) throws {
        guard FileManager.default.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw SignalError.storage("presentation migration stage could not be created")
        }
        try protectFile(at: url)
    }

    private static func protectFile(at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
    }

    private static func removeIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    private static func sqlQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
