import CoreMedia
import MontageEngine
import SwiftUI

/// The preview full screen, held either way up: the picture on black, with
/// the preview's playback controls over it, larger, and a scrubber along the
/// bottom. Plays through the editor's own player, so it carries on from
/// wherever the preview was, and the editor is where it left off after.
/// Swiping down closes it, as does its close button.
struct FullscreenPlayerView: View {
    let playback: PlaybackController

    @Environment(\.dismiss) private var dismiss
    @State private var showsControls = true
    /// How far the picture has been pulled down, to close.
    @State private var pull = 0.0

    /// How far down a swipe has to pull the picture to close it.
    private let closingPull = 120.0

    var body: some View {
        ZStack {
            Color.black
                .opacity(1 - min(pull / 400, 0.5))
                .ignoresSafeArea()
            PlayerView(player: playback.player)
                .ignoresSafeArea()
                .offset(y: pull)
                .scaleEffect(1 - min(pull / 2000, 0.1))
            if let error = playback.playbackError {
                Label {
                    Text(verbatim: error.localizedDescription)
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
                .foregroundStyle(.white.opacity(0.7))
            }
            PlaybackOverlay(playback: playback, isShown: $showsControls, isLarge: true) {
                HStack {
                    PlaybackOverlayButton("Fullscreen.Close", systemImage: "xmark", isLarge: true) { dismiss() }
                    Spacer()
                }
            } bottom: {
                scrubber
            }
            .opacity(pull == 0 ? 1 : 0)
        }
        .gesture(closingDrag)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .preferredColorScheme(.dark)
    }

    // MARK: - Scrubber

    private var scrubber: some View {
        HStack(spacing: 12) {
            timecode(playback.currentTime)
            Slider(value: scrubPosition, in: 0...max(playback.duration.seconds, 0.001)) { isEditing in
                if isEditing {
                    playback.beginScrubbing()
                } else {
                    playback.endScrubbing()
                }
            }
            .accessibilityLabel(Text("Fullscreen.Position"))
            timecode(playback.duration)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 640)
        .glassEffect(.clear, in: .capsule)
    }

    private func timecode(_ time: CMTime) -> some View {
        Text(verbatim: playback.frames.timecode(time))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.9))
            .fixedSize()
    }

    /// The playhead, in seconds, for the slider; moving it scrubs.
    private var scrubPosition: Binding<Double> {
        Binding {
            playback.currentTime.seconds
        } set: { seconds in
            playback.scrub(to: playback.frames.snapped(CMTime(seconds: seconds, preferredTimescale: 6000)))
        }
    }

    // MARK: - Closing

    /// Pulling the picture down closes it once it's far enough; let go
    /// before, it springs back.
    private var closingDrag: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                pull = max(0, value.translation.height)
            }
            .onEnded { value in
                if value.translation.height > closingPull || value.predictedEndTranslation.height > closingPull * 2 {
                    dismiss()
                } else {
                    withAnimation(.spring(duration: 0.3)) { pull = 0 }
                }
            }
    }
}
