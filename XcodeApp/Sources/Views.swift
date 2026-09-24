import SwiftUI
import CoreImage.CIFilterBuiltins

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
                .tag(conv.id)
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

    var body: some View {
        VStack(spacing: 0) {
            if !vm.isLinked {
                LinkDeviceView()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(vm.messages, id: \.id) { msg in
                            HStack {
                                if msg.direction == .outgoing { Spacer() }
                                Text(msg.body)
                                    .padding(8)
                                    .background(msg.direction == .outgoing ? Color.accentColor.opacity(0.2) : Color.gray.opacity(0.15))
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                if msg.direction == .incoming { Spacer() }
                            }
                        }
                    }
                    .padding()
                }
                Divider()
                HStack {
                    TextField("Message", text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { send() }
                    Button("Send") { send() }
                        .keyboardShortcut(.return)
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding()
            }
        }
    }

    private func send() {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        draft = ""
        Task { await vm.send(body) }
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
