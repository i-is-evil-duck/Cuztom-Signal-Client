import Foundation
import Testing
@testable import CuztomSignalCore

/// A scriptable stand-in for the CoreAudio router.
final class FakeAudioRouter: CallAudioRouting, @unchecked Sendable {
    private let lock = NSLock()
    private let routes: [AudioOutputRoute]
    private var currentID: UInt32
    private var capturedID: UInt32?
    private var failNextSwitch = false
    private var switchCount = 0
    private var restoreCount = 0

    init(
        routes: [AudioOutputRoute] = [
            AudioOutputRoute(id: 1, name: "MacBook Air Speakers", kind: .builtInSpeaker),
            AudioOutputRoute(id: 2, name: "Crusher Evo", kind: .bluetooth)
        ],
        currentID: UInt32 = 2
    ) {
        self.routes = routes
        self.currentID = currentID
    }

    func availableOutputRoutes() -> [AudioOutputRoute] { routes }

    func currentOutputRoute() -> AudioOutputRoute? {
        routes.first { $0.id == currentID }
    }

    func captureCurrentRoute() {
        lock.lock()
        capturedID = currentID
        lock.unlock()
    }

    // All state access goes through synchronous helpers: NSLock cannot be
    // taken directly from an async context under Swift 6 concurrency.
    private func beginSwitch() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        switchCount += 1
        let shouldFail = failNextSwitch
        failNextSwitch = false
        return shouldFail
    }

    private func applyRoute(_ id: UInt32) {
        lock.lock()
        currentID = id
        lock.unlock()
    }

    private func beginRestore() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        restoreCount += 1
        return capturedID
    }

    func setSpeakerphone(_ speakerOn: Bool) async throws {
        try await Task.sleep(nanoseconds: 1_000_000)
        if beginSwitch() { throw AudioRoutingError.systemRefused("test refusal") }
        let wanted: AudioOutputRoute.Kind = speakerOn ? .builtInSpeaker : .bluetooth
        guard let target = routes.first(where: { $0.kind == wanted }) else {
            throw AudioRoutingError.noAlternateRoute
        }
        applyRoute(target.id)
    }

    func restoreCapturedRoute() async {
        if let target = beginRestore() { applyRoute(target) }
    }

    func failNextSwitchNow() {
        lock.lock(); failNextSwitch = true; lock.unlock()
    }

    var switches: Int { lock.lock(); defer { lock.unlock() }; return switchCount }
    var restores: Int { lock.lock(); defer { lock.unlock() }; return restoreCount }
    var current: UInt32 { lock.lock(); defer { lock.unlock() }; return currentID }
}

/// Exercises the real CoreAudio path read-only: it enumerates this machine's
/// outputs and classifies them. No device is switched, so it is safe to run
/// anywhere, and it catches CoreAudio misuse (empty results, bad sizes) that a
/// fake router would never reveal.
@Test func realRouterEnumeratesThisMachinesOutputDevices() {
    let router = AudioOutputRouter()
    let routes = router.availableOutputRoutes()

    #expect(!routes.isEmpty, "expected at least one audio output device")
    #expect(routes.allSatisfy { !$0.name.isEmpty })

    let current = router.currentOutputRoute()
    #expect(current != nil, "expected a default output device")
    if let current {
        #expect(routes.contains(current), "default device must appear in the route list")
    }
    // The classifier must place the machine's own speakers in the built-in
    // bucket, otherwise the speaker toggle can never find a target.
    if let builtIn = routes.first(where: { $0.isBuiltIn }) {
        #expect(builtIn.kind == .builtInSpeaker)
    }
}

private func makeOffer(callID: UInt64 = 7) throws -> CallSignal {
    let json = """
    {"kind":"offer","thread":"contact:peer","sender":"peer-uuid","sender_name":"Peer","call_id":\(callID)}
    """
    return try JSONDecoder().decode(CallSignal.self, from: Data(json.utf8))
}

/// Wait for the tracked callback hop to be applied.
private func settle() async {
    try? await Task.sleep(nanoseconds: 150_000_000)
}

@Test @MainActor func speakerToggleMovesAudioAndOnlyThenUpdatesState() async throws {
    let router = FakeAudioRouter()
    let bridge = ScriptedCallBridge()
    let controller = CallController(audioRouter: router)
    await controller.configure(with: bridge, transport: bridge)

    bridge.emit(try makeOffer())
    await settle()
    #expect(controller.activeCall?.callRecord.direction == .incoming)

    controller.setSpeakerOn(true)
    await settle()

    #expect(router.switches == 1)
    #expect(router.current == 1) // moved to the built-in speaker
    #expect(controller.activeCall?.speakerOn == true)
}

@Test @MainActor func speakerToggleDoesNotLieWhenTheSwitchFails() async throws {
    let router = FakeAudioRouter()
    let bridge = ScriptedCallBridge()
    let controller = CallController(audioRouter: router)
    await controller.configure(with: bridge, transport: bridge)

    bridge.emit(try makeOffer())
    await settle()
    router.failNextSwitchNow()

    controller.setSpeakerOn(true)
    await settle()

    // CoreAudio refused the switch, so the UI must not claim a new route.
    #expect(controller.activeCall?.speakerOn == false)
    #expect(router.current == 2)
}

@Test @MainActor func singleOutputMachineDisablesTheSpeakerControl() {
    let onlyBuiltIn = [
        AudioOutputRoute(id: 1, name: "MacBook Air Speakers", kind: .builtInSpeaker)
    ]
    let controller = CallController(
        audioRouter: FakeAudioRouter(routes: onlyBuiltIn, currentID: 1)
    )
    #expect(controller.canToggleSpeaker == false)
}

@Test @MainActor func speakerControlIsAvailableWithAHeadset() {
    let controller = CallController(audioRouter: FakeAudioRouter())
    #expect(controller.canToggleSpeaker == true)
    #expect(controller.speakerRouteDescription == "Switch to built-in speaker")
}

@Test @MainActor func endingACallRestoresThePreCallAudioRoute() async throws {
    let router = FakeAudioRouter(currentID: 2) // started on the headset
    let bridge = ScriptedCallBridge()
    let controller = CallController(audioRouter: router)
    await controller.configure(with: bridge, transport: bridge)

    bridge.emit(try makeOffer())
    await settle()
    controller.setSpeakerOn(true)
    await settle()
    #expect(router.current == 1)

    // The remote hangs up; the native terminal state is what closes the call.
    bridge.emit(try JSONDecoder().decode(
        CallSignal.self,
        from: Data(#"{"kind":"hangup","thread":"contact:peer","sender":"peer-uuid","call_id":7}"#.utf8)
    ))
    await settle()
    bridge.emit(try JSONDecoder().decode(
        CallStateEvent.self,
        from: Data(#"{"thread":"contact:peer","call_id":7,"state":"ended_remote"}"#.utf8)
    ))
    await settle()
    #expect(router.restores >= 1)
    #expect(router.current == 2) // back on the headset the call started on
    #expect(controller.activeCall == nil)
}

@Test @MainActor func resetAwaitsAPendingAudioRouteSwitch() async throws {
    let router = FakeAudioRouter()
    let bridge = ScriptedCallBridge()
    let controller = CallController(audioRouter: router)
    await controller.configure(with: bridge, transport: bridge)

    bridge.emit(try makeOffer())
    await settle()
    controller.setSpeakerOn(true)
    await controller.resetAndAwait()

    // Teardown finished; a stale route switch must not resurrect call state.
    #expect(controller.activeCall == nil)
    #expect(router.current == 2)
}
