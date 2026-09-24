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

enum LinkPhase: Equatable {
    case starting
    case linking
    case linked
    case failed
}

/// Thin @Observable wrapper over `ChatController` (which owns all logic and
/// is unit-tested under CLT). Live backend when the rust dylib is present,
/// Mock only as an explicit fallback — never a silent switch.
@Observable
@MainActor
final class ChatViewModel {
    private var controller: ChatController?

    var phase = LinkPhase.starting
    var conversations: [Conversation] = []
    var selectedId: String?
    var messages: [ChatMessage] = []
    var linkQR: LinkQR?
    var isLinked = false
    var backendName = "…"
    var errorMessage: String?

    func start() async {
        phase = .starting
        errorMessage = nil
        let live = RustCoreService()
        if live.loadLibrary() {
            backendName = "Live"
            let controller = ChatController(service: live)
            self.controller = controller
            guard await controller.begin() else {
                fail(controller)
                return
            }
            phase = .linking
            sync()
            guard await controller.finish() else {
                fail(controller)
                return
            }
            succeed(controller)
        } else {
            await startDemo()
        }
    }

    func retry() async {
        await start()
    }

    func startDemo() async {
        phase = .starting
        errorMessage = nil
        let (convs, msgs) = Self.previewData()
        let controller = ChatController(service: MockSignalService(seedConversations: convs, seedMessages: msgs))
        self.controller = controller
        backendName = "Mock"
        await controller.link()
        sync()
        phase = .linked
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

    private func succeed(_ controller: ChatController) {
        sync()
        phase = .linked
        if let first = conversations.first {
            Task { await self.select(first.id) }
        }
    }

    private func fail(_ controller: ChatController) {
        sync()
        errorMessage = controller.lastError ?? "unknown error"
        phase = .failed
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
