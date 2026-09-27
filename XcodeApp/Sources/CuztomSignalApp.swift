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
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
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
    /// Built per session rather than using `GroupCallController.shared`.
    ///
    /// The shared instance is constructed with an `EmptyGroupRoster`, so a
    /// controller that is not given the real roster silently reports an empty
    /// membership and can never resolve an inbound group's id. That is exactly
    /// what happened: calls placed with no roster at all, and inbound calls
    /// discarded as unresolvable.
    private var groupCallController: GroupCallController?
    private var groupRoster: NativeGroupRoster?

    /// The group call in progress, or nil. Kept as a plain mirror of the
    /// controller's own state so the views can render it without reaching into
    /// a second observable.
    var groupCall: GroupCallState?
    /// The live native core, kept so the group call's video feeds can read frames.
    private(set) var coreService: RustCoreService?

    var phase = LinkPhase.starting
    var conversations: [Conversation] = []
    var selectedId: String?
    var messages: [ChatMessage] = []
    var linkQR: LinkQR?
    var isLinked = false
    var buildVersionTag = BuildInfo.displayTag
    var errorMessage: String?
    var connectionText = "starting"
    var syncNote = "none"
    var accountLine = "—"
    var diagnosticsText = ""
    var historyExhausted = false
    var preview: PreviewItem?
    var receiptTarget: ChatMessage?
    var emojiTarget: ChatMessage?
    var showCallsSoon = false

    /// Composer state is keyed by conversation so switching chats never sends
    /// a draft, reply, or staged file to the newly selected peer.
    var draft: String {
        get {
            guard let selectedId else { return "" }
            return draftsByConversation[selectedId] ?? ""
        }
        set {
            guard let selectedId else { return }
            draftsByConversation[selectedId] = newValue
        }
    }

    var replyingTo: ChatMessage? {
        get {
            guard let selectedId else { return nil }
            return repliesByConversation[selectedId]
        }
        set {
            guard let selectedId else { return }
            repliesByConversation[selectedId] = newValue
        }
    }

    var pendingFiles: [URL] {
        get {
            guard let selectedId else { return [] }
            return pendingFilesByConversation[selectedId] ?? []
        }
        set {
            guard let selectedId else { return }
            pendingFilesByConversation[selectedId] = newValue
        }
    }

    var sendingAttachment: Bool {
        get {
            guard let selectedId else { return false }
            return sendingAttachmentByConversation[selectedId] ?? false
        }
        set {
            guard let selectedId else { return }
            sendingAttachmentByConversation[selectedId] = newValue
        }
    }

    var sendError: String? {
        get {
            guard let selectedId else { return nil }
            return sendErrorsByConversation[selectedId]
        }
        set {
            guard let selectedId else { return }
            sendErrorsByConversation[selectedId] = newValue
        }
    }
    var isLoggingOut = false

    // Read receipts settings
    var sendReadReceipts = true
    var sendDeliveryReceipts = true

    // Call state
    var incomingCall: ActiveCall?
    var activeCall: ActiveCall?

    // Typing indicator state
    var typingUsers: [String: [String: (String, Bool)]] = [:] // thread -> sender ID -> (name, isTyping)

    // Cached own ACI for name resolution
    private var cachedSelfAci: String?
    private var draftsByConversation: [String: String] = [:]
    private var repliesByConversation: [String: ChatMessage] = [:]
    private var pendingFilesByConversation: [String: [URL]] = [:]
    private var sendingAttachmentByConversation: [String: Bool] = [:]
    private var sendErrorsByConversation: [String: String] = [:]
    // Guards against an older async selection completing after a newer click.
    private var selectionGeneration = 0
    private var selectionInProgress = false
    // SwiftUI can evaluate the root .task more than once while a window is
    // being restored. Only one service/controller may be started at a time.
    private var starting = false
    private var notifiedCallIDs: Set<UUID> = []
    private var diagnosticsTask: Task<Void, Never>?
    private var selectionTask: Task<Void, Never>?

    var notificationsEnabled: Bool = NotificationManager.shared.enabled {
        didSet {
            NotificationManager.shared.enabled = notificationsEnabled
            if notificationsEnabled {
                Task { _ = await NotificationManager.shared.requestAuthorization() }
            } else {
                NotificationManager.shared.cancelAll()
            }
        }
    }

    /// Link previews are opt-in because fetching a message URL reveals the
    /// recipient's IP address and can expose message content to a remote site.
    var linkPreviewsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "linkPreviewsEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "linkPreviewsEnabled") }
    }

    var showNotificationPreviews: Bool {
        get { NotificationManager.shared.showMessagePreviews }
        set { NotificationManager.shared.showMessagePreviews = newValue }
    }

    func start() async {
        guard !starting else { return }
        starting = true
        defer { starting = false }
        let oldDiagnostics = diagnosticsTask
        let oldSelection = selectionTask
        diagnosticsTask = nil
        selectionTask = nil
        oldDiagnostics?.cancel()
        oldSelection?.cancel()
        await oldDiagnostics?.value
        await oldSelection?.value
        await controller?.shutdown()
        controller = nil
        liveService = nil
        selectionInProgress = false
        phase = .starting
        errorMessage = nil
        NotificationManager.shared.configure()
        // Native backend only — the demo is gone. Without the rust dylib
        // there is nothing to connect to, so fail loudly with Retry.
        buildVersionTag = BuildInfo.displayTag
        let live = RustCoreService()
        // Kept so the group call's video feeds can read frames. The feeds poll the
        // core directly, and a poll that had no service would silently never draw
        // anything.
        coreService = live
        guard live.loadLibrary() else {
            errorMessage = "rust core not found — rebuild: cd rust-core && cargo build --release"
            phase = .failed
            return
        }
        let store: any MessageStoring
        do {
            store = try SQLiteMessageStore()
            Log.info("SQLiteMessageStore initialized")
        } catch {
            // A missing/wrong presentation key is a security/recovery error;
            // silently falling back to memory would hide data loss and make
            // logout/relink behavior diverge from production persistence.
            Log.error("SQLiteMessageStore init failed: \(error)")
            errorMessage = "Presentation database unavailable: \(error.localizedDescription)"
            phase = .failed
            return
        }
        let controller = ChatController(service: live, store: store, pluginHost: plugins)
        self.controller = controller
        self.liveService = live
        controller.onStateChange = { [weak self] in
            self?.sync()
        }
        controller.onIncomingMessage = { [weak self] message in
            self?.notifyIncomingMessage(message)
        }
        // Install call callbacks before starting the receive loop; an incoming
        // call can arrive immediately after the linked session resumes.
        callController.onIncomingCallChanged = { [weak self] call in
            guard let self else { return }
            let previousIncoming = self.incomingCall
            let wasActive = self.activeCall != nil
            self.incomingCall = wasActive ? nil : call
            if call == nil, let previousIncoming {
                NotificationManager.shared.cancelIncomingCall(
                    identifier: previousIncoming.callRecord.id.uuidString
                )
            }
            if let call, !wasActive, self.activeCall == nil,
               self.notifiedCallIDs.insert(call.callRecord.id).inserted {
                let peer = call.callRecord.remotePeer
                let caller = peer.displayName
                    ?? peer.uuidString.map { self.displayName(for: $0, in: call.callRecord.conversationId) }
                    ?? peer.phone
                    ?? "Unknown"
                let title = self.conversations.first(where: { $0.id == call.callRecord.conversationId })?.title
                    ?? "Call"
                NotificationManager.shared.notifyIncomingCall(
                    callerName: caller,
                    conversationTitle: title,
                    identifier: call.callRecord.id.uuidString
                )
            }
        }
        callController.onActiveCallChanged = { [weak self] call in
            guard let self else { return }
            self.activeCall = call
            if call != nil { self.incomingCall = nil }
        }
        await callController.configure(with: live, transport: live)
        // Group calls need a roster and the ZK group id map, both from the same
        // store, so they are configured together.
        let roster = NativeGroupRoster(service: live)
        groupRoster = roster
        // The controller must hold the same roster the view model primes, or a
        // call is placed with no members and inbound groups stay unresolvable.
        // The CDN hosts come from the live service configuration, not from a
        // constant: they differ between staging and production, and a hardcoded
        // host fails as an unreachable endpoint rather than as a configuration
        // mistake.
        let groupCalls = GroupCallController(
            roster: roster,
            redeemer: NativeGroupCallRedeemer(service: live)
        )
        groupCallController = groupCalls
        // The controller is a Combine object and this model is `@Observable`, so
        // nothing would re-render on a ring without being told. The banner is the
        // only way an incoming call becomes visible, so it cannot depend on the
        // view happening to read through to the controller.
        groupCalls.onIncomingRingChanged = { [weak self] ring in
            Task { @MainActor in
                guard let self else { return }
                self.incomingGroupCall = ring
                self.sync()
            }
        }
        groupCalls.configure(with: live)
        // An inbound group call names a group by identifier, and one for a group
        // this device is not in cannot be joined, so the map is what decides
        // whether a ringing call is answerable at all.
        live.onGroupCallSignal = { [weak self] signal in
            Task { @MainActor [weak self] in
                guard let self, let groupCalls = self.groupCallController else { return }
                await groupCalls.receive(event: signal)
                self.groupCall = groupCalls.current
                self.sync()
            }
        }
        // The id-to-key map is deliberately *not* loaded here. It lives behind
        // the sync loop's live manager, which is not running at configure time,
        // so an eager read fails and inbound group calls stay unresolvable for
        // the rest of the process. `NativeGroupRoster` loads it on first use.
        // Wire typing indicator callback to update ViewModel state
        controller.onTypingUpdateWithID = { [weak self] thread, senderID, senderName, started in
            Task { @MainActor in
                guard let self else { return }
                var users = self.typingUsers[thread] ?? [:]
                if started {
                    users[senderID] = (senderName, true)
                } else {
                    users.removeValue(forKey: senderID)
                }
                if users.isEmpty {
                    self.typingUsers.removeValue(forKey: thread)
                } else {
                    self.typingUsers[thread] = users
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
        selectionTask?.cancel()
        selectionGeneration += 1
        let generation = selectionGeneration
        selectionInProgress = true
        // Update the visible target immediately; the history fetch can yield,
        // but Send must never fall back to the previously selected contact.
        selectedId = id
        messages = []
        historyExhausted = false
        // These are intentionally transient, unlike the composer cache. A
        // sheet/popover from the previous conversation must not cover the new
        // one or retain an action target after the selection changes.
        preview = nil
        receiptTarget = nil
        emojiTarget = nil
        editingMessage = nil
        editDraft = ""
        sendErrorsByConversation[id] = nil
        selectionTask = Task { [weak self] in
            guard let self, let controller = self.controller else { return }
            await controller.select(id)
            guard !Task.isCancelled, generation == self.selectionGeneration else { return }
            self.selectionInProgress = false
            // Auto-send read receipts when opening a conversation. Keep this
            // inside the tracked selection task so logout can await it.
            if self.sendReadReceipts {
                try? await controller.sendReadReceipts(for: id)
            }
            guard !Task.isCancelled, generation == self.selectionGeneration else { return }
            self.sync()
        }
    }

    func send(_ body: String, to requestedID: String? = nil) async {
        guard let controller else { return }
        let targetID = requestedID ?? selectedId
        guard let targetID else { return }

        // Snapshot all composer state by target. An upload may outlive the
        // selection change; completion must update the old conversation's
        // cache, never the newly visible one.
        sendErrorsByConversation[targetID] = nil
        if body.hasPrefix("/") {
            await controller.sendOrCommand(
                body,
                plugins: plugins,
                ctx: pluginCtx(selectedThread: targetID),
                to: targetID
            )
            sendErrorsByConversation[targetID] = controller.lastError
            sync()
            return
        }

        let files = pendingFilesByConversation[targetID] ?? []
        let quote = repliesByConversation[targetID]
        if !files.isEmpty {
            sendingAttachmentByConversation[targetID] = true
            var remaining: [URL] = []
            var firstFile = true
            var replyWasSent = false

            // The native attachment command does not carry a quote yet. If a
            // text reply is present, send it first rather than silently
            // dropping the quote; subsequent files remain ordinary uploads.
            if let quote, !body.isEmpty {
                await controller.sendReply(body: body, to: targetID, quote: quote)
                if controller.lastError == nil {
                    replyWasSent = true
                    repliesByConversation[targetID] = nil
                }
            }

            if replyWasSent || quote == nil {
                for url in files {
                    let caption = firstFile && !replyWasSent ? body : ""
                    firstFile = false
                    if await controller.sendAttachment(fileURL: url, caption: caption, to: targetID) {
                        try? FileManager.default.removeItem(at: url)
                    } else {
                        remaining.append(url)
                    }
                }
            } else {
                remaining = files
                sendErrorsByConversation[targetID] = "A reply with only attachments is not supported yet"
            }

            pendingFilesByConversation[targetID] = remaining
            sendingAttachmentByConversation[targetID] = false
            if controller.lastError != nil {
                sendErrorsByConversation[targetID] = controller.lastError
            }
            if remaining.isEmpty {
                repliesByConversation[targetID] = nil
                try? FileManager.default.removeItem(at: pendingDir(for: targetID))
            }
            sync()
            return
        }

        if let quote {
            await controller.sendReply(body: body, to: targetID, quote: quote)
            sendErrorsByConversation[targetID] = controller.lastError
            if controller.lastError == nil {
                repliesByConversation[targetID] = nil
            }
            sync()
            return
        }

        await controller.send(body, to: targetID)
        sendErrorsByConversation[targetID] = controller.lastError
        sync()
    }

    func react(message: ChatMessage, emoji: String) async {
        guard let controller else { return }
        sendErrorsByConversation[message.conversationId] = nil
        let succeeded = await controller.react(messageId: message.id, emoji: emoji)
        if !succeeded {
            sendErrorsByConversation[message.conversationId] = controller.lastError ?? "Reaction failed"
        }
        sync()
    }

    func deleteMessage(_ message: ChatMessage, forEveryone: Bool) async {
        guard let controller else { return }
        sendErrorsByConversation[message.conversationId] = nil
        let succeeded = await controller.deleteMessage(id: message.id, forEveryone: forEveryone)
        if !succeeded {
            sendErrorsByConversation[message.conversationId] = controller.lastError ?? "Delete failed"
        }
        sync()
    }

    /// Edit an outgoing message
    var editingMessage: ChatMessage?
    var editDraft = ""

    func editMessage(_ message: ChatMessage) async {
        guard message.direction == .outgoing,
              selectedId != nil else { return }
        // Present edit sheet with current body
        editingMessage = message
        editDraft = message.body
    }

    /// Confirm edit and send to Signal
    func confirmEdit() async {
        guard let msg = editingMessage,
              let id = selectedId else { return }
        let sentTs = await controller?.sendMessageEdit(
            thread: id,
            targetTs: msg.storeTs ?? 0,
            newBody: editDraft
        ) ?? -1
        if sentTs < 0 {
            sendError = controller?.lastError ?? "Edit failed"
        } else {
            editingMessage = nil
            editDraft = ""
        }
        sync()
    }

    /// Cancel edit
    func cancelEdit() {
        editingMessage = nil
        editDraft = ""
    }

    /// Apply a live typing indicator
    func applyTyping(
        thread: String,
        senderName: String,
        started: Bool,
        senderID: String? = nil
    ) {
        let key = senderID ?? senderName
        var users = typingUsers[thread] ?? [:]
        if started {
            users[key] = (senderName, true)
        } else {
            users.removeValue(forKey: key)
        }
        if users.isEmpty {
            typingUsers.removeValue(forKey: thread)
        } else {
            typingUsers[thread] = users
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

    // MARK: - Group calls

    /// Start a group call in the selected conversation.
    ///
    /// The roster is read first, on purpose. A call placed without it connects
    /// with nobody identifiable in it, and the failure only shows up later as
    /// unidentified participants, so an unreadable group fails here instead.
    func startGroupCall() async {
        guard let id = selectedId,
              let conv = conversations.first(where: { $0.id == id }),
              conv.peer.isGroup,
              let masterKey = ThreadID.parse(id).groupMasterKey else { return }
        guard let roster = groupRoster, let groupCalls = groupCallController else {
            sendError = "Group calls are not ready yet"
            return
        }
        do {
            // The roster is primed by the controller, not here. Doing it in both
            // places meant the answered-ring path - added later - silently missed
            // it, and a call joined without a member map connects and is unusable.
            groupCall = try await groupCalls.startCall(
                masterKeyHex: masterKey,
                title: conv.title
            )
        } catch {
            sendError = "Group call failed: \(GroupCallController.describe(error))"
        }
        sync()
    }

    /// End the group call in progress.
    func endGroupCall() async {
        await groupCallController?.end()
        groupCall = nil
        // Frames belong to the call that has ended, and so does the memory they
        // occupy.
        releaseGroupCallVideo()
        sync()
    }

    /// Mute or unmute this device's microphone in the live group call.
    ///
    /// Routed through the controller rather than tracked here, because the
    /// controller is what knows whether the core confirmed the change. The banner
    /// must not claim a microphone state the call has not been told about.
    func setGroupCallMuted(_ muted: Bool) async {
        await groupCallController?.setMuted(muted)
        groupCall = groupCallController?.current
        sync()
    }

    /// Turn this device's camera on or off in the live group call.
    func setGroupCallCameraOff(_ off: Bool) async {
        await groupCallController?.setCameraOff(off)
        groupCall = groupCallController?.current
        sync()
    }

    /// A video feed per participant who is sending video.
    ///
    /// Derived from the call's own participant list rather than kept in step with
    /// it separately, so a feed exists exactly while somebody is in the call. A
    /// feed for someone who has left would keep polling the core for frames nobody
    /// is drawing.
    ///
    /// The feed objects themselves are cached, because a feed holds the last frame
    /// it drew and the sequence it has already shown — rebuilding one per render
    /// would throw both away and redraw from nothing.
    private var videoFeedCache: [UInt32: RemoteVideoFeed] = [:]

    var groupCallVideoFeeds: [RemoteVideoFeed] {
        guard let call = groupCall, call.phase == .connected else {
            videoFeedCache = [:]
            return []
        }
        // Only participants the SFU says are forwarding video, and only once it has
        // told us a height. A tile for someone sending nothing is a black
        // rectangle, which reads as broken video rather than as no video.
        let sending = call.participants
            .filter { $0.isForwardingVideo == true && $0.videoHeight > 0 }
            .map(\.demuxId)
        // Forget anybody who has stopped, so a departed participant's last frame
        // is released rather than held.
        let keep = Set(sending)
        videoFeedCache = videoFeedCache.filter { keep.contains($0.key) }
        return sending.map { demuxId in
            if let kept = videoFeedCache[demuxId] { return kept }
            let made = RemoteVideoFeed(demuxId: demuxId, service: coreService)
            videoFeedCache[demuxId] = made
            return made
        }
    }

    /// Release every frame, on a call ending.
    func releaseGroupCallVideo() {
        videoFeedCache = [:]
        Task { await coreService?.groupCallResetVideo() }
    }
    /// The group call somebody is ringing us for, if any.
    ///
    /// Mirrored here rather than read through the controller, because the
    /// controller is a Combine `ObservableObject` and this is a Swift
    /// `@Observable` model: a computed property reading across the two registers
    /// no observation dependency, so the view is never told to re-read and the
    /// banner never appears even though the ring arrived. Mirrored, reading it is
    /// a real dependency.
    private(set) var incomingGroupCall: GroupCallController.GroupCallRing?

    /// Answer an incoming group call.
    func answerGroupCall(_ ring: GroupCallController.GroupCallRing) async {
        guard let groupCalls = groupCallController else { return }
        groupCall = await groupCalls.answer(ring)
        sync()
    }

    /// Dismiss an incoming group call without answering it.
    func declineGroupCall(_ ring: GroupCallController.GroupCallRing) {
        groupCallController?.decline(ring)
        sync()
    }

    /// Place a group call to a specific conversation, from its list row.
    func startGroupCall(conversationId: String) async {
        selectedId = conversationId
        sync()
        await startGroupCall()
    }

    /// Answer incoming call
    func answerCall() async {
        guard let call = incomingCall else { return }
        NotificationManager.shared.cancelIncomingCall(identifier: call.callRecord.id.uuidString)
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
        NotificationManager.shared.cancelIncomingCall(identifier: call.callRecord.id.uuidString)
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
        NotificationManager.shared.cancelIncomingCall(identifier: call.callRecord.id.uuidString)
        do {
            try await callController.endCall(call)
        } catch {
            sendError = "End call failed: \(error.localizedDescription)"
            sync()
        }
    }

    func sendAttachment(url: URL, caption: String, to requestedID: String? = nil) async {
        guard let controller, let targetID = requestedID ?? selectedId else { return }
        sendingAttachmentByConversation[targetID] = true
        sendErrorsByConversation[targetID] = nil
        _ = await controller.sendAttachment(fileURL: url, caption: caption, to: targetID)
        sendErrorsByConversation[targetID] = controller.lastError
        sendingAttachmentByConversation[targetID] = false
        sync()
    }

    /// Stage dropped/pasted files (copied into a conversation-scoped cache).
    func stageFiles(_ urls: [URL]) {
        guard let conversationID = selectedId else { return }
        let dir = pendingDir(for: conversationID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var staged = 0
        for url in urls {
            // Finder drops / pasteboard URLs are security-scoped: without
            // this the copy fails silently with a permission error.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }

            // Avoid copying a file onto itself when a paste/drop points into
            // our own cache. The suffix also prevents same-basename files in
            // one chat from replacing each other.
            let sourceName = url.lastPathComponent.isEmpty ? "attachment" : url.lastPathComponent
            let dest: URL
            if url.standardizedFileURL == dir.appendingPathComponent(sourceName).standardizedFileURL {
                dest = url
            } else {
                let sourceURL = URL(fileURLWithPath: sourceName)
                let stem = sourceURL.deletingPathExtension().lastPathComponent
                let ext = sourceURL.pathExtension
                let suffix = UUID().uuidString.prefix(8)
                let filename = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
                dest = dir.appendingPathComponent(filename)
                try? FileManager.default.removeItem(at: dest)
                guard (try? FileManager.default.copyItem(at: url, to: dest)) != nil else {
                    Log.error("stage failed: \(url.lastPathComponent)")
                    continue
                }
            }

            var files = pendingFilesByConversation[conversationID] ?? []
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete],
                ofItemAtPath: dest.path
            )
            if !files.contains(dest) {
                files.append(dest)
                pendingFilesByConversation[conversationID] = files
            }
            staged += 1
        }
        Log.info("staged \(staged)/\(urls.count) files for \(conversationID)")
    }

    /// Paste images/files from the clipboard into the pending tray.
    func pasteBoard() {
        guard let conversationID = selectedId else { return }
        let pb = NSPasteboard.general
        var urls: [URL] = []
        if let objects = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] {
            urls.append(contentsOf: objects.filter { $0.isFileURL })
        }
        if urls.isEmpty, let tiff = pb.data(forType: .tiff), let img = NSImage(data: tiff) {
            let dir = pendingDir(for: conversationID)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("paste-\(UUID().uuidString.prefix(8)).png")
            if let rep = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: rep)?.representation(using: .png, properties: [:]) {
                try? png.write(to: dest)
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.complete],
                    ofItemAtPath: dest.path
                )
                var files = pendingFilesByConversation[conversationID] ?? []
                files.append(dest)
                pendingFilesByConversation[conversationID] = files
            }
        }
        if !urls.isEmpty { stageFiles(urls) }
    }

    func removePendingFile(_ url: URL) {
        guard let conversationID = selectedId else { return }
        pendingFilesByConversation[conversationID]?.removeAll { $0 == url }
        try? FileManager.default.removeItem(at: url)
    }

    private func pendingDir() -> URL {
        let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("CuztomSignal/pending", isDirectory: true)
    }

    private func pendingDir(for conversationID: String) -> URL {
        let encoded = conversationID.addingPercentEncoding(withAllowedCharacters: .alphanumerics)
            ?? UUID().uuidString
        return pendingDir().appendingPathComponent(encoded, isDirectory: true)
    }

    func loadMore() async {
        guard let controller else { return }
        switch await controller.loadMoreResult() {
        case .loaded:
            historyExhausted = false
        case .exhausted:
            historyExhausted = true
        case .failed(let message):
            historyExhausted = false
            sendError = message
        case .cancelled:
            break
        }
        sync()
    }

    func downloadAttachment(messageId: UUID, index: Int) async {
        await controller?.downloadAttachment(messageId: messageId, index: index)
        sync()
    }

    private let plugins = PluginHost(plugins: [InfoPlugin()])

    private func pluginCtx(selectedThread: String? = nil) -> PluginContext {
        // `controller`/`liveService` are Sendable; safe to capture.
        let c = controller
        let live = liveService
        let capturedThread = selectedThread
        return PluginContext(
            conversations: { await c?.conversations ?? [] },
            selectedThread: {
                if let capturedThread { return capturedThread }
                guard let c else { return nil }
                return await c.selectedId
            },
            recentMessages: { id, n in await c?.messages(in: id, limit: n) ?? [] },
            diagnostics: { await c?.diagnostics() ?? "not started" },
            account: {
                if let me = try? await live?.whoami() {
                    return "\(me.number) · \(String(me.aci.prefix(8)))"
                }
                return "unknown"
            },
            rosterSummary: { live?.lastRosterSummary ?? "not connected" },
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
            syncNote = "request sent, waiting for contacts_synced…"
            Log.info("manual contact sync requested")
        } else {
            syncNote = "request failed"
            Log.error("manual sync failed")
        }
        // The authoritative refresh is triggered by the backend's
        // `contacts_synced` event; refreshing immediately would only reread
        // the old roster and reintroduce Unknown names.
    }

    func logout() async {
        guard !isLoggingOut, let c = controller else { return }
        isLoggingOut = true
        defer { isLoggingOut = false }
        selectionGeneration += 1
        selectionInProgress = false
        let oldDiagnostics = diagnosticsTask
        let oldSelection = selectionTask
        diagnosticsTask = nil
        selectionTask = nil
        oldDiagnostics?.cancel()
        oldSelection?.cancel()
        await oldDiagnostics?.value
        await oldSelection?.value
        await callController.resetAndAwait()
        // A group call must not survive an account boundary: native clients are
        // torn down on logout, so a live handle would be refused and the UI
        // would show a call that no longer exists.
        await groupCallController?.resetAndAwait()
        groupCallController = nil
        groupRoster?.reset()
        groupRoster = nil
        groupCall = nil
        incomingGroupCall = nil
        notifiedCallIDs.removeAll()
        NotificationManager.shared.cancelAll()

        // The controller owns one authoritative, throwing wipe. It does not
        // start a replacement account if the native or presentation wipe fails.
        do {
            try await c.logoutAndWipe()
        } catch {
            let message = "Logout failed: \(error.localizedDescription)"
            Log.error("logout/data wipe failed: \(error)")
            errorMessage = message
            sendError = message
            phase = .failed
            return
        }

        // The controller has already cleared the Swift-side store.
        liveService = nil
        cachedSelfAci = nil
        // Diagnostics are account-scoped; do not retain identifiers or paths
        // after the authoritative wipe succeeds.
        Log.clear()
        draftsByConversation.removeAll()
        repliesByConversation.removeAll()
        pendingFilesByConversation.removeAll()
        sendingAttachmentByConversation.removeAll()
        sendErrorsByConversation.removeAll()
        editingMessage = nil
        editDraft = ""
        preview = nil
        typingUsers.removeAll()
        selectionGeneration += 1
        selectionInProgress = false
        selectedId = nil
        try? FileManager.default.removeItem(at: pendingDir())
        sync()
        // Back to a fresh QR only after the native wipe succeeded.
        phase = .starting
        await start()
    }

    private var liveService: RustCoreService?

    private func succeed(_ controller: ChatController) {
        sync()
        phase = .linked
        if notificationsEnabled {
            Task { _ = await NotificationManager.shared.requestAuthorization() }
        }
        if selectedId == nil, let first = conversations.first {
            select(first.id)
        }
    }

    private func fail(_ controller: ChatController) {
        sync()
        errorMessage = controller.lastError ?? "unknown error"
        phase = .failed
    }

    private func notifyIncomingMessage(_ message: ChatMessage) {
        // Avoid a banner for a conversation the user is already viewing, but
        // keep notifications for all other conversations and for a running
        // app in the background.
        if selectedId == message.conversationId && NSApplication.shared.isActive {
            return
        }
        let conversationTitle = conversations.first(where: { $0.id == message.conversationId })?.title
            ?? "New message"
        let sender: String
        if let hint = message.author.displayName,
           !hint.isEmpty,
           hint != "Unknown",
           hint != String((message.author.uuidString ?? "").prefix(8)) {
            sender = hint
        } else {
            sender = message.author.uuidString.map {
                displayName(for: $0, in: message.conversationId)
            } ?? "Unknown"
        }
        NotificationManager.shared.notifyMessage(
            threadID: message.conversationId,
            conversationTitle: conversationTitle,
            senderName: sender,
            body: message.body,
            storeTs: message.storeTs
        )
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

    func displayName(for message: ChatMessage) -> String {
        if let hint = message.author.displayName,
           !hint.isEmpty,
           hint != "Unknown",
           hint != String((message.author.uuidString ?? "").prefix(8)) {
            return hint
        }
        return displayName(for: message.author.uuidString ?? "", in: message.conversationId)
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
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.connectionText = String(describing: controller.connection)
            self.diagnosticsText = await controller.diagnostics()
            guard !Task.isCancelled else { return }
            if let live = self.liveService,
               let me = try? await live.whoami() {
                let friendlyName = (await live.profileName(uuid: me.aci))
                    .flatMap { $0.isEmpty ? nil : $0 } ?? "You"
                guard !Task.isCancelled else { return }
                self.accountLine = "\(me.number) · \(friendlyName)"
                self.cachedSelfAci = me.aci
            }
        }
    }
}
