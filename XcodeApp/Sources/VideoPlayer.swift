import SwiftUI
import AppKit
import AVKit

/// Video playback via AppKit directly.
///
/// SwiftUI's `VideoPlayer` is intentionally avoided: on macOS 26 it aborts
/// the process while instantiating its representable view
/// (`_AVKit_SwiftUI` metadata init → SIGABRT, crash 2026-09-23).
/// `AVPlayerView` has no such issue.
struct AppKitVideoPlayer: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = AVPlayer(url: url)
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if let current = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url, current != url {
            nsView.player = AVPlayer(url: url)
        }
    }

    static func dismantleNSView(_ nsView: AVPlayerView, coordinator: ()) {
        nsView.player?.pause()
        nsView.player = nil
    }
}
