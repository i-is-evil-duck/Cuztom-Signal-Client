import SwiftUI
import AppKit
import AVKit
import CoreMedia
import CoreImage.CIFilterBuiltins
import CuztomSignalCore

struct ContentView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        Group {
            switch vm.phase {
            case .linked:
                NavigationSplitView {
                    SidebarView()
                } detail: {
                    MessageListView()
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

    var body: some View {
        @Bindable var vm = vm
        VStack(spacing: 0) {
            if !vm.isLinked {
                LinkDeviceView()
            } else {
                // Send-target header: always shows exactly where Send goes.
                if let id = vm.selectedId {
                    let title = vm.conversations.first(where: { $0.id == id })?.title ?? id
                    HStack {
                        Text("To: \(title)")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button { vm.showCallsSoon = true } label: {
                            Image(systemName: "phone")
                        }
                        .buttonStyle(.plain)
                        .help("Voice call (M4)")
                        Button { vm.showCallsSoon = true } label: {
                            Image(systemName: "video")
                        }
                        .buttonStyle(.plain)
                        .help("Video call (M4)")
                    }
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Color.gray.opacity(0.08))
                    .alert("Calls aren't here yet", isPresented: $vm.showCallsSoon) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text("Voice/video calls land in M4 (RingRTC). Everything else in this build is live.")
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
                HStack {
                    Button {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseFiles = true
                        panel.canChooseDirectories = false
                        if panel.runModal() == .OK, let url = panel.url {
                            let caption = draft
                            draft = ""
                            vm.replyingTo = nil
                            Task { await vm.sendAttachment(url: url, caption: caption) }
                        }
                    } label: {
                        Image(systemName: "paperclip")
                    }
                    .buttonStyle(.plain)
                    .help("Send a file (draft text becomes the caption)")
                    .disabled(vm.sendingAttachment)
                    TextField("Message  (/help for commands)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button(vm.sendingAttachment ? "Sending…" : "Send") { send() }
                        .keyboardShortcut(.return)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || vm.sendingAttachment)
                }
                .padding()
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
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { await vm.send(body) }
    }
}

struct MessageRow: View {
    @Environment(ChatViewModel.self) private var vm
    var msg: ChatMessage

    private let quickEmojis = ["👍", "❤️", "😂", "😮", "😢", "🙏"]

    var body: some View {
        HStack {
            if msg.direction == .outgoing { Spacer() }
            VStack(alignment: .leading, spacing: 4) {
                if !msg.body.isEmpty {
                    Text(msg.body)
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

/// Video player without a scrub timeline (scroll-to-seek removed by design),
/// auto-sized to the media aspect.
struct SheetVideoPlayer: View {
    var url: URL
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var aspect: CGFloat = 16.0 / 9.0

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
            HStack {
                Button(playing ? "Pause" : "Play") {
                    guard let player else { return }
                    if playing { player.pause() } else { player.play() }
                    playing.toggle()
                }
                .keyboardShortcut(.space)
                Text(itemDuration).font(.caption).foregroundStyle(.secondary)
            }
        }
        .task {
            let p = AVPlayer(url: url)
            player = p
            aspect = await videoAspect(url: url) ?? (16.0 / 9.0)
            p.play()
            playing = true
        }
        .onDisappear {
            player?.pause()
        }
    }

    private var frameSize: CGSize {
        let maxW: CGFloat = 640
        let maxH: CGFloat = 460
        let h = min(maxH, maxW / aspect)
        return CGSize(width: h * aspect, height: h)
    }

    private var itemDuration: String {
        guard let d = player?.currentItem?.duration, d.isValid, !d.isIndefinite else { return "" }
        let s = Int(CMTimeGetSeconds(d))
        return String(format: "%d:%02d", s / 60, s % 60)
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

private func qrNSImage(_ string: String) -> NSImage? {    let context = CIContext()
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
    guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
    return NSImage(cgImage: cg, size: NSSize(width: 240, height: 240))
}
