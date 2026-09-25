import Foundation
import CuztomSignalCore

/// A group roster backed by the native store.
///
/// The controller needs two things per group: a display name and the member
/// ACIs the SFU needs in order to attribute call traffic. Both are read from the
/// same place, so they are cached together for the length of a call rather than
/// fetched repeatedly.
///
/// A group whose roster cannot be read is reported as unknown rather than as
/// empty. The difference matters: an empty roster tells the SFU nobody is
/// present, so every participant becomes unattributable, while an unknown roster
/// fails visibly before a call is placed.
public final class NativeGroupRoster: GroupRosterProviding, @unchecked Sendable {
    private let service: RustCoreService
    private let lock = NSLock()
    private var cached: [String: RustCoreService.GroupRoster] = [:]
    /// ZK group id to master key, loaded once. Needed to decide which inbound
    /// calls this device can answer at all.
    private var groupIdToMasterKey: [String: String]?
    private var titles: [String: String] = [:]

    public init(service: RustCoreService) {
        self.service = service
    }

    /// Seed the display names from the conversation list the app already has.
    ///
    /// Group titles arrive with the roster, but only when a call is placed, so
    /// the caller's name is used for the header while a call is in progress.
    public func seedTitles(_ byMasterKey: [String: String]) {
        lock.withLock { titles.merge(byMasterKey) { _, new in new } }
    }

    public func members(masterKeyHex: String) -> [String] {
        lock.withLock { cached[masterKeyHex]?.memberAciUUIDs ?? [] }
    }

    public func title(masterKeyHex: String) -> String {
        lock.withLock { cached[masterKeyHex]?.title ?? titles[masterKeyHex] ?? "" }
    }

    public func masterKeyHex(forGroupIdHex groupIdHex: String) -> String? {
        lock.withLock { groupIdToMasterKey?[groupIdHex] }
    }

    /// Read a group's roster into the cache.
    ///
    /// Called by the view model before a call is placed, so a failure surfaces as
    /// "cannot read this group" rather than as a call that connects with nobody
    /// identifiable in it.
    @discardableResult
    public func load(masterKeyHex: String) async throws -> RustCoreService.GroupRoster {
        let roster = try await service.groupRoster(masterKeyHex: masterKeyHex)
        lock.withLock { cached[masterKeyHex] = roster }
        return roster
    }

    /// Load the id-to-key map used to decide which inbound calls are receivable.
    @discardableResult
    public func loadGroupIdMap() async throws -> [String: String] {
        let map = try await service.groupIdMap()
        lock.withLock { groupIdToMasterKey = map }
        return map
    }

    /// Drop everything. Called on logout and relink: group state from one
    /// account must never be visible to the next.
    public func reset() {
        lock.withLock {
            cached.removeAll()
            groupIdToMasterKey = nil
        }
    }
}
