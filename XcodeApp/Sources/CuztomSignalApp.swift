import SwiftUI
import CuztomSignalCore

@main
struct CuztomSignalApp: App {
    @State private var viewModel = ChatViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(viewModel)
                .frame(minWidth: 900, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}

@Observable
@MainActor
final class ChatViewModel {
    var store = MessageStore()
    var service: (any SignalService)?
    var conversations: [Conversation] = []
    var selectedId: String?
    var messages: [ChatMessage] = []
    var linkQR: LinkQR?
    var isLinked = false

    init(service: (any SignalService)? = nil) {
        self.service = service
    }

    func startLinking(deviceName: String = "CuztomMac") async {
        let svc = MockSignalService(seedConversations: Self.previewData().0,
                                    seedMessages: Self.previewData().1)
        self.service = svc
        do {
            linkQR = try await svc.beginLinking(deviceName: deviceName)
            try await svc.waitForLink()
            isLinked = true
            conversations = try await svc.fetchConversations()
            for c in conversations { await store.upsertConversation(c) }
        } catch {
            print("link failed: \(error)")
        }
    }

    func select(_ id: String) async {
        selectedId = id
        await store.markRead(conversationId: id)
        messages = await store.messages(in: id)
        if let idx = conversations.firstIndex(where: { $0.id == id }) {
            conversations[idx].unreadCount = 0
        }
    }

    func send(_ body: String) async {
        guard let id = selectedId, let svc = service else { return }
        do {
            let msg = try await svc.sendText(body, to: id)
            await store.saveMessage(msg)
            messages = await store.messages(in: id)
        } catch {
            print("send failed: \(error)")
        }
    }

    static func previewData() -> ([Conversation], [String: [ChatMessage]]) {
        let a = Conversation(id: "c1", title: "Alice", peer: SignalAddress(phone: "+1001"),
                             lastMessagePreview: "hey!", unreadCount: 1)
        let g = Conversation(id: "group.abc", title: "Reels (bridge testers)",
                             peer: SignalAddress(groupId: "group.abc"),
                             lastMessagePreview: "sent a reel", unreadCount: 0)
        let m = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1001"),
                            body: "hey! this is a mock thread", direction: .incoming, status: .delivered)
        return ([a, g], ["c1": [m]])
    }
}
