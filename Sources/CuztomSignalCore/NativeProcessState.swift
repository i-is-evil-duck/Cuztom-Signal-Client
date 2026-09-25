import Foundation

/// Process-wide safety state for the singleton native worker. A failed wipe
/// must not be bypassed merely by constructing another Swift service object.
final class NativeProcessState: @unchecked Sendable {
    static let shared = NativeProcessState()

    let lifecycleGate = AsyncOperationGate()

    private let lock = NSLock()
    private var sessionEpochs: [String: SessionEpoch] = [:]
    private var poisonedDatabasePaths: Set<String> = []

    func sessionEpoch(databasePath: String) -> SessionEpoch {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.key(databasePath)
        if let existing = sessionEpochs[key] { return existing }
        let created = SessionEpoch()
        sessionEpochs[key] = created
        return created
    }

    func isPoisoned(databasePath: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return poisonedDatabasePaths.contains(Self.key(databasePath))
    }

    func requireUsable(databasePath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !poisonedDatabasePaths.contains(Self.key(databasePath)) else {
            throw SignalError.sessionInvalidated
        }
    }

    func markPoisoned(databasePath: String) {
        lock.lock()
        poisonedDatabasePaths.insert(Self.key(databasePath))
        lock.unlock()
    }

    func clearPoison(databasePath: String) {
        lock.lock()
        poisonedDatabasePaths.remove(Self.key(databasePath))
        lock.unlock()
    }

    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }
}
