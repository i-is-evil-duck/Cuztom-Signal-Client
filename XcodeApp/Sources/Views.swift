import SwiftUI
import AppKit
import AVKit
import CoreMedia
import CoreImage.CIFilterBuiltins
import CuztomSignalCore
import UniformTypeIdentifiers
import Darwin

struct ContentView: View {
    @Environment(ChatViewModel.self) private var vm
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch vm.phase {
            case .linked:
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    ZStack {
                        MessageListView()
                            .id(vm.selectedId)
                        // Incoming call overlay
                        if let call = vm.incomingCall, vm.activeCall == nil {
                            IncomingCallView(
                                call: call,
                                onAnswer: { Task { await vm.answerCall() } },
                                onDecline: { Task { await vm.declineCall() } }
                            )
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(100)
                        }
                        // Active call overlay
                        if let call = vm.activeCall {
                            ActiveCallView(call: call)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                                .zIndex(99)
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.incomingCall != nil)
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: vm.activeCall != nil)
                }
            default:
                StatusView()
            }
        }
        .task {
            if vm.phase == .starting {
                await vm.start()
            }
        }
        .onAppear {
            AppDelegate.reopenMainWindow = { openWindow(id: "main") }
            DropRelay.model = vm
        }
    }
}

struct StatusView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        switch vm.phase {
        case .starting:
            VStack(spacing: 12) {
                ProgressView()
                Text("Starting…").foregroundStyle(.secondary)
            }
            .padding(40)
        case .linking:
            LinkDeviceView()
        case .failed:
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 48))
                Text("Couldn't connect").font(.title2)
                if let err = vm.errorMessage {
                    Text(err).font(.caption).monospaced().foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Button("Retry") { Task { await vm.retry() } }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(40)
        case .linked:
            EmptyView()
        }
    }
}

