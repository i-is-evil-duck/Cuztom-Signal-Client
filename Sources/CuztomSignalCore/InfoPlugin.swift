import Foundation

/// Debug/info plugin: read-only introspection for testing and troubleshooting.
/// No network writes except `/sync` (which just asks the phone to re-send
/// contacts — the same button as Settings → Request contact sync).
public struct InfoPlugin: ChatPlugin {
    public var id: String { "cuztom.info" }
    public var name: String { "Info" }
    public var version: String { "1.0.0" }

    public var commands: [PluginCommand] {
        [
            PluginCommand(name: "info", description: "app + backend versions"),
            PluginCommand(name: "account", description: "linked account identity"),
            PluginCommand(name: "roster", description: "cached contacts/groups/message counts"),
            PluginCommand(name: "diag", description: "full diagnostics dump"),
            PluginCommand(name: "sync", description: "request contact sync from phone"),
            PluginCommand(name: "thread", description: "dump a thread", usage: "<conversation-id> [limit]"),
            PluginCommand(name: "log", description: "log file location"),
            PluginCommand(name: "whereami", description: "open thread + last send target"),
        ]
    }

    public init() {}

    public func handle(command: String, args: String, ctx: PluginContext) async -> String? {
        switch command {
        case "info":
            return "CuztomSignal 0.1.0 · Swift 6 + presage/libsignal core"
        case "account":
            return await ctx.account()
        case "roster":
            return await ctx.rosterSummary()
        case "diag":
            return await ctx.diagnostics()
        case "sync":
            return await ctx.requestSync() ? "sync requested — watch for arrivals" : "sync request failed (see diagnostics)"
        case "thread":
            return await dumpThread(args, ctx: ctx)
        case "log":
            return "log: \(Log.fileURL.path)"
        case "whereami":
            let open = await ctx.selectedThread() ?? "none"
            let diag = await ctx.diagnostics()
            let last = diag.split(separator: "\n").first(where: { $0.hasPrefix("last sent to:") }) ?? "last sent to: ?"
            return "open thread: \(open)\n\(last)"
        default:
            return nil
        }
    }

    private func dumpThread(_ args: String, ctx: PluginContext) async -> String {
        let parts = args.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard let id = parts.first, !id.isEmpty else {
            let convs = await ctx.conversations()
            let ids = convs.prefix(10).map(\.id).joined(separator: "\n")
            return "usage: /thread <conversation-id> [limit]\nthreads:\n\(ids)"
        }
        let limit = parts.count > 1 ? Int(parts[1]) ?? 5 : 5
        let msgs = await ctx.recentMessages(id, min(max(limit, 1), 20))
        guard !msgs.isEmpty else { return "thread \(id): no cached messages" }
        let fmt = DateFormatter()
        fmt.dateFormat = "MM-dd HH:mm"
        let lines = msgs.map { m in
            let dir = m.direction == .outgoing ? "→" : "←"
            let body = m.body.isEmpty ? "[attachment]" : String(m.body.prefix(80))
            return "\(dir) [\(fmt.string(from: m.sentAt))] \(body)"
        }
        return "thread \(id) (\(msgs.count)):\n" + lines.joined(separator: "\n")
    }
}
