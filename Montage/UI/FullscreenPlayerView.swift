import MontageEngine
import SwiftUI

/// The preview full screen, held either way up: the picture on black, with
/// the preview's playback controls over it, larger, and a scrubber along the
/// bottom. Plays through the editor's own player, so it carries on from
/// wherever the preview was, and the editor is where it left off after.
///
/// It zooms out of the preview it was opened from, and back into it when
/// it's swiped down or closed.
struct FullscreenPlayerView: View {
    let playback: PlaybackController

    @Environment(\.dismiss) private var dismiss
    @State private var showsControls = true

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            PlayerView(player: playback.player)
                .ignoresSafeArea()
            if let error = playback.playbackError {
                Label {
                    Text(verbatim: error.localizedDescription)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            // Over the whole screen, so play and pause sit in the middle of the
            // picture, with the rest kept in the safe area.
            GeometryReader { safeArea in
                PlaybackOverlay(
                    playback: playback, isShown: $showsControls, size: .large, contentInsets: safeArea.safeAreaInsets
                ) {
                    HStack {
                        PlaybackOverlayButton("Fullscreen.Close", systemImage: "xmark", isLarge: true) { dismiss() }
                        Spacer()
                    }
                } bottom: {
                    PlaybackScrubber(playback: playback)
                }
                .ignoresSafeArea()
            }
        }
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
    }
}
