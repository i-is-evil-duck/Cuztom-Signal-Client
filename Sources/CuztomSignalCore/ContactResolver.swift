import Foundation

/// Centralized contact name resolution service.
/// Provides consistent ACI/UUID → display name mapping across the app.
public actor ContactResolver {
    private let rustCore: RustCoreService?
    private var nameCache: [String: String] = [:] // aci/uuid -> display name
    private var groupMemberCache: [String: [String: String]] = [:] // groupThreadId -> [aci -> name]

    public init(rustCore: RustCoreService? = nil) {
        self.rustCore = rustCore
    }

    /// Set the RustCoreService for profile lookups
    public func setRustCore(_ rustCore: RustCoreService) {
        // Note: Can't reassign due to actor isolation, would need a different pattern
    }

    /// Resolve display name for an ACI/UUID in a conversation context
    public func displayName(for aci: String, in conversationId: String, conversations: [Conversation]) -> String {
        // "You" for own messages
        if aci == "self" || aci == "You" { return "You" }

        // Check conversation peer (1:1 chat)
        if let conv = conversations.first(where: { $0.id == conversationId }) {
            if !conv.peer.isGroup {
                if conv.peer.uuidString == aci || conv.peer.phone == aci {
                    return conv.title
                }
            } else {
                // Group conversation - check group member cache
                if let memberName = groupMemberCache[conversationId]?[aci] {
                    return memberName
                }
            }
        }

        // Check global name cache
        if let cached = nameCache[aci] {
            return cached
        }

        // UI-facing fallback: do not expose raw service identifiers.
        return "Unknown"
    }

    /// Resolve display name with RustCore for profile lookups
    public func displayNameWithProfile(for aci: String, in conversationId: String, conversations: [Conversation], rustCore: RustCoreService) async -> String {
        // Quick check first
        let quick = displayName(for: aci, in: conversationId, conversations: conversations)
        if quick != String(aci.prefix(min(8, aci.count))) && quick != aci {
            return quick
        }

        // Try profile lookup for contacts
        if let conv = conversations.first(where: { $0.id == conversationId }), !conv.peer.isGroup {
            // For 1:1, we already have the name from roster
            return quick
        }

        // For group members, try profile lookup
        if let name = await rustCore.profileName(uuid: aci) {
            nameCache[aci] = name
            // Also cache in group member cache
            if let conv = conversations.first(where: { $0.id == conversationId }), conv.peer.isGroup {
                groupMemberCache[conversationId, default: [:]][aci] = name
            }
            return name
        }

        return quick
    }

    /// Pre-populate cache from roster contacts
    public func populateFromRoster(_ contacts: [RosterPayload.Contact]) {
        for contact in contacts {
            let id = contact.id
            let label = if contact.name.isEmpty {
                contact.phone.isEmpty ? id : contact.phone
            } else {
                contact.name
            }
            nameCache[id] = label

            // Also index by phone if available
            if !contact.phone.isEmpty {
                nameCache[contact.phone] = label
            }
        }
    }

    /// Pre-populate cache from groups
    public func populateFromGroups(_ groups: [RosterPayload.Group]) {
        // Groups don't have member names in roster, but we have group titles
        for group in groups {
            nameCache["group:\(group.id)"] = group.title.isEmpty ? "Unnamed group" : group.title
        }
    }

    /// Clear all caches (e.g., on logout)
    public func clear() {
        nameCache.removeAll()
        groupMemberCache.removeAll()
    }
}