struct SidebarView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        List(selection: $vm.selectedId) {
            ForEach(vm.conversations) { conv in
                Label {
                    VStack(alignment: .leading) {
                        Text(conv.title).font(.headline)
                        if let preview = conv.lastMessagePreview {
                            Text(preview).font(.subheadline).foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } icon: {
                    Image(systemName: conv.peer.isGroup ? "person.3.fill" : "person.circle.fill")
                }
                // Tag type must match the Optional selection or taps silently
                // do nothing (this once pinned sends to the first thread).
                .tag(conv.id as String?)
                .badge(conv.unreadCount > 0 ? conv.unreadCount : 0)
            }
        }
        .navigationTitle("Cuztom Signal")
        .safeAreaInset(edge: .bottom) {
            Text("build: \(vm.buildVersionTag)")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onChange(of: vm.selectedId) { _, newId in
            if let newId { vm.select(newId) }
        }
    }
}

struct MessageListView: View {
    @Environment(ChatViewModel.self) private var vm
    @State private var loadingMore = false
    @State private var dropActive = false

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            if !vm.isLinked {
                LinkDeviceView()
            } else {
                // Send-target header: always shows exactly where Send goes.
                if let id = vm.selectedId {
                    let title = vm.conversations.first(where: { $0.id == id })?.title ?? id
                    let isGroup = vm.conversations.first(where: { $0.id == id })?.peer.isGroup ?? false
                    HStack {
                        Text("To: \(title)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if isGroup {
                            // Group calls only. A 1:1 group call would need a
                            // call id, and RingRTC has none for a group message.
                            Button { Task { await vm.startGroupCall() } } label: {
                                Image(systemName: "person.3.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Group call")
                            .disabled(vm.groupCall != nil)
                        } else {
                            // Voice call button
                            Button { Task { await vm.startVoiceCall() } } label: {
                                Image(systemName: "phone.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Voice call")
                            .disabled(vm.activeCall != nil || vm.incomingCall != nil)

                            // Video is intentionally not enabled yet; the native
                            // audio path is the supported lightweight call mode.
                            Button { Task { await vm.startVideoCall() } } label: {
                                Image(systemName: "video.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Video calls are not available yet")
                            .disabled(true)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.gray.opacity(0.08))

                    // A group call in progress, with the reason it is not
                    // working when there is one. Shown here rather than as a
                    // separate window so a call that failed says so next to the
                    // conversation instead of disappearing.
                    if let call = vm.groupCall {
                        GroupCallBanner(call: call) {
                            Task { await vm.endGroupCall() }
                        }
                    }
                }
                // Typing indicator
                if let id = vm.selectedId,
                   let users = vm.typingUsers[id],
                   !users.isEmpty {
                    let names = users.values
                        .filter { $0.1 }
                        .map(\.0)
                    if !names.isEmpty {
                        let label = names.count == 1
                            ? "\(names[0]) is typing…"
                            : "\(names.joined(separator: ", ")) are typing…"
                        HStack {
                            Text(label)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 2)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if vm.selectedId != nil {
                    if vm.historyExhausted {
                        Text("No older messages — history starts when this device was linked.")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(.top, 8)
                    } else {
                        Button(loadingMore ? "Loading…" : "Load older messages") {
                            loadingMore = true
                            Task {
                                await vm.loadMore()
                                loadingMore = false
                            }
                        }
                        .font(.caption)
                        .padding(.top, 8)
                        .disabled(loadingMore)
                    }
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(vm.messages.enumerated()), id: \.element.id) { index, msg in
                                MessageRow(
                                    msg: msg,
                                    showsSender: shouldShowSender(at: index),
                                    onOpenReply: { reference in
                                        openReply(reference, proxy: proxy)
                                    }
                                )
                            }
                            Color.clear
                                .frame(height: 1)
                                .id("message-bottom")
                        }
                        .padding()
                    }
                    .onAppear {
                        proxy.scrollTo("message-bottom", anchor: .bottom)
                    }
                    .onChange(of: vm.messages.map(\.id)) { _, _ in
                        // Covers both locally sent messages and live inbound
                        // messages without changing the user's scroll position
                        // while they are reading older history.
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo("message-bottom", anchor: .bottom)
                        }
                    }
                }
                Divider()
                if let quote = vm.replyingTo {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Replying").font(.caption2).foregroundStyle(.secondary)
                            Text(quote.body.isEmpty ? "[attachment]" : String(quote.body.prefix(80)))
                                .font(.caption).lineLimit(1)
                        }
                        Spacer()
                        Button { vm.replyingTo = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.08))
                }
                if !vm.pendingFiles.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(vm.pendingFiles, id: \.self) { url in
                                HStack(spacing: 4) {
                                    Image(systemName: "doc.fill")
                                    Text(url.lastPathComponent).font(.caption).lineLimit(1)
                                    Button { vm.removePendingFile(url) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(6)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(8)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .padding(.vertical, 4)
                }
                if let err = vm.sendError {
                    HStack {
                        Text(err).font(.caption).foregroundStyle(.red).lineLimit(2)
                        Spacer()
                        Button { vm.sendError = nil } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                }
                HStack {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = true
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK {
                            vm.stageFiles(panel.urls)
                        }
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .help("Attach files (draft text becomes the caption)")
                    .disabled(vm.sendingAttachment)
                    Button { vm.pasteBoard() } label: {
                        Image(systemName: "clipboard")
                    }
                    .buttonStyle(.plain)
                    .help("Paste clipboard images/files as attachments")
                    TextField(
                        "Message  (/help for commands)",
                        text: Binding(
                            get: { vm.draft },
                            set: { vm.draft = $0 }
                        )
                    )
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                        .onChange(of: vm.draft) { _, newValue in
                            if !newValue.isEmpty {
                                Task { await vm.sendTyping(started: true) }
                            } else {
                                Task { await vm.sendTyping(started: false) }
                            }
                        }
                    Button(vm.sendingAttachment ? "Sending…" : "Send") { send() }
                        .keyboardShortcut(.return)
                        .disabled((vm.draft.trimmingCharacters(in: .whitespaces).isEmpty && vm.pendingFiles.isEmpty) || vm.sendingAttachment)
                }
                .padding()
                .onDrop(of: [.fileURL], isTargeted: $dropActive) { providers in
                    for p in providers {
                        // NOTE: this callback is nonisolated and must not
                        // capture the view model — relay through DropRelay.
                        _ = p.loadObject(ofClass: URL.self) { url, _ in
                            if let url { DropRelay.stage([url]) }
                        }
                    }
                    return true
                }
                .overlay {
                    if dropActive {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.accentColor, lineWidth: 3)
                            .padding(6)
                    }
                }
            }
        }
        .sheet(item: $vm.preview) { item in
            AttachmentPreview(item: item)
        }
        .popover(item: $vm.receiptTarget) { msg in
            VStack(alignment: .leading, spacing: 8) {
                Text("Message info").font(.headline)
                if !msg.readBy.isEmpty {
                    Text("Seen by").font(.caption).foregroundStyle(.secondary)
                    ForEach(msg.readBy, id: \.self) { aci in
                        Text("✓ \(vm.displayName(for: aci, in: msg.conversationId))")
                    }
                }
                if !msg.deliveredTo.isEmpty {
                    Text("Delivered to").font(.caption).foregroundStyle(.secondary)
                    ForEach(msg.deliveredTo, id: \.self) { aci in
                        Text("✓ \(vm.displayName(for: aci, in: msg.conversationId))")
                    }
                }
                if msg.readBy.isEmpty && msg.deliveredTo.isEmpty {
                    Text("No receipts yet.").foregroundStyle(.secondary)
                }
                Text("Note: this client displays receipts but doesn't send read receipts yet.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .padding()
            .frame(minWidth: 260)
        }
        .popover(item: $vm.emojiTarget) { msg in
            AppleEmojiCatcherView { emoji in
                vm.emojiTarget = nil
                Task { await vm.react(message: msg, emoji: emoji) }
            }
            .padding()
            .frame(width: 300, height: 140)
        }
        .sheet(item: $vm.editingMessage) { msg in
            EditMessageSheet(message: msg, draft: $vm.editDraft, onConfirm: { Task { await vm.confirmEdit() } }, onCancel: { vm.cancelEdit() })
        }
    }

    private func openReply(_ reference: MessageReference, proxy: ScrollViewProxy) {
        if let target = message(for: reference) {
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: .center)
            }
            return
        }

        // Replies can point outside the currently loaded page. Grow the page
        // once, then either jump to the target or leave a useful non-blocking
        // status instead of presenting a blank/failed navigation action.
        Task { @MainActor in
            await vm.loadMore()
            guard !Task.isCancelled, let target = message(for: reference) else {
                vm.sendError = "The quoted message is not loaded yet"
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) {
                proxy.scrollTo(target.id, anchor: .center)
            }
        }
    }

