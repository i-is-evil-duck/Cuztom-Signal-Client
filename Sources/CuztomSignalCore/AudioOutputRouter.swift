import CoreAudio
import Foundation

/// A macOS audio output device a call can be routed to.
public struct AudioOutputRoute: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable, Equatable {
        /// The machine's own speakers or headphone jack.
        case builtInSpeaker
        case bluetooth
        case usb
        case display
        case virtual
        case other
    }

    public let id: UInt32
    public let name: String
    public let kind: Kind

    public init(id: UInt32, name: String, kind: Kind) {
        self.id = id
        self.name = name
        self.kind = kind
    }

    public var isBuiltIn: Bool { kind == .builtInSpeaker }
}

/// Why a speaker toggle could not be honoured.
public enum AudioRoutingError: Error, LocalizedError, Equatable {
    /// There is no other device to move audio to.
    case noAlternateRoute
    /// CoreAudio refused the switch.
    case systemRefused(String)

    public var errorDescription: String? {
        switch self {
        case .noAlternateRoute:
            return "No other audio output is available"
        case .systemRefused(let detail):
            return "Could not switch audio output: \(detail)"
        }
    }
}

/// Real output routing for the call UI.
///
/// RingRTC plays through whatever CoreAudio reports as the system default
/// output, so toggling the speaker button means switching that default between
/// the built-in speaker and the connected headset. The route in use before the
/// call is captured so the toggle can return to it instead of guessing.
///
/// A Mac's headphone jack is usually part of the *same* device as its built-in
/// speakers, so plugging in wired headphones needs no device switch and
/// reports no alternate route. That is reported honestly instead of pretending
/// to toggle.
public protocol CallAudioRouting: Sendable {
    /// Every connected device that can play audio.
    func availableOutputRoutes() -> [AudioOutputRoute]
    /// The device audio is playing through right now.
    func currentOutputRoute() -> AudioOutputRoute?
    /// Remember the current default so `restoreCapturedRoute()` can return to it.
    func captureCurrentRoute()
    /// `true` moves audio to the built-in speaker, `false` to the headset.
    func setSpeakerphone(_ speakerOn: Bool) async throws
    /// Undo a speaker toggle by returning to the captured pre-call route.
    func restoreCapturedRoute() async
}

public final class AudioOutputRouter: CallAudioRouting, @unchecked Sendable {
    private let lock = NSLock()
    private var capturedRouteID: UInt32?

    public init() {}

    // MARK: - Discovery

    public func availableOutputRoutes() -> [AudioOutputRoute] {
        Self.outputDeviceIDs().compactMap { Self.describe($0) }
    }

    public func currentOutputRoute() -> AudioOutputRoute? {
        guard let id = AudioOutputRouter.defaultOutputDeviceID() else { return nil }
        return AudioOutputRouter.describe(id)
    }

    public func captureCurrentRoute() {
        let id = AudioOutputRouter.defaultOutputDeviceID()
        lock.lock()
        capturedRouteID = id
        lock.unlock()
    }

    // MARK: - Switching

    public func setSpeakerphone(_ speakerOn: Bool) async throws {
        let routes = availableOutputRoutes()
        guard !routes.isEmpty else { throw AudioRoutingError.noAlternateRoute }

        let target: AudioOutputRoute
        if speakerOn {
            guard let builtIn = routes.first(where: { $0.isBuiltIn }) else {
                // Desktop hardware with no internal speaker: "speaker on" has
                // no meaning, so do not pretend it worked.
                throw AudioRoutingError.noAlternateRoute
            }
            target = builtIn
        } else {
            guard let headset = preferredHeadset(routes) else {
                throw AudioRoutingError.noAlternateRoute
            }
            target = headset
        }

        guard target.id != AudioOutputRouter.defaultOutputDeviceID() else { return }
        try AudioOutputRouter.setDefaultOutputDevice(target.id)
    }

    public func restoreCapturedRoute() async {
        let captured = capturedRoute()
        guard let captured, captured != AudioOutputRouter.defaultOutputDeviceID() else { return }
        // The captured device may have been unplugged mid-call. Restoring is
        // best effort and must never surface as a call failure.
        try? AudioOutputRouter.setDefaultOutputDevice(captured)
    }

    private func capturedRoute() -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return capturedRouteID
    }

    /// Prefer the route the user was already on, then wireless headsets, then
    /// wired, then a display. Anything internal is not a "headset".
    private func preferredHeadset(_ routes: [AudioOutputRoute]) -> AudioOutputRoute? {
        if let captured = capturedRoute(),
           let match = routes.first(where: { $0.id == captured }), !match.isBuiltIn {
            return match
        }
        let order: [AudioOutputRoute.Kind] = [.bluetooth, .usb, .display, .other]
        for kind in order {
            if let match = routes.first(where: { $0.kind == kind }) { return match }
        }
        return nil
    }

    // MARK: - CoreAudio plumbing

    private static var systemObject: AudioObjectID { AudioObjectID(kAudioObjectSystemObject) }

    private static func outputDeviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }

        // Read into an explicitly sized buffer. CoreAudio writes exactly the
        // byte count it reported, so the allocation must match it precisely.
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioDeviceID>.alignment
        )
        defer { buffer.deallocate() }

        var written = size
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &written, buffer) == noErr
        else { return [] }

        let count = Int(written) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        let typed = buffer.assumingMemoryBound(to: AudioDeviceID.self)
        return (0..<count).map { typed[$0] }
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &id) == noErr,
              id != AudioDeviceID(0) else { return nil }
        return id
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) throws {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = id
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectSetPropertyData(
            systemObject, &address, 0, nil, size, &device
        )
        guard status == noErr else {
            throw AudioRoutingError.systemRefused(
                String(format: "CoreAudio status %d", status)
            )
        }
    }

    /// Describe a device, or `nil` when it cannot play audio (inputs, or
    /// disabled devices).
    static func describe(_ id: AudioDeviceID) -> AudioOutputRoute? {
        guard hasOutputStreams(id) else { return nil }
        return AudioOutputRoute(
            id: id,
            name: deviceName(id) ?? "Audio Output",
            kind: transportKind(id)
        )
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        // A stream configuration list is at least large enough to hold its
        // buffer count; anything smaller cannot describe a playing device.
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr,
              size >= UInt32(MemoryLayout<UInt32>.size) else { return false }
        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }
        // The buffer count is the first field of the returned AudioBufferList.
        return buffer.assumingMemoryBound(to: AudioBufferList.self).pointee.mNumberBuffers > 0
    }

    private static func deviceName(_ id: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            AudioObjectGetPropertyData(
                id, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer)
            )
        }
        guard status == noErr else { return nil }
        let value = name as String
        return value.isEmpty ? nil : value
    }

    private static func transportKind(_ id: AudioDeviceID) -> AudioOutputRoute.Kind {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport = UInt32(kAudioDeviceTransportTypeUnknown)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else {
            return .other
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn:
            return .builtInSpeaker
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return .bluetooth
        case kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeThunderbolt:
            return .usb
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return .display
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return .virtual
        default:
            return .other
        }
    }
}
