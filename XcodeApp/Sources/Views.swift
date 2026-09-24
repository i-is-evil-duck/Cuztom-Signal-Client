import SwiftUI
import AppKit
import AVKit
import CoreMedia
import CoreImage.CIFilterBuiltins
import CuztomSignalCore
import UniformTypeIdentifiers

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
                        // Incoming call overlay
                        if let call = vm.incomingCall {
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
            Text("backend: \(vm.backendName)")
                .font(.caption2).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        .onChange(of: vm.selectedId) { _, newId in
            if let newId { Task { await vm.select(newId) } }
        }
    }
}

struct MessageListView: View {
    @Environment(ChatViewModel.self) private var vm
    @State private var draft = ""
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
                        if !isGroup {
                            // Voice call button
                            Button { Task { await vm.startVoiceCall() } } label: {
                                Image(systemName: "phone.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Voice call")
                            .disabled(vm.activeCall != nil || vm.incomingCall != nil)

                            // Video call button
                            Button { Task { await vm.startVideoCall() } } label: {
                                Image(systemName: "video.fill")
                            }
                            .buttonStyle(.plain)
                            .help("Video call")
                            .disabled(vm.activeCall != nil || vm.incomingCall != nil)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.gray.opacity(0.08))
                }
                // Typing indicator
                if let id = vm.selectedId,
                   let typing = vm.typingUsers[id],
                   typing.1 {
                    HStack {
                        Text("\(typing.0) is typing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 12).padding(.vertical, 2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
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
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.messages, id: \.id) { msg in
                            MessageRow(msg: msg)
                        }
                    }
                    .padding()
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
                                    Button { vm.pendingFiles.removeAll { $0 == url } } label: {
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
                    TextField("Message  (/help for commands)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                        .onChange(of: draft) { _, newValue in
                            if !newValue.isEmpty {
                                Task { await vm.sendTyping(started: true) }
                            } else {
                                Task { await vm.sendTyping(started: false) }
                            }
                        }
                    Button(vm.sendingAttachment ? "Sending…" : "Send") { send() }
                        .keyboardShortcut(.return)
                        .disabled((draft.trimmingCharacters(in: .whitespaces).isEmpty && vm.pendingFiles.isEmpty) || vm.sendingAttachment)
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
                    ForEach(msg.readBy, id: \.self) { Text("✓ \($0)") }
                }
                if !msg.deliveredTo.isEmpty {
                    Text("Delivered to").font(.caption).foregroundStyle(.secondary)
                    ForEach(msg.deliveredTo, id: \.self) { Text("✓ \($0)") }
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

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty || !vm.pendingFiles.isEmpty else { return }
        draft = ""
        Task { await vm.send(body) }
    }
}

struct MessageRow: View {
    @Environment(ChatViewModel.self) private var vm
    var msg: ChatMessage

    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    private var isGroupMessage: Bool {
        msg.author.groupId != nil
    }

    private var senderInitials: String {
        // For group messages, show sender initials
        if isGroupMessage {
            if let authorName = msg.author.uuidString {
                // Try to get initials from the ACI/UUID or use a hash-based approach
                let name = msg.author.uuidString ?? "?"
                let components = name.split(separator: " ")
                if components.count >= 2 {
                    return String(components[0].prefix(1)) + String(components[1].prefix(1))
                } else {
                    return String(name.prefix(2)).uppercased()
                }
            }
        }
        return ""
    }

