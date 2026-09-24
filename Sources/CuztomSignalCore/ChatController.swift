import Foundation

/// UI-agnostic chat coordinator. No SwiftUI/Combine here so it builds and
/// tests under Command Line Tools; `XcodeApp` adds a thin @Observable wrapper.
///
/// Flow: `link()` -> load conversations into `store` -> `select()` pages
/// messages -> `send()` via the `SignalService` and mirrors into `store`.
/// M1 swaps the injected service from `MockSignalService` to `RustCoreService`
/// with no changes to this class.
@MainActor
public final class ChatController {
    public private(set) var connection: ConnectionState = .unlinked
    public private(set) var conversations: [Conversation] = []
    public private(set) var selectedId: String?
    public private(set) var messages: [ChatMessage] = []
    public private(set) var linkQR: LinkQR?
    public private(set) var lastError: String?

    private let service: any SignalService
    private let store: MessageStore
    private var observerTask: Task<Void, Never>?

    public init(service: any SignalService, store: MessageStore = MessageStore()) {
        self.service = service
        self.store = store
    }

    public var isLinked: Bool {
        connection == .connected || connection == .syncing
    }

    public func link(deviceName: String = "CuztomMac") async {
        lastError = nil
        guard await begin(deviceName: deviceName) else { return }
        _ = await finish()
    }

    /// Step 1: fetch the provisioning QR. Returns false on error.
    public func begin(deviceName: String = "CuztomMac") async -> Bool {
        lastError = nil
        do {
            linkQR = try await service.beginLinking(deviceName: deviceName)
            connection = .linking
            observeConnection()
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            return false
        }
    }

    /// Step 2: wait for the phone scan, then sync. Returns false on error.
    /// Split from `begin()` so UI can paint the QR while this runs.
    public func finish() async -> Bool {
        do {
            try await service.waitForLink()
            connection = .syncing
            try await refresh()
            connection = .connected
            return true
        } catch {
            lastError = String(describing: error)
            connection = .offline
            return false
        }
    }

    public func refresh() async throws {
        let convs = try await service.fetchConversations()
        for c in convs {
            await store.upsertConversation(c)
            let history = try await service.fetchMessages(conversationId: c.id, limit: 200)
            for m in history { await store.saveMessage(m) }
        }
        conversations = await store.allConversations()
        if let id = selectedId {
            messages = await store.messages(in: id)
        }
    }

    public func select(_ id: String) async {
        selectedId = id
        // Top up from the service so threads opened after sync (or with
        // arrivals since sync) are complete; saveMessage dedupes by id.
        if let history = try? await service.fetchMessages(conversationId: id, limit: 200) {
            for m in history { await store.saveMessage(m) }
        }
        await store.markRead(conversationId: id)
        messages = await store.messages(in: id)
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].unreadCount = 0
        }
    }

    public func send(_ body: String) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let id = selectedId else { return }
        do {
            let msg = try await service.sendText(trimmed, to: id)
            await store.saveMessage(msg)
            messages = await store.messages(in: id)
        } catch {
            lastError = String(describing: error)
        }
    }

    /// Append an inbound message (websocket callback target in M1).
    public func receive(_ message: ChatMessage) async {
        await store.saveMessage(message)
        conversations = await store.allConversations()
        if message.conversationId == selectedId {
            messages = await store.messages(in: message.conversationId)
        }
    }

    private func observeConnection() {
        observerTask?.cancel()
        observerTask = Task { [weak self] in
            guard let stream = self?.service.connectionState else { return }
            for await state in stream {
                await MainActor.run { [weak self] in
                    // Terminal .connected from waitForLink wins; only
                    // surface regressions (offline) from the backend.
                    if state == .offline { self?.connection = .offline }
                }
            }
        }
    }
}
