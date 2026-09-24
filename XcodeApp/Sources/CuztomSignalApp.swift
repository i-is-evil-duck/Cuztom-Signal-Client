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

        Settings {
            SettingsView()
                .environment(viewModel)
        }
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
    var connectionText = "starting"
    var syncNote = "none"
    var accountLine = "—"
    var diagnosticsText = ""

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
        self.liveService = live
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
        guard let controller else { return }
        if body.hasPrefix("/") {
            await controller.sendOrCommand(body, plugins: plugins, ctx: pluginCtx())
            sync()
            return
        }
        await controller.send(body)
        sync()
    }

    func loadMore() async {
        await controller?.loadMore()
        sync()
    }

    func downloadAttachment(messageId: UUID, index: Int) async {
        await controller?.downloadAttachment(messageId: messageId, index: index)
        sync()
    }

    private let plugins = PluginHost(plugins: [InfoPlugin()])

    private func pluginCtx() -> PluginContext {
        // `controller`/`liveService` are Sendable; safe to capture.
        let c = controller
        let live = liveService
        return PluginContext(
            conversations: { await c?.conversations ?? [] },
            recentMessages: { id, n in await c?.messages(in: id, limit: n) ?? [] },
            diagnostics: { await c?.diagnostics() ?? "not started" },
            account: {
                if let me = try? await live?.whoami() {
                    return "\(me.number) · \(String(me.aci.prefix(8)))"
                }
                return "unknown"
            },
            rosterSummary: { live?.lastRosterSummary ?? "no live backend" },
            requestSync: { await c?.requestSync() ?? false }
        )
    }

    func refreshNow() async {
        await controller?.refreshNow()
        sync()
    }

    /// Ask the phone to re-send contacts/groups, then refresh.
    func requestSync() async {
        guard let c = controller else { return }
        syncNote = "sync requested…"
        if await c.requestSync() {
            syncNote = "request sent, waiting for phone…"
            Log.info("manual contact sync requested")
        } else {
            syncNote = "request failed"
            Log.error("manual sync failed")
        }
        await c.refreshNow()
        sync()
    }

    func logout() async {
        guard let c = controller else { return }
        _ = await c.logout()
        liveService = nil
        sync()
        // Back to a fresh QR.
        phase = .starting
        await start()
    }

    private var liveService: RustCoreService?

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
        syncNote = controller.lastSyncNote ?? "none"
        errorMessage = phase == .failed ? errorMessage : controller.lastError
        Task {
            connectionText = String(describing: controller.connection)
            diagnosticsText = await controller.diagnostics()
            if let live = liveService,
               let me = try? await live.whoami() {
                accountLine = "\(me.number) · \(String(me.aci.prefix(8)))"
            }
        }
    }
}
