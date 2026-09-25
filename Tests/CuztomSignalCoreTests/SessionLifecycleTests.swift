import Foundation
import Testing
@testable import CuztomSignalCore

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set() {
        lock.lock()
        stored = true
        lock.unlock()
    }
}

@Test func serialNativeExecutorDoesNotOverlapOperations() async throws {
    let executor = SerialNativeExecutor(label: "test.native.\(UUID().uuidString)")
    let firstStarted = LockedFlag()
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEnqueued = LockedFlag()
    let secondStarted = LockedFlag()

    let first = Task {
        try await executor.run {
            firstStarted.set()
            releaseFirst.wait()
            return 1
        }
    }
    while !firstStarted.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let second = Task {
        try await executor.run({
            secondStarted.set()
            return 2
        }, onEnqueue: {
            secondEnqueued.set()
        })
    }
    while !secondEnqueued.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    // The second operation must remain behind the blocked first operation.
    #expect(!secondStarted.value)
    releaseFirst.signal()
    #expect(try await first.value == 1)
    #expect(try await second.value == 2)
    #expect(secondStarted.value)
}

@Test func serialNativeExecutorSkipsQueuedOperationAfterCancellation() async throws {
    let executor = SerialNativeExecutor(label: "test.native.cancel.\(UUID().uuidString)")
    let firstStarted = LockedFlag()
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEnqueued = LockedFlag()
    let secondRan = LockedFlag()

    let first = Task {
        try await executor.run {
            firstStarted.set()
            releaseFirst.wait()
            return 1
        }
    }
    while !firstStarted.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let second = Task {
        try await executor.run({
            secondRan.set()
            return 2
        }, onEnqueue: {
            secondEnqueued.set()
        })
    }
    while !secondEnqueued.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    second.cancel()
    releaseFirst.signal()
    #expect(try await first.value == 1)

    do {
        _ = try await second.value
        Issue.record("expected queued native operation to observe cancellation")
    } catch is CancellationError {
        // expected
    } catch {
        Issue.record("wrong cancellation error: \(error)")
    }
    #expect(!secondRan.value)
}

@Test func cancellationDuringNativeOperationReturnsCompletedResult() async throws {
    let executor = SerialNativeExecutor(label: "test.native.inflight.\(UUID().uuidString)")
    let started = LockedFlag()
    let release = DispatchSemaphore(value: 0)
    let operation = Task {
        try await executor.run {
            started.set()
            release.wait()
            return 7
        }
    }
    while !started.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    operation.cancel()
    release.signal()
    #expect(try await operation.value == 7)
}

@Test func asyncLifecycleGateSerializesTransitions() async throws {
    let gate = AsyncOperationGate()
    let firstEntered = LockedFlag()
    let secondSubmitted = LockedFlag()
    let secondEntered = LockedFlag()

    let first = Task {
        try await gate.run {
            firstEntered.set()
            try await Task.sleep(nanoseconds: 50_000_000)
            return 1
        }
    }
    while !firstEntered.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }

    let second = Task {
        secondSubmitted.set()
        return try await gate.run {
            secondEntered.set()
            return 2
        }
    }
    while !secondSubmitted.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    #expect(!secondEntered.value)

    #expect(try await first.value == 1)
    #expect(try await second.value == 2)
    #expect(secondEntered.value)
}

@Test func asyncGateDoesNotDeadlockCanceledWaiter() async throws {
    let gate = AsyncOperationGate()
    let firstEntered = LockedFlag()
    let secondSubmitted = LockedFlag()
    let first = Task {
        try await gate.run {
            firstEntered.set()
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
    while !firstEntered.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    let second = Task {
        secondSubmitted.set()
        try await gate.run {}
    }
    while !secondSubmitted.value {
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    second.cancel()
    do {
        try await second.value
        Issue.record("expected canceled gate waiter to fail")
    } catch is CancellationError {
        // expected
    }
    try await first.value
}

@Test func failedNativeTeardownPoisonsServiceAgainstRelink() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-poison-test-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let databasePath = directory.appendingPathComponent("signal.db").path
    let service = RustCoreService(
        libraryPath: "/nonexistent/libcuztom_signal_core.dylib",
        dbPath: databasePath
    )
    do {
        try await service.clearAllData()
        Issue.record("expected missing native library during teardown")
    } catch SignalError.unsupported {
        // expected
    } catch {
        Issue.record("wrong teardown error: \(error)")
    }

    do {
        _ = try await service.isLinkedAccount()
        Issue.record("expected poisoned service to reject native reads")
    } catch SignalError.sessionInvalidated {
        // expected
    } catch {
        Issue.record("wrong poisoned read error: \(error)")
    }

    do {
        _ = try await service.beginLinking(deviceName: "TestMac")
        Issue.record("expected poisoned service to reject relink")
    } catch SignalError.sessionInvalidated {
        // expected
    } catch {
        Issue.record("wrong poisoned relink error: \(error)")
    }

    let replacement = RustCoreService(
        libraryPath: "/nonexistent/libcuztom_signal_core.dylib",
        dbPath: databasePath
    )
    do {
        _ = try await replacement.isLinkedAccount()
        Issue.record("expected a new service instance to inherit process poison")
    } catch SignalError.sessionInvalidated {
        // expected
    } catch {
        Issue.record("wrong process poison error: \(error)")
    }
}

@Test func logoutIsIdempotentWhenAlreadyUnlinked() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-logout-idempotent-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = RustCoreService(
        libraryPath: "/nonexistent/libcuztom_signal_core.dylib",
        dbPath: directory.appendingPathComponent("signal.db").path
    )
    try await service.logout()
    try await service.logout()
}

@Test func presentationWipeFailurePoisonsNativeService() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("cuztom-presentation-poison-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let service = RustCoreService(
        libraryPath: "/nonexistent/libcuztom_signal_core.dylib",
        dbPath: directory.appendingPathComponent("signal.db").path
    )
    service.poisonAfterPresentationFailure()
    do {
        _ = try await service.isLinkedAccount()
        Issue.record("expected presentation failure to poison native service")
    } catch SignalError.sessionInvalidated {
        // expected
    } catch {
        Issue.record("wrong presentation poison error: \(error)")
    }
}

@Test func suspendedEpochRequiresExplicitResume() throws {
    let epoch = SessionEpoch()
    let old = try epoch.capture()
    #expect(try epoch.resumeIfNeeded() == old)
    _ = epoch.suspend()

    do {
        try epoch.require(old)
        Issue.record("expected suspended token to be rejected")
    } catch SignalError.sessionInvalidated {
        // expected
    }

    let replacement = try epoch.resume()
    #expect(epoch.isCurrent(replacement))
    #expect(replacement != old)

    epoch.poison()
    do {
        _ = try epoch.resume()
        Issue.record("expected poisoned epoch to reject relink")
    } catch SignalError.sessionInvalidated {
        // expected
    }
}
