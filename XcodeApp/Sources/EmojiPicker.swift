import SwiftUI
import AppKit

/// macOS Character Viewer (Emoji & Symbols) integration for reactions.
///
/// There is no public API to read the picker's selection, so this hosts a
/// hidden `NSTextField`, makes it first responder, and opens the viewer on
/// top: whatever the user picks lands in the field, is captured via
/// `textDidChange`, and forwarded as the reaction. Standard macOS behavior,
/// full emoji set, zero maintenance.
struct AppleEmojiCatcher: NSViewRepresentable {
    var onPick: (String) -> Void

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.backgroundColor = .clear
        field.textColor = .clear
        field.stringValue = ""
        field.placeholderString = "…"
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.changed(_:)),
            name: NSControl.textDidChangeNotification,
            object: field
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Become first responder so the viewer types into us, then ask
        // AppKit (via its private Edit-menu action) to show the viewer.
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
            NSApp.sendAction(Selector(("orderFrontCharacterPicker:")), to: nil, from: nsView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    @MainActor
    final class Coordinator: NSObject {
        var onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) {
            self.onPick = onPick
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc func changed(_ note: Notification) {
            guard let field = note.object as? NSTextField else { return }
            let picked = field.stringValue
            guard !picked.isEmpty else { return }
            field.stringValue = ""
            onPick(picked)
        }
    }
}

/// Popover content hosting the catcher: invisible field + hint.
struct AppleEmojiCatcherView: View {
    var onPick: (String) -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text("Pick an emoji").font(.headline)
            Text("Choose in the Character Viewer, then press Esc.")
                .font(.caption).foregroundStyle(.secondary)
            AppleEmojiCatcher(onPick: onPick)
                .frame(width: 120, height: 24)
        }
        .padding()
    }
}
