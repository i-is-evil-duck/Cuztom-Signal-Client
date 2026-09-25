import Foundation

/// Centralized contact name resolution service.
/// Provides consistent ACI/UUID → display name mapping across the app.
public actor ContactResolver {
    private var rustCore: RustCoreService?
    private var nameCache: [String: String] = [:] // aci/uuid -> display name
    private var groupMemberCache: [String: [String: String]] = [:] // groupThreadId -> [aci -> name]

    public init(rustCore: RustCoreService? = nil) {
        self.rustCore = rustCore
    }

    /// Set the RustCoreService for profile lookups
    public func setRustCore(_ rustCore: RustCoreService) {
        self.rustCore = rustCore
    }

    /// Resolve display name for an ACI/UUID in a conversation context
    public func displayName(for aci: String, in conversationId: String, conversations: [Conversation]) -> String {
        let key = Self.normalizedID(aci)
        // "You" for own messages
        if key == "self" || aci == "You" { return "You" }

        // Check conversation peer (1:1 chat)
        if let conv = conversations.first(where: { $0.id == conversationId }) {
            if !conv.peer.isGroup {
                if Self.normalizedID(conv.peer.uuidString ?? "") == key || conv.peer.phone == aci {
                    return conv.title
                }
            } else if let memberName = groupMemberCache[conversationId]?[key] {
                return memberName
            }
        }

        // Check global name cache, including ACI/PNI aliases.
        if let cached = nameCache[key] ?? nameCache[aci] {
            return cached
        }

        // UI-facing fallback: do not expose raw service identifiers.
        return "Unknown"
    }

    /// Resolve display name with RustCore for profile lookups
    public func displayNameWithProfile(for aci: String, in conversationId: String, conversations: [Conversation], rustCore: RustCoreService) async -> String {
        let quick = displayName(for: aci, in: conversationId, conversations: conversations)
        if quick != "Unknown" { return quick }
        let key = Self.normalizedID(aci)

        // For a known 1:1 conversation, the roster title is authoritative.
        if let conv = conversations.first(where: { $0.id == conversationId }), !conv.peer.isGroup {
            return quick
        }

        // Group members may not have a contact row, but a profile key can
        // become available after an authenticated message exchange.
        if let name = await rustCore.profileName(uuid: aci), !name.isEmpty {
            nameCache[key] = name
            if let conv = conversations.first(where: { $0.id == conversationId }), conv.peer.isGroup {
                groupMemberCache[conversationId, default: [:]][key] = name
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
                contact.phone.isEmpty ? "Unknown" : contact.phone
            } else {
                contact.name
            }
            nameCache[Self.normalizedID(id)] = label

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

    private static func normalizedID(_ value: String) -> String {
        value
            .replacingOccurrences(of: "PNI:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
