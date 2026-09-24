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

/// Thin @Observable wrapper over `ChatController` (which owns all logic and
/// is unit-tested under CLT). Property names are the exact surface
/// `Views.swift` binds to; M1 swaps the injected service to `RustCoreService`.
@Observable
@MainActor
final class ChatViewModel {
    private var controller: ChatController?

    var conversations: [Conversation] = []
    var selectedId: String?
    var messages: [ChatMessage] = []
    var linkQR: LinkQR?
    var isLinked = false
    var backendName = "…"

    func startLinking(deviceName: String = "CuztomMac") async {
        // Live backend when the rust dylib sits next to the build;
        // otherwise the deterministic mock (Xcode previews, CI).
        let live = RustCoreService()
        let svc: any SignalService
        if live.loadLibrary() {
            svc = live
            backendName = "Live"
        } else {
            let (convs, msgs) = Self.previewData()
            svc = MockSignalService(seedConversations: convs, seedMessages: msgs)
            backendName = "Mock"
        }
        let controller = ChatController(service: svc)
        self.controller = controller
        await controller.link(deviceName: deviceName)
        sync()
        if let first = conversations.first {
            await select(first.id)
        }
    }

    func select(_ id: String) async {
        await controller?.select(id)
        sync()
    }

    func send(_ body: String) async {
        await controller?.send(body)
        sync()
    }

    private func sync() {
        guard let controller else { return }
        conversations = controller.conversations
        selectedId = controller.selectedId
        messages = controller.messages
        linkQR = controller.linkQR
        isLinked = controller.isLinked
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
