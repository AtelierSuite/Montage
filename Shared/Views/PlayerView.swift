import AVFoundation
import SwiftUI

/// A player's picture, fitted into the view, without any playback controls of
/// its own: the editor has its transport.
struct PlayerView {
    let player: AVPlayer
}

#if os(macOS)
extension PlayerView: NSViewRepresentable {
    func makeNSView(context: Context) -> PlayerLayerView {
        PlayerLayerView()
    }

    func updateNSView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleNSView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// A view backed by a player layer.
final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    init() {
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        playerLayer.backgroundColor = .black
        // Hosting the layer, rather than drawing into one, so it fills the
        // view as the view resizes.
        layer = playerLayer
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
#else
extension PlayerView: UIViewRepresentable {
    func makeUIView(context: Context) -> PlayerLayerView {
        PlayerLayerView()
    }

    func updateUIView(_ view: PlayerLayerView, context: Context) {
        view.playerLayer.player = player
    }

    static func dismantleUIView(_ view: PlayerLayerView, coordinator: ()) {
        view.playerLayer.player = nil
    }
}

/// A view backed by a player layer.
final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }

    init() {
        super.init(frame: .zero)
        playerLayer.videoGravity = .resizeAspect
        backgroundColor = .black
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
#endif