    private func message(for reference: MessageReference) -> ChatMessage? {
        vm.messages.first { message in
            guard message.storeTs == reference.storeTs else { return false }
            guard let authorID = reference.authorID,
                  !authorID.isEmpty,
                  let messageAuthor = message.author.uuidString else { return true }
            return messageAuthor == authorID
        }
    }

    private func shouldShowSender(at index: Int) -> Bool {
        let message = vm.messages[index]
        guard message.direction == .incoming, message.author.groupId != nil else {
            return false
        }
        guard index > 0 else { return true }
        let previous = vm.messages[index - 1]
        let sameSender = previous.direction == .incoming
            && previous.author.groupId != nil
            && previous.author.uuidString == message.author.uuidString
        let contiguous = sameSender
            && message.sentAt.timeIntervalSince(previous.sentAt) < 5 * 60
        return !contiguous
    }

    private func send() {
        let body = vm.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !vm.pendingFiles.isEmpty,
              let targetID = vm.selectedId else { return }
        vm.draft = ""
        // Capture the destination at the moment Send is tapped. An async
        // history refresh must never redirect this message to the old chat.
        Task { await vm.send(body, to: targetID) }
    }
}

private struct ReactionSummary: Identifiable {
    let emoji: String
    let count: Int
    var id: String { emoji }
}

/// Sizes a bubble to hug its content between a minimum and a maximum.
///
/// A plain `.frame(maxWidth:)` cannot do this: it is greedy and expands to the
/// proposed width, which made every bubble render at the maximum. Measuring the
/// content with a preference key instead collapses into a feedback loop — the
/// content is measured *after* it has been clamped, so it reports the clamped
/// width and can never grow again (every bubble locks to the minimum and media
/// gets flattened).
///
/// Asking the subview for its ideal size and then re-proposing the clamped
/// width gives both required behaviours: short content hugs, long content
/// wraps exactly at the maximum, and images render at their natural size.
private struct ClampedBubbleLayout: Layout {
    let minWidth: CGFloat
    let maxWidth: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let width = clampedWidth(for: content)
        // Re-propose the clamped width so text wraps there and resizable media
        // resolves its height from the aspect ratio.
        let fitted = content.sizeThatFits(
            ProposedViewSize(width: width, height: proposal.height)
        )
        return CGSize(width: width, height: proposal.height ?? fitted.height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let content = subviews.first else { return }
        let width = clampedWidth(for: content)
        content.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: width, height: bounds.height)
        )
    }

    private func clampedWidth(for content: LayoutSubview) -> CGFloat {
        let ideal = content.sizeThatFits(.unspecified).width
        guard ideal.isFinite, ideal > 0 else { return minWidth }
        return min(max(ideal, minWidth), maxWidth)
    }
}

