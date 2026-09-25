import SwiftUI
import AppKit
import AVKit
import AVFoundation
import CryptoKit

/// Video playback via AppKit directly.
///
/// SwiftUI's `VideoPlayer` is intentionally avoided: on macOS 26 it aborts
/// the process while instantiating its representable view
/// (`_AVKit_SwiftUI` metadata init → SIGABRT, crash 2026-09-23).
/// `AVPlayerView` has no such issue.
struct AppKitVideoPlayer: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        // The expanded viewer owns one explicit transport bar. Keeping the
        // AppKit surface control-free avoids two competing scrubbers and
        // stale play/pause state on macOS 26.
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.showsFullScreenToggleButton = false
        view.allowsMagnification = true
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
        nsView.controlsStyle = .none
        nsView.videoGravity = .resizeAspect
        nsView.showsFullScreenToggleButton = false
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player?.replaceCurrentItem(with: nil)
        nsView.player = nil
    }
}

/// Video thumbnail with a play button; opens the full player on tap.
/// Thumbnails are cached under Caches/CuztomSignal/thumbs/.
struct VideoThumbnail: View {
    @Environment(ChatViewModel.self) private var vm
    var url: URL
    var filename: String
    @State private var thumb: NSImage?

    var body: some View {
        Button {
            vm.preview = PreviewItem(url: url, mime: "video/*", filename: filename)
        } label: {
            ZStack {
                Group {
                    if let thumb {
                        Image(nsImage: thumb)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.2))
                    }
                }
                .frame(width: 280, height: 164)
                .cornerRadius(6)
                .clipped()
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(.white)
                    .shadow(radius: 4)
            }
        }
        .buttonStyle(.plain)
        .task(id: url) {
            thumb = nil
            thumb = await Task.detached(priority: .utility) {
                cachedVideoThumbnail(url: url)
            }.value
        }
    }
}

private func thumbsDir() -> URL {
    let base = (try? FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)) ?? FileManager.default.temporaryDirectory
    return base.appendingPathComponent("CuztomSignal/thumbs")
}

private func cachedVideoThumbnail(url: URL) -> NSImage? {
    let digest = SHA256.hash(data: Data(url.path.utf8))
        .map { String(format: "%02x", $0) }
        .joined()
    let key = "\(digest)-\(url.lastPathComponent)"
    let dest = thumbsDir().appendingPathComponent(key).appendingPathExtension("jpg")
    if let img = NSImage(contentsOf: dest) {
        return img
    }
    guard let img = renderVideoThumbnail(url: url),
          let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let jpg = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else {
        return nil
    }
    try? FileManager.default.createDirectory(at: thumbsDir(), withIntermediateDirectories: true)
    try? jpg.write(to: dest)
    return img
}

private func renderVideoThumbnail(url: URL) -> NSImage? {
    let asset = AVAsset(url: url)
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 480, height: 480)
    guard let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) else {
        return nil
    }
    return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
}
