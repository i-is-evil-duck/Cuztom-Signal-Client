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
        // Live backend only — the demo is gone. Without the rust dylib
        // there is nothing to connect to, so fail loudly with Retry.
        let live = RustCoreService()
        guard live.loadLibrary() else {
            backendName = "missing"
            errorMessage = "rust core not found — rebuild: cd rust-core && cargo build --release"
            phase = .failed
            return
        }
        backendName = "Live"
        let controller = ChatController(service: live)
        self.controller = controller
        guard await controller.begin() else {
            fail(controller)
            return
        }
        if controller.linkQR != nil {
            // Fresh link: paint the QR while the phone scan completes.
            phase = .linking
            sync()
        }
        guard await controller.finish() else {
            fail(controller)
            return
        }
        succeed(controller)
    }

    func retry() async {
        await start()
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
}