struct MessageRow: View {
    @Environment(ChatViewModel.self) private var vm
    var msg: ChatMessage
    var showsSender = true
    var onOpenReply: (MessageReference) -> Void = { _ in }

    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    /// Bubbles hug their content between these bounds. See
    /// `ClampedBubbleLayout` for why this cannot be done with `.frame`.
    private let minBubbleWidth: CGFloat = 72
    private let maxBubbleWidth: CGFloat = 460
    /// Receipt lists name every reader, so cap them well below the bubble
    /// maximum; otherwise they alone stretch the bubble to full width.
    private let receiptLineWidth: CGFloat = 300

    private var isGroupMessage: Bool {
        msg.author.groupId != nil
    }

    var body: some View {
        HStack {
            if msg.direction == .outgoing { Spacer() }
            ClampedBubbleLayout(
                minWidth: minBubbleWidth,
                maxWidth: maxBubbleWidth
            ) {
            VStack(alignment: .leading, spacing: 4) {
                // Sender name/initials for group messages (incoming only)
                if isGroupMessage && msg.direction == .incoming && showsSender {
                    let senderName = vm.displayName(for: msg)
                    let initials = vm.initials(for: senderName)
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Text(initials.isEmpty ? "?" : initials)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        Text(senderName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)
                }
                if let reply = msg.replyTo {
                    Button {
                        onOpenReply(reply)
                    } label: {
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "arrowshape.turn.up.left")
                                .font(.caption2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(replyAuthorName(reply))
                                    .font(.caption2)
                                    .foregroundStyle(Color.accentColor)
                                    .lineLimit(1)
                                Text(replyPreview(reply))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                        }
                        .padding(6)
                        .background(Color.accentColor.opacity(0.10))
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open quoted message")
                }
                if !msg.body.isEmpty {
                    Text(msg.body)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copy") { NSPasteboard.general.setString(msg.body, forType: .string) }
                        }
                    LinkPreviewsView(text: msg.body, enabled: vm.linkPreviewsEnabled)
                }
                ForEach(Array(msg.attachments.enumerated()), id: \.offset) { idx, att in
                    AttachmentRow(msg: msg, index: idx, att: att)
                }
                if !reactionSummary.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(reactionSummary, id: \.emoji) { reaction in
                            Button {
                                Task { await vm.react(message: msg, emoji: reaction.emoji) }
                            } label: {
                                HStack(spacing: 3) {
                                    Text(reaction.emoji)
                                    if reaction.count > 1 {
                                        Text("\(reaction.count)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    msg.reactions.contains(reaction.emoji)
                                        ? Color.accentColor.opacity(0.22)
                                        : Color.gray.opacity(0.12)
                                )
                                .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Reaction \(reaction.emoji)")
                        }
                    }
                }
                if msg.direction == .outgoing && (!msg.readBy.isEmpty || !msg.deliveredTo.isEmpty) {
                    Button {
                        vm.receiptTarget = msg
                    } label: {
                        Text(receiptLine)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                            // Without a cap this one line is wide enough to
                            // stretch the whole bubble to its maximum.
                            .frame(maxWidth: receiptLineWidth, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            }
            .background(msg.direction == .outgoing ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contextMenu {
                Button("Reply") { vm.replyingTo = msg }
                Menu("React") {
                    ForEach(quickEmojis, id: \.self) { emoji in
                        Button("\(emoji) \(msg.reactions.contains(emoji) ? "✓" : "")") {
                            Task { await vm.react(message: msg, emoji: emoji) }
                        }
                    }
                    Divider()
                    Button("Emoji & Symbols…") { vm.emojiTarget = msg }
                }
                if msg.direction == .outgoing {
                    Menu("Delete") {
                        Button("Delete for me", role: .destructive) {
                            Task { await vm.deleteMessage(msg, forEveryone: false) }
                        }
                        Button("Delete for everyone", role: .destructive) {
                            Task { await vm.deleteMessage(msg, forEveryone: true) }
                        }
                    }
                    Divider()
                    Button("Edit") {
                        Task { await vm.editMessage(msg) }
                    }
                }
            }
            if msg.direction == .incoming { Spacer() }
        }
    }

    private var reactionSummary: [ReactionSummary] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for emoji in msg.reactions where !emoji.isEmpty {
            if counts[emoji] == nil { order.append(emoji) }
            counts[emoji, default: 0] += 1
        }
        return order.map { ReactionSummary(emoji: $0, count: counts[$0] ?? 0) }
    }

    private func replyAuthorName(_ reference: MessageReference) -> String {
        guard let authorID = reference.authorID, !authorID.isEmpty else {
            return "Quoted message"
        }
        return vm.displayName(for: authorID, in: msg.conversationId)
    }

    private func replyPreview(_ reference: MessageReference) -> String {
        let body = reference.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return body.isEmpty ? "[attachment]" : String(body.prefix(160))
    }

    private var receiptLine: String {
        var parts: [String] = []
        if !msg.readBy.isEmpty {
            let names = msg.readBy.map { vm.displayName(for: $0, in: msg.conversationId) }
            parts.append("Seen by \(names.joined(separator: ", "))")
        }
        if !msg.deliveredTo.isEmpty {
            let names = msg.deliveredTo.map { vm.displayName(for: $0, in: msg.conversationId) }
            parts.append("Delivered to \(names.joined(separator: ", "))")
        }
        return parts.joined(separator: " · ")
    }
}

private enum AttachmentImageLoader {
    /// Decode bytes rather than asking AppKit to infer a type from a cache
    /// filename. Older inbound attachments were stored as extensionless
    /// `...-attachment` files even when their MIME type was image/gif.
    static func load(from url: URL) -> NSImage? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return NSImage(data: data)
    }
}

struct AnimatedGIFView: NSViewRepresentable {
    let image: NSImage

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleProportionallyDown
        view.animates = true
        view.image = image
        return view
    }

    func updateNSView(_ nsView: NSImageView, context: Context) {
        nsView.image = image
        nsView.animates = true
    }
}

struct AttachmentRow: View {
    @Environment(ChatViewModel.self) private var vm
    var msg: ChatMessage
    var index: Int
    var att: AttachmentMeta

    var body: some View {
        Group {
            if isGIF, let url = existingURL,
               let image = AttachmentImageLoader.load(from: url) {
                AnimatedGIFView(image: image)
                    .frame(width: 340, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("attachment-gif")
                    .onTapGesture {
                        vm.preview = PreviewItem(url: url, mime: att.normalizedMIMEType, filename: att.filename)
                    }
            } else if att.isImage, let url = existingURL,
               let image = AttachmentImageLoader.load(from: url) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: 340, maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("attachment-image")
                    .onTapGesture {
                        vm.preview = PreviewItem(url: url, mime: att.normalizedMIMEType, filename: att.filename)
                    }
            } else if att.isVideo, let url = existingURL {
                VideoThumbnail(url: url, filename: att.filename)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                    VStack(alignment: .leading) {
                        Text(att.filename).font(.subheadline).lineLimit(1)
                        Text("\(att.normalizedMIMEType) · \(sizeString)").font(.caption).foregroundStyle(.secondary)
                    }
                    if let url = existingURL {
                        Button("Reveal") {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .font(.caption)
                    } else {
                        Button("Download") {
                            Task { await vm.downloadAttachment(messageId: msg.id, index: index) }
                        }
                        .font(.caption)
                    }
                }
                .padding(6)
                .frame(maxWidth: 300, alignment: .leading)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var existingURL: URL? {
        guard let url = att.localURL,
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var isGIF: Bool { att.isGIF }

    private var icon: String {
        if att.isVideo { return "film" }
        if att.normalizedMIMEType.hasPrefix("audio/") { return "waveform" }
        return "doc"
    }

    private var sizeString: String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(att.byteCount))
    }
}

struct AttachmentPreview: View {
    @Environment(\.dismiss) private var dismiss
    var item: PreviewItem

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(item.filename)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .help("Close preview")
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            GeometryReader { proxy in
                Group {
                    let meta = AttachmentMeta(
                        filename: item.filename,
                        mimeType: item.mime,
                        byteCount: 0,
                        localURL: item.url
                    )
                    if meta.isGIF, let image = AttachmentImageLoader.load(from: item.url) {
                        AnimatedGIFView(image: image)
                            .frame(
                                width: min(720, proxy.size.width),
                                height: min(520, proxy.size.height)
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    } else if meta.isImage, let image = AttachmentImageLoader.load(from: item.url) {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 720, maxHeight: 520)
                    } else if meta.isVideo {
                        SheetVideoPlayer(url: item.url)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "doc").font(.system(size: 64))
                            Text(item.mime).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(16)
            }
            .frame(minWidth: 600, idealWidth: 900, minHeight: 400, idealHeight: 620)
            .background(Color.black.opacity(0.92))

            Divider()

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
        }
        .frame(minWidth: 600, idealWidth: 900, minHeight: 480, idealHeight: 680)
    }
}

/// Expanded video player with one authoritative transport bar. The AppKit
/// player surface is intentionally control-free; this view owns play/pause,
/// seeking, time, restart, and mute so the controls cannot disagree with the
/// actual `AVPlayer` state.
struct SheetVideoPlayer: View {
    let url: URL
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isMuted = false
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var duration: Double = 0
    @State private var currentTime: Double = 0
    @State private var loadError: String?

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Color.black
                if let player {
                    AppKitVideoPlayer(player: player)
                        .aspectRatio(aspect, contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let loadError {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.title)
                        Text(loadError)
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                } else {
                    ProgressView("Loading video…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("video-surface")

            VStack(spacing: 10) {
                HStack(spacing: 8) {
                    Text(fmt(currentTime))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                    Slider(value: seekBinding, in: 0...max(duration, 1))
                        .disabled(duration <= 0 || player == nil)
                        .accessibilityIdentifier("video-scrubber")
                    Text(fmt(duration))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .leading)
                }

                HStack(spacing: 12) {
                    Button {
                        togglePlayback()
                    } label: {
                        Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.space)
                    .disabled(player == nil)
                    .accessibilityIdentifier("video-play-pause")

                    Button {
                        restart()
                    } label: {
                        Label("Restart", systemImage: "gobackward")
                    }
                    .disabled(player == nil)
                    .accessibilityIdentifier("video-restart")

                    Spacer()

                    Button {
                        isMuted.toggle()
                        player?.isMuted = isMuted
                    } label: {
                        Label(isMuted ? "Unmute" : "Mute", systemImage: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .disabled(player == nil)
                    .accessibilityIdentifier("video-mute")
                }
            }
            .padding(16)
            .background(.regularMaterial)
        }
        .task(id: url) {
            await prepare()
        }
        .onDisappear {
            teardown()
        }
    }

    private var seekBinding: Binding<Double> {
        Binding(
            get: {
                guard duration.isFinite, duration > 0 else { return 0 }
                return min(max(currentTime, 0), duration)
            },
            set: { value in
                let clamped = min(max(value, 0), max(duration, 0))
                currentTime = clamped
                player?.seek(
                    to: CMTime(seconds: clamped, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
            }
        )
    }

    @MainActor
    private func prepare() async {
        teardown()
        loadError = nil

        do {
            let asset = AVURLAsset(url: url)
            let loadedDuration = try await asset.load(.duration)
            let loadedAspect = await videoAspect(url: url) ?? (16.0 / 9.0)
            guard !Task.isCancelled else { return }

            let value = CMTimeGetSeconds(loadedDuration)
            duration = value.isFinite && value > 0 ? value : 0
            aspect = loadedAspect
            let newPlayer = AVPlayer(url: url)
            newPlayer.isMuted = isMuted
            player = newPlayer
            newPlayer.play()
            isPlaying = true

            while !Task.isCancelled {
                let time = newPlayer.currentTime()
                if time.isValid {
                    currentTime = max(0, CMTimeGetSeconds(time))
                }
                isPlaying = newPlayer.timeControlStatus == .playing
                if duration > 0, currentTime >= max(0, duration - 0.05), isPlaying {
                    newPlayer.pause()
                    currentTime = duration
                    isPlaying = false
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            loadError = error.localizedDescription
            player = nil
            isPlaying = false
        }
    }

    @MainActor
    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if duration > 0, currentTime >= duration - 0.05 {
                player.seek(to: .zero)
                currentTime = 0
            }
            player.play()
            isPlaying = true
        }
    }

    @MainActor
    private func restart() {
        guard let player else { return }
        player.seek(to: .zero)
        currentTime = 0
        player.play()
        isPlaying = true
    }

    @MainActor
    private func teardown() {
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
        aspect = 16.0 / 9.0
    }

    private func fmt(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded(.down))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private func videoAspect(url: URL) async -> CGFloat? {
    let asset = AVAsset(url: url)
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
    let size = try? await track.load(.naturalSize)
    let transform = try? await track.load(.preferredTransform)
    guard let size, size.width > 0, size.height > 0 else { return nil }
    let t = transform ?? CGAffineTransform.identity
    let rect = CGRect(origin: .zero, size: size).applying(t)
    guard rect.width > 0, rect.height > 0 else { return nil }
    return abs(rect.width / rect.height)
}

struct LinkDeviceView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "qrcode").font(.system(size: 48))
            Text("Link your phone").font(.title2)
            Text("Signal → Settings → Linked devices → Link new device")
                .font(.footnote).foregroundStyle(.secondary)
            if let qr = vm.linkQR {
                if qr.payload.hasPrefix("sgnl://") {
                    if let img = qrNSImage(qr.payload) {
                        Image(nsImage: img)
                            .interpolation(.none)
                            .cornerRadius(8)
                    }
                } else {
                    // Mock backend payload (dev only).
                    Text(qr.payload).font(.caption).monospaced().foregroundStyle(.secondary)
                }
            } else {
                ProgressView("Contacting Signal…")
            }
        }
        .padding(40)
    }
}

/// File-drop relay: `NSItemProvider.loadObject` callbacks are nonisolated
/// and must not capture the view model, so drops land here and hop to the
/// main actor internally.
enum DropRelay {
    nonisolated(unsafe) static weak var model: ChatViewModel?

    static func stage(_ urls: [URL]) {
        Task { @MainActor in
            model?.stageFiles(urls)
        }
    }
}

struct EditMessageSheet: View {
    @Environment(\.dismiss) private var dismiss
    var message: ChatMessage
    @Binding var draft: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Edit Message")
                .font(.headline)
            TextEditor(text: $draft)
                .font(.body)
                .frame(minHeight: 100)
                .padding(8)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            HStack {
                Spacer()
                Button("Cancel") { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { onConfirm() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 400, height: 250)
    }
}

private func qrNSImage(_ string: String) -> NSImage? {
    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
}

private enum LinkPreviewPolicy {
    static let maxResponseBytes = 1_000_000

    static func hasSafeSyntax(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host?.lowercased(),
              !host.isEmpty,
              url.port == nil || url.port == 443 else {
            return false
        }
        return true
    }

    static func allows(_ url: URL) -> Bool {
        guard hasSafeSyntax(url), let host = url.host?.lowercased() else { return false }
        return isPublicHost(host)
    }

    static func isPublicHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        guard !lower.hasPrefix("localhost"),
              !lower.hasSuffix(".localhost"),
              !lower.hasSuffix(".local"),
              !lower.hasSuffix(".internal"),
              !lower.hasSuffix(".lan"),
              !lower.hasSuffix(".home.arpa") else {
            return false
        }

        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return false
        }
        defer { freeaddrinfo(first) }

        var foundAddress = false
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            foundAddress = true
            if info.pointee.ai_family == AF_INET {
                var address = sockaddr_in()
                withUnsafePointer(to: info.pointee.ai_addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        address = $0.pointee
                    }
                }
                let value = UInt32(bigEndian: address.sin_addr.s_addr)
                let firstByte = (value >> 24) & 0xff
                let secondByte = (value >> 16) & 0xff
                let isPrivate = firstByte == 10
                    || firstByte == 127
                    || (firstByte == 169 && secondByte == 254)
                    || (firstByte == 172 && (16...31).contains(secondByte))
                    || (firstByte == 192 && secondByte == 168)
                    || (firstByte == 100 && (64...127).contains(secondByte))
                    || (firstByte == 198 && (secondByte == 18 || secondByte == 19))
                    || firstByte >= 224
                    || firstByte == 0
                if isPrivate { return false }
            } else if info.pointee.ai_family == AF_INET6 {
                var address = sockaddr_in6()
                withUnsafePointer(to: info.pointee.ai_addr) { pointer in
                    pointer.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
                        address = $0.pointee
                    }
                }
                let bytes = withUnsafeBytes(of: address.sin6_addr) { Array($0) }
                let firstByte = bytes[0]
                let secondByte = bytes[1]
                let isUnspecified = bytes.allSatisfy { $0 == 0 }
                let isLoopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes[15] == 1
                let isPrivate = isUnspecified
                    || isLoopback
                    || firstByte == 0xff
                    || (firstByte == 0xfe && (secondByte & 0xc0) == 0x80)
                    || firstByte == 0xfc
                    || firstByte == 0xfd
                if isPrivate { return false }
            }
            cursor = info.pointee.ai_next
        }
        return foundAddress
    }
}

