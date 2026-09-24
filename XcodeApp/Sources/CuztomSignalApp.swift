import SwiftUI
import AppKit
import CuztomSignalCore

@main
struct CuztomSignalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var viewModel = ChatViewModel()

    init() {
        // Capture stdout/stderr (incl. Rust panics) into the diagnostics log.
        // Without this, native crashes vanish with the process.
        if ProcessInfo.processInfo.environment["RUST_BACKTRACE"] == nil {
            setenv("RUST_BACKTRACE", "1", 1)
        }
        redirectStreamsToLog()
    }

    /// Duplicate C-level stdout/stderr into the log file (Rust `eprintln!`
    /// and panic messages land here). Swift `Log` writes the same file.
    private func redirectStreamsToLog() {
        let url = Log.fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        url.path.withCString { path in
            _ = freopen(path, "a+", stdout)
            _ = freopen(path, "a+", stderr)
        }
    }

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

/// Reopen the main window when the dock icon is clicked after closing it.
/// Without this the app sits running with no windows until force-quit.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
            if let window = sender.windows.first(where: { $0.canBecomeMain }) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}

/// Expanded attachment viewer item (image / playable video / file info).
struct PreviewItem: Identifiable, Equatable {
    let id = UUID()
    var url: URL
    var mime: String
    var filename: String
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
    var historyExhausted = false
    var preview: PreviewItem?

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
        historyExhausted = false
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
        guard let controller else { return }
        historyExhausted = false
        let grew = await controller.loadMore()
        if !grew { historyExhausted = true }
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
            selectedThread: { await c?.selectedId },
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