    var body: some View {
        HStack {
            if msg.direction == .outgoing { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                // Sender name/initials for group messages (incoming only)
                if isGroupMessage && msg.direction == .incoming {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.accentColor.opacity(0.3))
                            .frame(width: 24, height: 24)
                            .overlay {
                                Text(senderInitials)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        Text(msg.author.uuidString?.prefix(8) ?? "Unknown")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 2)
                }
                if !msg.body.isEmpty {
                    Text(msg.body)
                        .textSelection(.enabled)
                        .contextMenu {
                            Button("Copy") { NSPasteboard.general.setString(msg.body, forType: .string) }
                        }
                    LinkPreviewsView(text: msg.body)
                }
                ForEach(Array(msg.attachments.enumerated()), id: \.offset) { idx, att in
                    AttachmentRow(msg: msg, index: idx, att: att)
                }
                if !msg.reactions.isEmpty {
                    Text(msg.reactions.joined(separator: " "))
                        .font(.caption)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.gray.opacity(0.12))
                        .cornerRadius(8)
                }
                if msg.direction == .outgoing && (!msg.readBy.isEmpty || !msg.deliveredTo.isEmpty) {
                    Button {
                        vm.receiptTarget = msg
                    } label: {
                        Text(receiptLine).font(.caption2).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
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

    private var receiptLine: String {
        var parts: [String] = []
        if !msg.readBy.isEmpty { parts.append("Seen by \(msg.readBy.joined(separator: ", "))") }
        if !msg.deliveredTo.isEmpty { parts.append("Delivered to \(msg.deliveredTo.joined(separator: ", "))") }
        return parts.joined(separator: " · ")
    }
}

struct AttachmentRow: View {
    @Environment(ChatViewModel.self) private var vm
    var msg: ChatMessage
    var index: Int
    var att: AttachmentMeta

    var body: some View {
        Group {
            if att.mimeType.hasPrefix("image/"), let url = att.localURL,
               let img = NSImage(contentsOf: url) {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 240)
                    .cornerRadius(6)
                    .onTapGesture {
                        vm.preview = PreviewItem(url: url, mime: att.mimeType, filename: att.filename)
                    }
            } else if att.mimeType.hasPrefix("video/"), let url = att.localURL {
                VideoThumbnail(url: url, filename: att.filename)
            } else {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                    VStack(alignment: .leading) {
                        Text(att.filename).font(.subheadline).lineLimit(1)
                        Text("\(att.mimeType) · \(sizeString)").font(.caption).foregroundStyle(.secondary)
                    }
                    if att.localURL != nil {
                        Button("Reveal") {
                            if let url = att.localURL {
                                NSWorkspace.shared.activateFileViewerSelecting([url])
                            }
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
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
            }
        }
    }

    private var icon: String {
        if att.mimeType.hasPrefix("video/") { return "film" }
        if att.mimeType.hasPrefix("audio/") { return "waveform" }
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
        VStack(spacing: 12) {
            Text(item.filename).font(.headline).lineLimit(1)
            Group {
                if item.mime.hasPrefix("image/"), let img = NSImage(contentsOf: item.url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else if item.mime.hasPrefix("video/") {
                    SheetVideoPlayer(url: item.url)
                } else {
                    Image(systemName: "doc").font(.system(size: 64))
                    Text(item.mime).foregroundStyle(.secondary)
                }
            }
            .frame(minWidth: 500, minHeight: 400)
            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([item.url])
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding()
        .frame(minWidth: 600, minHeight: 520)
    }
}

/// Video player: Play/Pause + time readout, auto-sized to the media.
/// Deliberately NO scrub timeline (scroll-to-seek removed by design).
struct SheetVideoPlayer: View {
    var url: URL
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var aspect: CGFloat = 16.0 / 9.0
    @State private var total: Double = 0

    var body: some View {
        VStack(spacing: 8) {
            Group {
                if let player {
                    AppKitVideoPlayer(player: player)
                        .frame(width: frameSize.width, height: frameSize.height)
                        .cornerRadius(8)
                } else {
                    ProgressView().frame(width: 480, height: 270)
                }
            }
            // Media controls: transport + time, no seek bar.
            HStack(spacing: 12) {
                Button(playing ? "Pause" : "Play") {
                    guard let player else { return }
                    if playing { player.pause() } else { player.play() }
                    playing.toggle()
                }
                .keyboardShortcut(.space)
                .buttonStyle(.borderedProminent)
                TimelineView(.periodic(from: .now, by: 0.5)) { _ in
                    Text("\(fmt(currentSeconds)) / \(fmt(total))")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Spacer()
                Button("Restart") {
                    player?.seek(to: .zero)
                    player?.play()
                    playing = true
                }
                .font(.caption)
            }
        }
        .task {
            let p = AVPlayer(url: url)
            player = p
            aspect = await videoAspect(url: url) ?? (16.0 / 9.0)
            if let d = try? await p.currentItem?.asset.load(.duration), d.isValid, !d.isIndefinite {
                total = CMTimeGetSeconds(d)
            }
            p.play()
            playing = true
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var currentSeconds: Double {
        guard let t = player?.currentTime(), t.isValid else { return 0 }
        return CMTimeGetSeconds(t)
    }

    private var frameSize: CGSize {
        let maxW: CGFloat = 640
        let maxH: CGFloat = 460
        let h = min(maxH, maxW / aspect)
        return CGSize(width: h * aspect, height: h)
    }

    private func fmt(_ s: Double) -> String {
        guard s.isFinite && s >= 0 else { return "0:00" }
        let i = Int(s)
        return String(format: "%d:%02d", i / 60, i % 60)
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

/// Extract URLs from text and display link previews
struct LinkPreviewsView: View {
    let text: String
    @State private var previews: [URL: LinkPreview] = [:]
    
    private var urls: [URL] {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(location: 0, length: text.utf16.count)) ?? []
        return matches.compactMap { $0.url }
    }
    
    var body: some View {
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
    }
    
    private func fetchPreview(for url: URL) async {
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            if let html = String(data: data, encoding: .utf8),
               let title = extractMeta(html, property: "og:title") ?? extractTag(html, tag: "title"),
               let image = extractMeta(html, property: "og:image") {
                let preview = LinkPreview(title: title, imageURL: URL(string: image), url: url)
                await MainActor.run { previews[url] = preview }
            }
        } catch {
            // Silently fail for link previews
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
    let imageURL: URL?
    let url: URL
}

struct LinkPreviewRow: View {
    let url: URL
    let preview: LinkPreview?
    
    var body: some View {
        HStack(spacing: 8) {
            if let preview = preview,
               let imageURL = preview.imageURL {
                AsyncImage(url: imageURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.2)
                }
                .frame(width: 60, height: 60)
                .cornerRadius(6)
            }
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
            Spacer()
        }
        .padding(8)
        .background(Color.gray.opacity(0.08))
        .cornerRadius(8)
    }
    }