private final class LinkPreviewSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url, LinkPreviewPolicy.allows(url) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// Extract URLs from text and display opt-in, bounded link previews.
struct LinkPreviewsView: View {
    let text: String
    let enabled: Bool
    @State private var previews: [URL: LinkPreview] = [:]

    private var urls: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        return matches.compactMap { $0.url }
            .filter { LinkPreviewPolicy.hasSafeSyntax($0) }
    }

    var body: some View {
        Group {
            if enabled {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(urls.prefix(3), id: \.self) { url in
                        LinkPreviewRow(url: url, preview: previews[url])
                            .onAppear {
                                if previews[url] == nil {
                                    Task { await fetchPreview(for: url) }
                                }
                            }
                    }
                }
                // No max-width frame here: a greedy frame would make every
                // message that contains a link report a full-width bubble.
                // The surrounding bubble owns the maximum.
            }
        }
        .task(id: text) {
            previews = [:]
        }
    }

    private func fetchPreview(for url: URL) async {
        guard enabled, LinkPreviewPolicy.allows(url) else { return }
        let delegate = LinkPreviewSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 1
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(from: url)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  http.expectedContentLength <= Int64(LinkPreviewPolicy.maxResponseBytes),
                  data.count <= LinkPreviewPolicy.maxResponseBytes,
                  let mime = http.mimeType,
                  mime.hasPrefix("text/html") || mime.hasPrefix("application/xhtml+xml"),
                  let html = String(data: data, encoding: .utf8),
                  let title = extractMeta(html, property: "og:title") ?? extractTag(html, tag: "title") else {
                return
            }
            let preview = LinkPreview(title: String(title.prefix(240)), url: url)
            await MainActor.run {
                guard !Task.isCancelled else { return }
                previews[url] = preview
            }
        } catch {
            // Preview failures are intentionally silent and never block the
            // message list or reveal the URL to an unapproved destination.
        }
    }

    private func extractMeta(_ html: String, property: String) -> String? {
        let pattern = "<meta property=\"\(property)\" content=\"([^\"]+)\""
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: html.utf16.count)
        return regex?.firstMatch(in: html, range: range).flatMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    private func extractTag(_ html: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>([^<]+)</\(tag)>"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(location: 0, length: html.utf16.count)
        return regex?.firstMatch(in: html, range: range).flatMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }
}

