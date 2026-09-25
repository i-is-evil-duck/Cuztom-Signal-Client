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
        WindowGroup(id: "main") {
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
/// (Checking `NSApp.windows` doesn't work — SwiftUI destroys closed
/// windows — so ContentView hands us the real `openWindow` action.)
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set from the main thread only (ContentView.onAppear / dock reopen).
    nonisolated(unsafe) static var reopenMainWindow: (() -> Void)?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.async {
                Self.reopenMainWindow?()
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
    private let callController = CallController.shared

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
    var replyingTo: ChatMessage?
    var receiptTarget: ChatMessage?
    var emojiTarget: ChatMessage?
    var showCallsSoon = false
    var sendingAttachment = false
    /// Files staged via paperclip / drop / paste, sent on Send.
    var pendingFiles: [URL] = []
    /// Last failed-action message (send/attachment/react/delete).
    var sendError: String?

    // Read receipts settings
    var sendReadReceipts = true
    var sendDeliveryReceipts = true

    // Call state
    var incomingCall: ActiveCall?
    var activeCall: ActiveCall?

    // Typing indicator state
    var typingUsers: [String: (String, Bool)] = [:] // thread -> (sender, isTyping)

    // Cached own ACI for name resolution
    private var cachedSelfAci: String?
    // Guards against an older async selection completing after a newer click.
    private var selectionGeneration = 0
    private var selectionInProgress = false

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
        let store: any MessageStoring
        do {
            store = try SQLiteMessageStore()
            Log.info("SQLiteMessageStore initialized")
        } catch {
            Log.error("SQLiteMessageStore init failed, falling back to in-memory: \(error)")
            store = InMemoryMessageStore()
        }
        let controller = ChatController(service: live, store: store, pluginHost: plugins)
        self.controller = controller
        self.liveService = live
        // Install call callbacks before starting the receive loop; an incoming
        // call can arrive immediately after the linked session resumes.
        callController.onIncomingCallChanged = { [weak self] call in
            guard let self else { return }
            self.incomingCall = self.activeCall == nil ? call : nil
        }
        callController.onActiveCallChanged = { [weak self] call in
            guard let self else { return }
            self.activeCall = call
            if call != nil { self.incomingCall = nil }
        }
        callController.configure(with: live, transport: live)
        // Wire typing indicator callback to update ViewModel state
        controller.onTypingUpdate = { [weak self] thread, sender, started in
            Task { @MainActor in
                if started {
                    self?.typingUsers[thread] = (sender, true)
                } else {
                    self?.typingUsers.removeValue(forKey: thread)
                }
            }
        }
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
        // Configure call controller with the live native signaling/media core.
        succeed(controller)
    }

    func retry() async {
        await start()
    }

    func select(_ id: String) {
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionInProgress = true
        // Update the visible target immediately; the history fetch can yield,
        // but Send must never fall back to the previously selected contact.
        selectedId = id
        messages = []
        historyExhausted = false
        Task { [weak self] in
            guard let self, let controller = self.controller else { return }
            await controller.select(id)
            guard generation == self.selectionGeneration else { return }
            self.selectionInProgress = false
            // Auto-send read receipts when opening a conversation
            if self.sendReadReceipts {
                Task {
                    try? await controller.sendReadReceipts(for: id)
                }
            }
            self.sync()
        }
    }

    func send(_ body: String, to requestedID: String? = nil) async {
        guard let controller else { return }
        let targetID = requestedID ?? selectedId
        guard let targetID else { return }
        sendError = nil
        if body.hasPrefix("/") {
            await controller.sendOrCommand(body, plugins: plugins, ctx: pluginCtx())
            sync()
            return
        }
        if !pendingFiles.isEmpty {
            sendingAttachment = true
            let files = pendingFiles
            pendingFiles = []
            replyingTo = nil
            var first = true
            for url in files {
                let caption = first ? body : ""
                first = false
                await controller.sendAttachment(fileURL: url, caption: caption, to: targetID)
            }
            sendingAttachment = false
            sendError = controller.lastError
            sync()
            try? FileManager.default.removeItem(at: pendingDir())
            return
        }
        if let quote = replyingTo {
            replyingTo = nil
            await controller.sendReply(body: body, to: targetID, quote: quote)
            sendError = controller.lastError
            sync()
            return
        }
        await controller.send(body, to: targetID)
        sendError = controller.lastError
        sync()
    }

    func react(message: ChatMessage, emoji: String) async {
        await controller?.react(messageId: message.id, emoji: emoji)
        sendError = controller?.lastError
        sync()
    }

    func deleteMessage(_ message: ChatMessage, forEveryone: Bool) async {
        await controller?.deleteMessage(id: message.id, forEveryone: forEveryone)
        sendError = controller?.lastError
        sync()
    }

    /// Edit an outgoing message
    var editingMessage: ChatMessage?
    var editDraft = ""

    func editMessage(_ message: ChatMessage) async {
        guard message.direction == .outgoing,
              let id = selectedId else { return }
        // Present edit sheet with current body
        editingMessage = message
        editDraft = message.body
    }

    /// Confirm edit and send to Signal
    func confirmEdit() async {
        guard let msg = editingMessage,
              let id = selectedId else { return }
        do {
            try await controller?.sendMessageEdit(thread: id, targetTs: msg.storeTs ?? 0, newBody: editDraft)
            editingMessage = nil
            editDraft = ""
        } catch {
            sendError = "Edit failed: \(error.localizedDescription)"
        }
        sync()
    }

    /// Cancel edit
    func cancelEdit() {
        editingMessage = nil
        editDraft = ""
    }

    /// Apply a live typing indicator
    func applyTyping(thread: String, senderName: String, started: Bool) {
        if started {
            typingUsers[thread] = (senderName, true)
        } else {
            typingUsers.removeValue(forKey: thread)
        }
    }


/// Send a typing indicator
func sendTyping(started: Bool) async {
    guard let id = selectedId,
          let controller else { return }
    await controller.sendTyping(thread: id, started: started)
}

    // MARK: - Calls (M4)

    /// Start an outgoing voice call
    func startVoiceCall() async {
        guard let id = selectedId,
              let conv = conversations.first(where: { $0.id == id }),
              !conv.peer.isGroup else { return }
        do {
            _ = try await callController.startCall(to: id, mediaType: .voice, peer: conv.peer)
        } catch {
            sendError = "Call failed: \(error.localizedDescription)"
            sync()
        }
    }

    /// Start an outgoing video call
    func startVideoCall() async {
        guard let id = selectedId,
              let conv = conversations.first(where: { $0.id == id }),
              !conv.peer.isGroup else { return }
        do {
            _ = try await callController.startCall(to: id, mediaType: .video, peer: conv.peer)
        } catch {
            sendError = "Call failed: \(error.localizedDescription)"
            sync()
        }
    }

    /// Answer incoming call
    func answerCall() async {
        guard let call = incomingCall else { return }
        do {
            try await callController.answerCall(call)
            // Keep the view-model transition deterministic even if the native
            // RingRTC state callback arrives a little later.
            incomingCall = nil
            activeCall = call
        } catch {
            sendError = "Answer failed: \(error.localizedDescription)"
            sync()
        }
    }

    /// Decline incoming call
    func declineCall() async {
        guard let call = incomingCall else { return }
        do {
            try await callController.declineCall(call)
        } catch {
            sendError = "Decline failed: \(error.localizedDescription)"
            sync()
        }
    }

    /// End active call
    func endCall() async {
        guard let call = activeCall ?? incomingCall else { return }
        do {
            try await callController.endCall(call)
        } catch {
            sendError = "End call failed: \(error.localizedDescription)"
            sync()
        }
    }

    func sendAttachment(url: URL, caption: String) async {
        sendingAttachment = true
        sendError = nil
        await controller?.sendAttachment(fileURL: url, caption: caption)
        sendError = controller?.lastError
        sendingAttachment = false
        sync()
    }

    /// Stage dropped/pasted files (copied into Caches/pending).
    func stageFiles(_ urls: [URL]) {
        let dir = pendingDir()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var staged = 0
        for url in urls {
            // Finder drops / pasteboard URLs are security-scoped: without
            // this the copy fails silently with a permission error.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let dest = dir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.removeItem(at: dest)
            if (try? FileManager.default.copyItem(at: url, to: dest)) != nil {
                if !pendingFiles.contains(dest) { pendingFiles.append(dest) }
                staged += 1
            } else {
                Log.error("stage failed: \(url.lastPathComponent)")
            }
        }
        Log.info("staged \(staged)/\(urls.count) files")
    }

    /// Paste images/files from the clipboard into the pending tray.
    func pasteBoard() {
        let pb = NSPasteboard.general
        var urls: [URL] = []
        if let objects = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: objects.filter { $0.isFileURL })
        }
        if urls.isEmpty, let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff) {
            let dest = pendingDir().appendingPathComponent("paste-\(Int(Date().timeIntervalSince1970)).png")
            try? FileManager.default.createDirectory(at: pendingDir(), withIntermediateDirectories: true)
            if let rep = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: rep)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dest)
                urls.append(dest)
            }
        }
        if !urls.isEmpty { stageFiles(urls) }
    }

    private func pendingDir() -> URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CuztomSignal/pending")
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
        callController.reset()
        // Clear all data from Rust core (DB, caches, keychain). This performs
        // the service logout itself; do not issue a second logout afterward.
        if let live = liveService {
            do {
                try await live.clearAllData()
            } catch {
                Log.error("service data wipe failed: \(error)")
            }
        }
        // Clear the Swift-side store/controller after the service wipe.
        await c.resetAfterServiceLogout()
        liveService = nil
        cachedSelfAci = nil
        selectionGeneration += 1
        selectionInProgress = false
        selectedId = nil
        sync()
        // Back to a fresh QR.
        phase = .starting
        await start()
    }

    private var liveService: RustCoreService?

    private func succeed(_ controller: ChatController) {
        sync()
        phase = .linked
        if selectedId == nil, let first = conversations.first {
            select(first.id)
        }
    }

    private func fail(_ controller: ChatController) {
        sync()
        errorMessage = controller.lastError ?? "unknown error"
        phase = .failed
    }

    /// Resolve a friendly name for an ACI/UUID in a conversation.
    /// UI-facing code should never fall back to a raw service identifier.
    func displayName(for aci: String, in conversationId: String) -> String {
        let bareID = aci.replacingOccurrences(of: "PNI:", with: "")
        if aci == "self" || aci == "You" { return "You" }

        let knownSelf = cachedSelfAci ?? controller?.selfAci
        if let knownSelf, bareID.caseInsensitiveCompare(knownSelf) == .orderedSame {
            return "You"
        }

        // Every synced contact has a canonical 1:1 conversation. Reuse its
        // friendly title for group messages, receipts, and typing indicators.
        if let contact = conversations.first(where: { conversation in
            guard !conversation.peer.isGroup else { return false }
            return conversation.peer.uuidString?.caseInsensitiveCompare(bareID) == .orderedSame
                || conversation.peer.phone == aci
        }) {
            return contact.title
        }

        if let group = conversations.first(where: { $0.id == conversationId }),
           group.peer.groupId?.caseInsensitiveCompare(bareID) == .orderedSame {
            return group.title
        }

        return "Unknown"
    }

    /// Two-letter initials for group sender chips and sender labels.
    func initials(for name: String) -> String {
        let words = name
            .split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .filter { !$0.isEmpty }
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    private func sync() {
        guard let controller else { return }
        conversations = controller.conversations
        if !selectionInProgress {
            selectedId = controller.selectedId
            messages = controller.messages
        }
        linkQR = controller.linkQR
        isLinked = controller.isLinked
        syncNote = controller.lastSyncNote ?? "none"
        errorMessage = phase == .failed ? errorMessage : controller.lastError
        Task {
            connectionText = String(describing: controller.connection)
            diagnosticsText = await controller.diagnostics()
            if let live = liveService,
               let me = try? await live.whoami() {
                let friendlyName = (try? await live.profileName(uuid: me.aci))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "You"
                accountLine = "\(me.number) · \(friendlyName)"
                cachedSelfAci = me.aci
            }
        }
    }
}
