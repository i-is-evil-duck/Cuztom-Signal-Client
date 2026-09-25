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

    /// Resolve a ZK group id to one of this device's groups, reading the map on
    /// first use.
    ///
    /// The map is loaded lazily rather than at startup because it lives behind
    /// the sync loop's live manager, which is not running yet when the app
    /// finishes configuring. Loading it eagerly failed every launch, which left
    /// inbound group calls unresolvable for the rest of the process.
    public func masterKeyHex(forGroupIdHex groupIdHex: String) async -> String? {
        if let known = lock.withLock({ groupIdToMasterKey?[groupIdHex] }) {
            return known
        }
        // Empty or stale: refresh once, then look again. A group this device has
        // left is simply absent from the map, so a second lookup coming back
        // empty is the answer rather than a failure worth retrying.
        guard (try? await loadGroupIdMap()) != nil else {
            Log.error("[group-call] group id map unreadable; inbound calls are unresolvable")
            return nil
        }
        return lock.withLock { groupIdToMasterKey?[groupIdHex] }
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

/// Redeems a group membership proof at the CDN, using the hosts the native
/// service configuration declares.
///
/// The host is deliberately not hardcoded here. Signal's service configuration
/// lists the CDN hosts that exist for the current environment, and they differ
/// between staging and production; a client that picks one is wrong half the
/// time and finds out as an unreachable endpoint.
public struct NativeGroupCallRedeemer: GroupCallController.ProofRedeeming {
    private let service: RustCoreService
    private let fallback: GroupCallProofService

    public init(service: RustCoreService, fallback: GroupCallProofService = GroupCallProofService()) {
        self.service = service
        self.fallback = fallback
    }

    public func cdnBaseURLs() async throws -> [URL] {
        let configured = try await service.cdnUrls()
        guard !configured.isEmpty else {
            // Failing is the point: a made-up host would fail as an unreachable
            // endpoint, which says nothing about the real problem.
            throw SignalError.network("the service configuration declares no CDN")
        }
        let hosts = configured.map { $0.host ?? "?" }.joined(separator: ", ")
        Log.info("[group-call] configured CDNs: \(hosts)")
        return configured
    }

    public func fetchToken(
        cdnBaseURL: URL,
        authorization: String,
        groupIdHex: String
    ) async throws -> GroupCallProofService.Proof {
        try await fallback.fetchToken(
            cdnBaseURL: cdnBaseURL,
            authorization: authorization,
            groupIdHex: groupIdHex
        )
    }
}
