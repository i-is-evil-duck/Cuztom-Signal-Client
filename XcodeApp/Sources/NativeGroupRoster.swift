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

    /// `GroupRosterProviding.load`, so a group call can prime its own roster.
    ///
    /// The concrete `load` above returns the richer `GroupRoster`; this is the
    /// protocol-shaped view of it. The SFU needs the member ACIs, and a call
    /// joined against a cache that was never filled hands it none.
    public func load(masterKeyHex: String) async throws -> [String] {
        try await load(masterKeyHex: masterKeyHex).memberAciUUIDs
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

/// Redeems a group membership proof natively.
///
/// Two things force this to the native side.
///
/// The endpoint is on the **storage service**, not a CDN. Traced from Signal
/// Desktop 8.28.0, the group-token call is issued with `host: 'storageService'`
/// and path `v2/groups/token`; the same host serves the group-state `PUT` and the
/// group-avatar upload. Requesting it from a CDN answers 403.
///
/// The storage service also serves a certificate from Signal's own authority
/// rather than the system roots, so `URLSession` rejects it while the native
/// client - already built with the service configuration's certificate
/// authority - accepts it.
///
/// The host is resolved through the service configuration natively, so a staging
/// build does not talk to production.
public struct NativeGroupCallRedeemer: GroupCallController.ProofRedeeming {
    private let service: RustCoreService

    public init(service: RustCoreService) {
        self.service = service
    }

    public func cdnBaseURLs() async throws -> [URL] {
        // The list is reporting only: the request is issued natively against the
        // storage endpoint, so nothing here selects a host. Reported so a
        // configuration problem is still visible.
        let configured = try await service.cdnUrls()
        let hosts = configured.map { $0.host ?? "?" }.joined(separator: ", ")
        Log.info("[group-call] redeeming natively; configured CDNs (not used): \(hosts)")
        return [URL(string: "https://storage.invalid")!]
    }

    public func fetchToken(
        cdnBaseURL: URL,
        authorization: String,
        groupIdHex: String
    ) async throws -> GroupCallProofService.Proof {
        return try await service.groupCallRedeemProof(authorization: authorization)
    }
}
