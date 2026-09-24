import SwiftUI
import AppKit
import AVKit
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
                    Text("To: \(title)")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 4)
                        .background(Color.gray.opacity(0.08))
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
                HStack {
                    TextField("Message  (/help for commands)", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("Send") { send() }
                        .keyboardShortcut(.return)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
        }
        .sheet(item: $vm.preview) { item in
            AttachmentPreview(item: item)
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
            }
            .padding(8)
            .background(msg.direction == .outgoing ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            if msg.direction == .incoming { Spacer() }
        }
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
                VStack(alignment: .leading, spacing: 4) {
                    VideoPlayer(player: AVPlayer(url: url))
                        .frame(height: 240)
                        .cornerRadius(6)
                    Button("Expand") {
                        vm.preview = PreviewItem(url: url, mime: att.mimeType, filename: att.filename)
                    }
                    .font(.caption)
                }
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
                    VideoPlayer(player: AVPlayer(url: item.url))
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
