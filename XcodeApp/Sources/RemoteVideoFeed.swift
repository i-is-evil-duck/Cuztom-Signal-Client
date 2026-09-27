import CoreGraphics
import Foundation
import SwiftUI

import CuztomSignalCore

/// Draws one remote participant's video by polling the core for new frames.
///
/// Polling rather than a callback, and that is the important decision. RingRTC
/// delivers frames on its decoder thread and warns that holding one stalls
/// decoding, so the copy has to happen there and return immediately. A callback
/// into Swift would put an unknown consumer on that thread; a poll keeps the
/// decoder's work bounded and lets this side drop frames instead of stalling it.
///
/// One frame in flight at a time: the newest sequence asked about is remembered,
/// so a slow display costs smoothness and nothing else.
@MainActor
@Observable
public final class RemoteVideoFeed: Identifiable {
    public let id: UInt32
    public let demuxId: UInt32

    /// The newest frame drawn, as a layer-ready image.
    public private(set) var image: CGImage?
    /// The sequence last drawn, so a poll asks only for something newer.
    private var drawnSequence: UInt64 = 0
    /// Reused between frames. The core copies out synchronously, so one buffer
    /// sized for the largest frame seen is enough and there is no per-frame
    /// allocation on the polling path.
    private var buffer: [UInt8] = []
    /// Frames the core has published for this participant, for the log. A count
    /// that never moves is how "video is not arriving" gets told apart from "video
    /// is arriving and not being drawn".
    public private(set) var framesDrawn: Int = 0

    private let service: RustCoreService?

    public init(demuxId: UInt32, service: RustCoreService?) {
        self.id = demuxId
        self.demuxId = demuxId
        self.service = service
    }

    public var isShowingVideo: Bool { image != nil }

    /// Whether anybody is known to be sending video at all.
    ///
    /// Separate from `isShowingVideo`, because "nobody is sending" and "somebody is
    /// sending and we have not drawn a frame yet" are different states and the
    /// second is worth waiting for rather than reporting as no video.
    public var hasFrames: Bool { framesDrawn > 0 }

    /// Look for a newer frame and draw it if there is one.
    ///
    /// Returns whether anything was drawn, so a caller can tell "no news" from
    /// "drew something" without inspecting the image.
    @discardableResult
    public func poll() async -> Bool {
        guard let service else { return false }
        // Size first: the dimensions are not known in advance and change with a
        // participant's resolution. Asking every time is cheap — it is one FFI
        // call and no allocation — where caching the size would mean drawing a
        // stale shape after a resolution change.
        let needed = await service.groupCallVideoFrameSize(clientId: demuxId)
        guard needed > 0 else {
            // No frame at all. Clearing rather than leaving the last one up: a
            // participant who stopped sending should stop being shown, or the
            // picture freezes and looks like a live call.
            if image != nil {
                image = nil
                drawnSequence = 0
                return true
            }
            return false
        }
        if buffer.count != needed {
            buffer = [UInt8](repeating: 0, count: needed)
        }
        guard let frame = await service.groupCallTakeVideoFrame(
            clientId: demuxId,
            sinceSequence: drawnSequence
        ) else {
            return false
        }
        guard let next = VideoFrameImage.image(
            pixels: frame.pixels,
            width: frame.width,
            height: frame.height
        ) else {
            // A frame arrived and could not be drawn. The sequence is still
            // advanced, so a frame that cannot be rendered is not retried
            // forever at the cost of every later one.
            drawnSequence = frame.sequence
            return false
        }
        drawnSequence = frame.sequence
        image = next
        framesDrawn += 1
        return true
    }
}
