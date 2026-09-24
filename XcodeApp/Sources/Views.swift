import SwiftUI

struct ContentView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        NavigationSplitView {
            SidebarView()
        } detail: {
            MessageListView()
        }
        .task {
            if !vm.isLinked {
                await vm.startLinking()
                if let first = vm.conversations.first {
                    await vm.select(first.id)
                }
            }
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
            Image(systemName: "qrcode").font(.system(size: 64))
            Text("Link your phone").font(.title2)
            if let qr = vm.linkQR {
                Text(qr.payload).font(.caption).monospaced().foregroundStyle(.secondary)
                Text("M1 will render a real QR from the Rust core (presage link-device).")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ProgressView("Preparing QR…")
            }
        }
        .padding(40)
    }
}
