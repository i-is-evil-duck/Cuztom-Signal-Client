import CoreGraphics
import Foundation

/// Turns a received video frame into something a layer can draw.
///
/// RGBA in, `CGImage` out. The pixels arrive display-ready and lossy — the native
/// frame buffer is chroma subsampled — so the only job here is to hand them to
/// CoreGraphics in a format it accepts.
///
/// A `CGImage` is immutable, so one is built per frame. That sounds wasteful and
/// is not: the alternative is keeping a bitmap context alive per participant,
/// which costs more and gives back the same allocation. Frames are already
/// dropped rather than queued by the time they reach here, so the rate that
/// matters is the rate that arrives.
public enum VideoFrameImage {
    /// Build an image from tightly packed RGBA bytes.
    ///
    /// Returns `nil` rather than a blank image when the bytes cannot be a frame,
    /// because a blank rectangle and a video that has not started are different
    /// things and the caller shows them differently.
    ///
    /// - Parameters:
    ///   - pixels: `width * height * 4` bytes, tightly packed, straight (not
    ///     premultiplied) alpha.
    ///   - width: from the core, not inferred. Inferring it from a byte count is
    ///     how a 360x640 frame ends up drawn as a square.
    public static func image(
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        guard pixels.count >= width * height * 4 else { return nil }

        // CoreGraphics takes a mutable pointer and may write through it, so it
        // gets a copy rather than the caller's buffer. That is one extra copy per
        // frame -- about 2 MB at the 720px cap, so ~60 MB/s at video rate, against
        // a decoder doing far more work on the same frame. Not worth the
        // complexity of a data provider to avoid, and worth saying out loud
        // rather than leaving a comment claiming otherwise.
        var scratch = pixels

        // `noneSkipLast`, not `premultipliedLast`: the native conversion emits
        // straight alpha, and premultiplied would have CoreGraphics divide colour
        // by an alpha that happens to be 255. Correct by construction rather than
        // correct by accident.
        //
        // Not `last`, which reads like the obvious choice and is rejected outright
        // for 8-bit RGB device colour — `CGContext` returns nil and the frame
        // silently disappears. Measured, not guessed: `premultipliedLast` and
        // `noneSkipLast` are accepted, `last` is not.
        return scratch.withUnsafeMutableBytes { raw -> CGImage? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
                  )
            else { return nil }
            // The context does not copy, so it must not outlive this call. Making
            // the image does the copy that lets `scratch` go.
            return context.makeImage()
        }
    }
}