struct LinkPreview {
    let title: String
    let url: URL
}

struct LinkPreviewRow: View {
    let url: URL
    let preview: LinkPreview?

    var body: some View {
        Link(destination: url) {
            HStack(spacing: 8) {
                // Do not fetch og:image here: it is a second, unvalidated
                // network request. The title and destination are enough to
                // identify the link without leaking the message recipient's
                // IP address to an image host.
                Image(systemName: "safari")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(preview?.title ?? url.host ?? url.absoluteString)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(url.absoluteString)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(8)
            .background(Color.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("link-preview")
    }
    }

/// The group call in progress, and the reason it is not working when there is
/// one.
///
/// The phase is spelled out rather than implied by a spinner. A call that cannot
/// get a membership proof cannot connect, and that is not something to hide
/// behind a spinner that never resolves: showing "connecting" forever would be a
/// claim this build has not verified.
struct GroupCallBanner: View {
    let call: GroupCallState
    let onEnd: () -> Void

    private var statusText: String {
        switch call.phase {
        case .connecting:
            return call.isOutgoing ? "Connecting to the call…" : "Joining the call…"
        case .connected:
            return "Connected"
        case .ended:
            return call.failure.map { "Call ended: \($0)" } ?? "Call ended"
        case .failed:
            return call.failure ?? "The call could not be connected"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            if call.phase == .connecting {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(call.title.isEmpty ? "Group call" : call.title)
                    .font(.callout.weight(.medium))
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(call.phase == .failed ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if call.phase == .connected || call.phase == .failed {
                Button("End", action: onEnd)
                    .buttonStyle(.plain)
            } else if call.phase == .ended {
                // An ended call stays on screen with its reason, so a call that
                // failed is not the same as a call the user never made.
                Button("Dismiss", action: onEnd)
                    .buttonStyle(.plain)
            } else {
                Button("End", action: onEnd)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.gray.opacity(0.12))
        .accessibilityIdentifier("group-call-banner")
    }
}
