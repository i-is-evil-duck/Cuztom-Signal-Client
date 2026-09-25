import SwiftUI
import CuztomSignalCore
import AppKit

struct SettingsView: View {
    @Environment(ChatViewModel.self) private var vm

    var body: some View {
        @Bindable var vm = vm
        Form {
            Section("Session") {
                LabeledContent("Build", value: vm.buildVersionTag)
                LabeledContent("Connection", value: vm.connectionText)
                LabeledContent("Account", value: vm.accountLine)
                Button("Log out…", role: .destructive) {
                    Task { await vm.logout() }
                }
                .disabled(!vm.isLinked || vm.isLoggingOut)
                Text("Logging out wipes keys and the session. The next launch shows a fresh QR code.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sync") {
                Button("Refresh now") { Task { await vm.refreshNow() } }
                    .disabled(!vm.isLinked)
                Button("Request contact sync") { Task { await vm.requestSync() } }
                    .disabled(!vm.isLinked)
                LabeledContent("Last sync event", value: vm.syncNote)
                if let err = vm.errorMessage {
                    LabeledContent("Last error") { Text(err).font(.caption).monospaced() }
                }
            }
            Section("Notifications") {
                Toggle("Message and call notifications", isOn: $vm.notificationsEnabled)
                Toggle("Show message/caller details", isOn: $vm.showNotificationPreviews)
                Text("Details are hidden by default so notification lock screens do not expose message text or caller names.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Toggle("Allow link previews", isOn: $vm.linkPreviewsEnabled)
                Text("Link previews are disabled by default. When enabled, only bounded public HTTPS pages are fetched; private and local network addresses are blocked.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Read Receipts") {
                Toggle("Send Read Receipts", isOn: $vm.sendReadReceipts)
                    .disabled(!vm.isLinked)
                Toggle("Send Delivery Receipts", isOn: $vm.sendDeliveryReceipts)
                    .disabled(!vm.isLinked)
                Text("When enabled, read/delivery receipts are automatically sent when you view messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Diagnostics") {
                Text(vm.diagnosticsText.isEmpty ? "—" : vm.diagnosticsText)
                    .font(.caption).monospaced()
                    .textSelection(.enabled)
                HStack {
                    Button("Copy diagnostics") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(vm.diagnosticsText, forType: .string)
                    }
                    Button("Reveal log in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([Log.fileURL])
                    }
                }
                Button("Refresh diagnostics") { Task { await vm.refreshNow() } }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .padding()
    }
}
