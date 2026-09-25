import Foundation

/// Canonical thread ID parsing and conversion utilities.
/// Single source of truth for thread ID ↔ SignalAddress ↔ groupId conversions.
public enum ThreadID {
    /// Thread ID prefix for 1:1 conversations
    public static let contactPrefix = "contact:"
    /// Thread ID prefix for groups
    public static let groupPrefix = "group:"

    /// Parse a thread ID into its components
    public static func parse(_ threadId: String) -> ThreadComponents {
        if threadId.hasPrefix(groupPrefix) {
            let masterKey = String(threadId.dropFirst(groupPrefix.count))
            return .group(masterKey: masterKey)
        } else if threadId.hasPrefix(contactPrefix) {
            let uuid = String(threadId.dropFirst(contactPrefix.count))
            return .contact(uuid: uuid)
        } else {
            // Fallback: treat as contact UUID
            return .contact(uuid: threadId)
        }
    }

    /// Thread ID components
    public enum ThreadComponents: Equatable, Sendable {
        case contact(uuid: String)
        case group(masterKey: String)

        public var threadId: String {
            switch self {
            case .contact(let uuid): return "\(contactPrefix)\(uuid)"
            case .group(let masterKey): return "\(groupPrefix)\(masterKey)"
            }
        }

        public var isGroup: Bool {
            if case .group = self { return true }
            return false
        }

        public var contactUUID: String? {
            if case .contact(let uuid) = self { return uuid }
            return nil
        }

        public var groupMasterKey: String? {
            if case .group(let masterKey) = self { return masterKey }
            return nil
        }
    }

    /// Create a SignalAddress from a thread ID
    public static func signalAddress(from threadId: String) -> SignalAddress {
        let components = parse(threadId)
        switch components {
        case .contact(let uuid):
            return SignalAddress(uuidString: uuid, threadId: threadId)
        case .group(let masterKey):
            return SignalAddress(groupId: masterKey, threadId: threadId)
        }
    }

    /// Get thread ID from SignalAddress
    public static func threadId(from address: SignalAddress) -> String {
        if let threadId = address.threadId, !threadId.isEmpty {
            return threadId
        }
        if let groupId = address.groupId {
            return "\(groupPrefix)\(groupId)"
        }
        if let uuid = address.uuidString {
            return "\(contactPrefix)\(uuid)"
        }
        return "unknown"
    }

    /// Check if a thread ID represents a group
    public static func isGroup(_ threadId: String) -> Bool {
        threadId.hasPrefix(groupPrefix)
    }

    /// Check if a thread ID represents a contact
    public static func isContact(_ threadId: String) -> Bool {
        threadId.hasPrefix(contactPrefix)
    }

    /// Extract group master key from thread ID (returns nil if not a group)
    public static func groupMasterKey(from threadId: String) -> String? {
        guard threadId.hasPrefix(groupPrefix) else { return nil }
        return String(threadId.dropFirst(groupPrefix.count))
    }

    /// Extract contact UUID from thread ID (returns nil if not a contact)
    public static func contactUUID(from threadId: String) -> String? {
        guard threadId.hasPrefix(contactPrefix) else { return nil }
        return String(threadId.dropFirst(contactPrefix.count))
    }

    /// Create group thread ID from master key
    public static func groupThreadId(masterKey: String) -> String {
        "\(groupPrefix)\(masterKey)"
    }

    /// Create contact thread ID from UUID
    public static func contactThreadId(uuid: String) -> String {
        "\(contactPrefix)\(uuid)"
    }
}

extension SignalAddress {
    /// Convenience: get thread ID from address components
    public var derivedThreadId: String {
        ThreadID.threadId(from: self)
    }

    /// Convenience: check if this address represents a group
    public var isGroupThread: Bool {
        groupId != nil
    }
}