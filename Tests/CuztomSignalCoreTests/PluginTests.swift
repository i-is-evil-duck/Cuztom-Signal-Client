import Foundation
import Testing
@testable import CuztomSignalCore

private func testCtx(
    convs: [Conversation] = [],
    msgs: [ChatMessage] = [],
    diag: String = "diag-ok",
    account: String = "+1000",
    roster: String = "1 contacts",
    syncOk: Bool = true
) -> PluginContext {
    PluginContext(
        conversations: { convs },
        selectedThread: { "c1" },
        recentMessages: { _, _ in msgs },
        diagnostics: { diag },
        account: { account },
        rosterSummary: { roster },
        requestSync: { syncOk }
    )
}

@Test func hostPassesThroughNormalText() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let result = await host.handleInput("hello world", ctx: testCtx())
    guard case .sendOriginal = result else {
        Issue.record("expected sendOriginal, got \(result)")
        return
    }
}

@Test func hostHandlesInfoCommands() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let ctx = testCtx()
    let info = await host.handleInput("/info", ctx: ctx)
    guard case .reply(let text) = info else {
        Issue.record("expected reply for /info"); return
    }
    #expect(text.contains("CuztomSignal"))
    let diag = await host.handleInput("/diag", ctx: ctx)
    guard case .reply(let dtext) = diag else {
        Issue.record("expected reply for /diag"); return
    }
    #expect(dtext == "diag-ok")
    let sync = await host.handleInput("/sync", ctx: ctx)
    guard case .reply(let stext) = sync else {
        Issue.record("expected reply for /sync"); return
    }
    #expect(stext.contains("requested"))
}

@Test func hostRejectsUnknownCommand() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let result = await host.handleInput("/nope", ctx: testCtx())
    guard case .reply(let text) = result else {
        Issue.record("expected reply for unknown command"); return
    }
    #expect(text.contains("unknown command"))
}

@Test func hostHelpListsCommands() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let result = await host.handleInput("/help", ctx: testCtx())
    guard case .reply(let text) = result else {
        Issue.record("expected reply for /help"); return
    }
    #expect(text.contains("/info"))
    #expect(text.contains("/thread"))
}

@Test func whereamiShowsOpenThread() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let result = await host.handleInput("/whereami", ctx: testCtx(diag: "last sent to: contact:x"))
    guard case .reply(let text) = result else {
        Issue.record("expected reply for /whereami"); return
    }
    #expect(text.contains("open thread: c1"))
    #expect(text.contains("last sent to: contact:x"))
}

@Test func threadCommandDumpsMessages() async {
    let host = await PluginHost(plugins: [InfoPlugin()])
    let msg = ChatMessage(conversationId: "c1", author: SignalAddress(phone: "+1"),
                          body: "hello", direction: .incoming, status: .delivered)
    let result = await host.handleInput("/thread c1 5", ctx: testCtx(msgs: [msg]))
    guard case .reply(let text) = result else {
        Issue.record("expected reply for /thread"); return
    }
    #expect(text.contains("hello"))
    #expect(text.contains("thread c1"))
}

@Test func ephemeralRepliesAreNotStored() async {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.select("c1")
    await controller.injectEphemeral("plugin says hi")
    let shown = await controller.messages
    #expect(shown.count == 1)
    #expect(shown[0].author.uuidString == "plugin")
    // A re-select reloads from the store, which must not contain it.
    await controller.select("c1")
    let reloaded = await controller.messages
    #expect(reloaded.isEmpty)
}

@Test func sendOrCommandRoutesSlashToEphemeral() async {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.select("c1")
    let host = await PluginHost(plugins: [InfoPlugin()])
    let ctx = PluginContext(
        conversations: { await controller.conversations },
        selectedThread: { await controller.selectedId },
        recentMessages: { id, n in await controller.messages(in: id, limit: n) },
        diagnostics: { "d" },
        account: { "a" },
        rosterSummary: { "r" },
        requestSync: { true }
    )
    await controller.sendOrCommand("/info", plugins: host, ctx: ctx)
    let shown = await controller.messages
    #expect(shown.count == 1)
    #expect(shown[0].body.contains("CuztomSignal"))
    // Plain text still sends through the service (ephemeral replays drop on
    // the store reload, by design — they are never persisted).
    await controller.sendOrCommand("hello", plugins: host, ctx: ctx)
    let after = await controller.messages
    #expect(after.count == 1)
    #expect(after.last?.direction == .outgoing)
}

@Test func loadMoreWithMockReportsExhausted() async {
    let conv = Conversation(id: "c1", title: "Peer", peer: SignalAddress(phone: "+1"))
    let svc = MockSignalService(seedConversations: [conv])
    let controller = await ChatController(service: svc)
    await controller.link()
    await controller.select("c1")
    // Mock seed never grows: loadMore finds nothing new.
    #expect(!(await controller.loadMore(chunk: 10)))
    if case .exhausted = await controller.loadMoreResult(chunk: 10) {
        // expected
    } else {
        Issue.record("expected exhausted history result")
    }
}

@Test func pluginRegisterReplacesSameId() async {
    struct Echo: ChatPlugin {
        var id: String { "x" }
        var name: String { "Echo" }
        var version: String { "0" }
        var commands: [PluginCommand] { [] }
        func handle(command: String, args: String, ctx: PluginContext) async -> String? { nil }
    }
    let host = await PluginHost()
    await host.register(Echo())
    await host.register(Echo())
    let list = await host.pluginList
    #expect(list.count == 1)
}
