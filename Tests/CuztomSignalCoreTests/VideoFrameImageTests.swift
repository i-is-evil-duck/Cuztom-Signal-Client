import CoreGraphics
import Foundation
import Testing

@testable import CuztomSignalCore

@Suite("Video frame to image")
struct VideoFrameImageTests {
    /// A frame has to become a drawable image at the size the core said.
    ///
    /// The dimensions come from the core rather than being inferred from a byte
    /// count, because a byte count cannot distinguish 640x360 from 360x640 — and
    /// drawing a frame with the wrong shape stretches somebody's face rather than
    /// failing visibly.
    @Test func aFrameBecomesAnImageAtTheGivenSize() throws {
        let width = 8, height = 4
        // Opaque mid-grey, so the image is not accidentally transparent.
        let pixels = [UInt8](repeating: 128, count: width * height * 4)
        let image = try #require(VideoFrameImage.image(pixels: pixels, width: width, height: height))
        #expect(image.width == width)
        #expect(image.height == height)
    }

    /// Portrait and landscape are different pictures, and both have to survive.
    @Test func portraitAndLandscapeFramesKeepTheirShape() throws {
        for (width, height) in [(6, 12), (12, 6), (1, 1)] {
            let pixels = [UInt8](repeating: 200, count: width * height * 4)
            let image = try #require(
                VideoFrameImage.image(pixels: pixels, width: width, height: height),
                "\(width)x\(height) should convert"
            )
            #expect(image.width == width, "\(width)x\(height) width")
            #expect(image.height == height, "\(width)x\(height) height")
        }
    }

    /// Nothing is invented from nothing.
    ///
    /// A blank rectangle and a video that has not started are different things,
    /// and the caller shows them differently — so a frame that cannot exist yields
    /// no image rather than an empty one.
    @Test func anImpossibleFrameYieldsNoImage() {
        #expect(VideoFrameImage.image(pixels: [], width: 0, height: 0) == nil)
        #expect(VideoFrameImage.image(pixels: [1, 2, 3, 4], width: 0, height: 4) == nil)
        #expect(VideoFrameImage.image(pixels: [1, 2, 3, 4], width: 4, height: 0) == nil)
        // Fewer bytes than the stated size: refused rather than read past the end.
        #expect(VideoFrameImage.image(pixels: [1, 2, 3, 4], width: 4, height: 4) == nil)
    }

    /// The caller's buffer is not modified.
    ///
    /// CoreGraphics takes a mutable pointer and may write through it, so the
    /// conversion works on a copy. If that ever stops being true, the next frame
    /// would arrive already corrupted and the fault would be a long way from here.
    @Test func theCallersPixelsAreLeftAlone() throws {
        let width = 4, height = 4
        let pixels = [UInt8](repeating: 77, count: width * height * 4)
        let before = pixels
        _ = VideoFrameImage.image(pixels: pixels, width: width, height: height)
        #expect(pixels == before, "the source buffer must survive untouched")
    }
}
