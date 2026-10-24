import CoreMedia
import MontageEngine
import SwiftUI

/// The preview full screen, held either way up: the picture on black, with
/// playback controls that come and go with a tap, out of the way while it
/// plays. Plays through the editor's own player, so it carries on from
/// wherever the preview was, and the editor is where it left off after.
/// Swiping down closes it, as does its close button.
struct FullscreenPlayerView: View {
    let playback: PlaybackController

    @Environment(\.dismiss) private var dismiss
    @State private var showsControls = true
    /// Hides the controls a moment after the last touch, while playing.
    @State private var hideTask: Task<Void, Never>?
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
            if showsControls && pull == 0 {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(.rect)
        .onTapGesture { setControlsShown(!showsControls) }
        .gesture(closingDrag)
        .statusBarHidden(!showsControls)
        .persistentSystemOverlays(showsControls ? .automatic : .hidden)
        .onAppear { scheduleHide() }
        .onChange(of: playback.isPlaying) { _, _ in scheduleHide() }
        .onDisappear { hideTask?.cancel() }
        .preferredColorScheme(.dark)
    }

    // MARK: - Controls

    private var controls: some View {
        VStack {
            HStack {
                Button("Fullscreen.Close", systemImage: "xmark") { dismiss() }
                    .labelStyle(.iconOnly)
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .glassEffect(.regular.interactive(), in: .circle)
                Spacer()
            }
            Spacer()
            transport
        }
        .padding()
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var transport: some View {
        HStack(spacing: 12) {
            Button(
                playback.isPlaying ? "Transport.Pause" : "Transport.Play",
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
            ) {
                playback.togglePlayPause()
                scheduleHide()
            }
            .labelStyle(.iconOnly)
            .font(.system(size: 20))
            .frame(width: 44, height: 44)
            .contentShape(.rect)
            .disabled(!playback.hasContent || playback.playbackError != nil)

            timecode(playback.currentTime)
            Slider(value: scrubPosition, in: 0...max(playback.duration.seconds, 0.001)) { isEditing in
                if isEditing {
                    hideTask?.cancel()
                    playback.beginScrubbing()
                } else {
                    playback.endScrubbing()
                    scheduleHide()
                }
            }
            .accessibilityLabel(Text("Fullscreen.Position"))
            timecode(playback.duration)
        }
        .padding(.leading, 6)
        .padding(.trailing, 16)
        .frame(maxWidth: 640)
        .glassEffect(.regular, in: .capsule)
    }

    private func timecode(_ time: CMTime) -> some View {
        Text(verbatim: playback.frames.timecode(time))
            .font(.system(size: 12, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
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

    private func setControlsShown(_ shown: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) { showsControls = shown }
        scheduleHide()
    }

    /// While playing, hides the controls a few seconds after they're shown
    /// or touched. Paused, they stay.
    private func scheduleHide() {
        hideTask?.cancel()
        guard showsControls, playback.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showsControls = false }
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
