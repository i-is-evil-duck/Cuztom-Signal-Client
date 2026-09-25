import Foundation
import Testing
@testable import CuztomSignalCore

private final class ScriptedCallBridge: CallNativeControlling, CallSignalTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var signalHandler: ((CallSignal) -> Void)?
    private var stateHandler: ((CallStateEvent) -> Void)?
    private let muteStarted: AsyncStream<Void>
    private let muteStartedContinuation: AsyncStream<Void>.Continuation
    private let releaseMute: AsyncStream<Void>
    private let releaseMuteContinuation: AsyncStream<Void>.Continuation
    private let startStarted: AsyncStream<Void>
    private let startStartedContinuation: AsyncStream<Void>.Continuation
    private let releaseStart: AsyncStream<Void>
    private let releaseStartContinuation: AsyncStream<Void>.Continuation
    private(set) var muteCalls = 0
    private(set) var hangupCalls = 0

    init() {
        var started: AsyncStream<Void>.Continuation!
        muteStarted = AsyncStream { started = $0 }
        muteStartedContinuation = started
        var release: AsyncStream<Void>.Continuation!
        releaseMute = AsyncStream { release = $0 }
        releaseMuteContinuation = release
        var startStarted: AsyncStream<Void>.Continuation!
        self.startStarted = AsyncStream { startStarted = $0 }
        self.startStartedContinuation = startStarted
        var releaseStart: AsyncStream<Void>.Continuation!
        self.releaseStart = AsyncStream { releaseStart = $0 }
        self.releaseStartContinuation = releaseStart
    }

    var onCallSignal: ((CallSignal) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return signalHandler }
        set { lock.lock(); signalHandler = newValue; lock.unlock() }
    }

    var onCallState: ((CallStateEvent) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return stateHandler }
        set { lock.lock(); stateHandler = newValue; lock.unlock() }
    }

    func startCall(thread: String, mediaType: String) async throws -> UInt64 {
        startStartedContinuation.yield(())
        for await _ in releaseStart { break }
        return 1
    }

    func acceptCall(callId: UInt64) async throws {}

    private func recordHangup() {
        lock.lock()
        hangupCalls += 1
        lock.unlock()
    }

    func hangupCall() async throws {
        recordHangup()
    }

    private func recordMute() {
        lock.lock()
        muteCalls += 1
        lock.unlock()
    }

    func setCallMuted(_ muted: Bool) async throws {
        recordMute()
        muteStartedContinuation.yield(())
        for await _ in releaseMute { break }
    }

    func waitForMute() async {
        for await _ in muteStarted { break }
    }

    func releaseMuteTask() {
        releaseMuteContinuation.yield(())
    }

    func waitForStart() async {
        for await _ in startStarted { break }
    }

    func releaseStartTask() {
        releaseStartContinuation.yield(())
    }

    func sendCallSignal(_ message: CallSignalMessage) async throws {}

    var incomingCallSignals: AsyncStream<CallSignalMessage> {
        AsyncStream { $0.finish() }
    }

    deinit {
        muteStartedContinuation.finish()
        releaseMuteContinuation.finish()
        startStartedContinuation.finish()
        releaseStartContinuation.finish()
    }
}

@Test @MainActor func resetRejectsInFlightCallStart() async throws {
    let bridge = ScriptedCallBridge()
    let controller = CallController()
    controller.microphonePermissionOverride = { true }
    await controller.configure(with: bridge, transport: bridge)

    let start = Task {
        try await controller.startCall(
            to: "contact:peer",
            mediaType: .voice,
            peer: SignalAddress(uuidString: "peer")
        )
    }
    await bridge.waitForStart()
    await controller.resetAndAwait()
    bridge.releaseStartTask()

    do {
        _ = try await start.value
        Issue.record("expected reset to reject the stale call start")
    } catch {
        // expected
    }
    #expect(controller.activeCall == nil)
    #expect(bridge.hangupCalls == 1)
}

@Test @MainActor func resetAwaitsQueuedCallActions() async {
    let bridge = ScriptedCallBridge()
    let controller = CallController()
    await controller.configure(with: bridge, transport: bridge)

    controller.setMuted(true)
    await bridge.waitForMute()
    await controller.resetAndAwait()
    bridge.releaseMuteTask()

    #expect(controller.activeCall == nil)
    #expect(bridge.muteCalls == 1)
}
