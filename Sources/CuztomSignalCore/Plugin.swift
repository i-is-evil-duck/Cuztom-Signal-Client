import Foundation

/// Modular plugin system. Plugins react to `/commands` typed in the message
/// field and to inbound traffic. All execution happens on callers' executors;
/// the host itself is `@MainActor`-bound (it lives in the ViewModel).
///
/// Built-ins live next to this file (`InfoPlugin`). Drop a new type
/// conforming to `ChatPlugin` into `Sources/CuztomSignalPlugins/` (or
/// anywhere in Core) and register it where the host is created.

public enum InputResult: Sendable {
    /// Not a command — send the text to Signal as usual.
    case sendOriginal
    /// Command handled; show this reply as an ephemeral local message.
    case reply(String)
    /// Handled silently.
    case silent
}

public struct PluginCommand: Sendable {
    public var name: String
    public var description: String
    public var usage: String

    public init(name: String, description: String, usage: String = "") {
        self.name = name
        self.description = description
        self.usage = usage
    }
}

/// Read-only capabilities handed to plugins. Fully Sendable so plugins can
/// run anywhere; the host wires these to the live controller.
public struct PluginContext: Sendable {
    public var conversations: @Sendable () async -> [Conversation]
    public var selectedThread: @Sendable () async -> String?
    public var recentMessages: @Sendable (String, Int) async -> [ChatMessage]
    public var diagnostics: @Sendable () async -> String
    public var account: @Sendable () async -> String
    public var rosterSummary: @Sendable () async -> String
    public var requestSync: @Sendable () async -> Bool

    public init(
        conversations: @Sendable @escaping () async -> [Conversation],
        selectedThread: @Sendable @escaping () async -> String?,
        recentMessages: @Sendable @escaping (String, Int) async -> [ChatMessage],
        diagnostics: @Sendable @escaping () async -> String,
        account: @Sendable @escaping () async -> String,
        rosterSummary: @Sendable @escaping () async -> String,
        requestSync: @Sendable @escaping () async -> Bool
    ) {
        self.conversations = conversations
        self.selectedThread = selectedThread
        self.recentMessages = recentMessages
        self.diagnostics = diagnostics
        self.account = account
        self.rosterSummary = rosterSummary
        self.requestSync = requestSync
    }
}

public protocol ChatPlugin: Sendable {
    var id: String { get }
    var name: String { get }
    var version: String { get }
    var commands: [PluginCommand] { get }
    /// Return reply text, or nil to stay silent.
    func handle(command: String, args: String, ctx: PluginContext) async -> String?
    /// Fired for every inbound/store message. Default: ignore.
    func onMessage(_ message: ChatMessage, ctx: PluginContext) async
}

public extension ChatPlugin {
    func onMessage(_ message: ChatMessage, ctx: PluginContext) async {}
}

@MainActor
public final class PluginHost {
    private var plugins: [any ChatPlugin] = []

    public init(plugins: [any ChatPlugin] = []) {
        self.plugins = plugins
    }

    public func register(_ plugin: any ChatPlugin) {
        plugins.removeAll { $0.id == plugin.id }
        plugins.append(plugin)
    }

    public var pluginList: [any ChatPlugin] { plugins }

    /// Route `/command args…`. Non-`/` text returns `.sendOriginal`.
    public func handleInput(_ text: String, ctx: PluginContext) async -> InputResult {
        guard text.hasPrefix("/") else { return .sendOriginal }
        let stripped = String(text.dropFirst())
        let parts = stripped.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let raw = parts.first else { return .sendOriginal }
        let name = raw.lowercased()
        let args = parts.count > 1 ? String(parts[1]) : ""

        if name == "help" {
            return .reply(helpText())
        }
        for plugin in plugins {
            if plugin.commands.contains(where: { $0.name == name }) {
                if let reply = await plugin.handle(command: name, args: args, ctx: ctx) {
                    return .reply(reply)
                }
                return .silent
            }
        }
        return .reply("unknown command /\(name) — try /help")
    }

    public func notifyMessage(_ message: ChatMessage, ctx: PluginContext) async {
        for plugin in plugins {
            await plugin.onMessage(message, ctx: ctx)
        }
    }

    private func helpText() -> String {
        var lines = ["commands:"]
        for plugin in plugins {
            for cmd in plugin.commands {
                let usage = cmd.usage.isEmpty ? "" : " \(cmd.usage)"
                lines.append("/\(cmd.name)\(usage) — \(cmd.description) [\(plugin.name)]")
            }
        }
        lines.append("/help — this list")
        return lines.joined(separator: "\n")
    }
}
