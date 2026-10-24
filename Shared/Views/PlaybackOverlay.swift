import MontageEngine
import SwiftUI

/// Playback controls laid over the picture, the way the system's video
/// player has them: over a light shade of black so they read on any
/// picture, in clear glass, playback in the middle and anything else in the
/// corners or along the bottom.
///
/// Tapping the picture shows and hides them at once. Starting playback hides
/// them straight away, out of the picture's way; pausing brings them back.
/// While playing, they go again a moment after they're brought up.
struct PlaybackOverlay<Corners: View, Bottom: View>: View {
    let playback: PlaybackController
    @Binding var isShown: Bool
    /// Bigger controls, for a picture that fills the screen.
    var isLarge = false
    /// Laid across the top: a row with whatever goes in the corners.
    @ViewBuilder var corners: Corners
    @ViewBuilder var bottom: Bottom

    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Whatever isn't a control toggles the controls.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { setShown(!isShown) }
            if isShown {
                Color.black.opacity(0.3)
                    .allowsHitTesting(false)
                VStack(spacing: 0) {
                    corners
                    Spacer(minLength: 0)
                    bottom
                }
                .padding(isLarge ? 16 : 6)
                transport
            }
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            setShown(!isPlaying)
        }
        .onDisappear { hideTask?.cancel() }
    }

    private var transport: some View {
        HStack(spacing: isLarge ? 28 : 12) {
            button("Transport.GoToStart", systemImage: "backward.end.fill", size: isLarge ? 52 : 34) {
                playback.goToStart()
            }
            button(
                playback.isPlaying ? "Transport.Pause" : "Transport.Play",
                systemImage: playback.isPlaying ? "pause.fill" : "play.fill", size: isLarge ? 72 : 46
            ) {
                playback.togglePlayPause()
            }
            button("Transport.GoToEnd", systemImage: "forward.end.fill", size: isLarge ? 52 : 34) {
                playback.goToEnd()
            }
        }
        .disabled(!playback.hasContent || playback.playbackError != nil)
    }

    private func button(
        _ title: LocalizedStringKey, systemImage: String, size: Double, action: @escaping () -> Void
    ) -> some View {
        Button(title, systemImage: systemImage) {
            action()
            scheduleHide()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: size * 0.4))
        .foregroundStyle(.white)
        .frame(width: size, height: size)
        .contentShape(.circle)
        .glassEffect(.clear.interactive(), in: .circle)
        .buttonStyle(.plain)
    }

    /// Shows or hides the controls at once, without fading.
    private func setShown(_ shown: Bool) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { isShown = shown }
        scheduleHide()
    }

    /// While playing, hides the controls a few seconds after they're shown or
    /// touched. Paused, they stay.
    private func scheduleHide() {
        hideTask?.cancel()
        guard isShown, playback.isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            setShown(false)
        }
    }
}

extension PlaybackOverlay where Bottom == EmptyView {
    init(playback: PlaybackController, isShown: Binding<Bool>, isLarge: Bool = false, @ViewBuilder corners: () -> Corners) {
        self.init(playback: playback, isShown: isShown, isLarge: isLarge, corners: corners, bottom: { EmptyView() })
    }
}

/// A button for a corner of the picture, in the overlay's clear glass.
struct PlaybackOverlayButton: View {
    let title: LocalizedStringKey
    let systemImage: String
    var isLarge = false
    let action: () -> Void

    init(_ title: LocalizedStringKey, systemImage: String, isLarge: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.isLarge = isLarge
        self.action = action
    }

    var body: some View {
        let size = isLarge ? 44.0 : 30.0
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .contentShape(.circle)
            .glassEffect(.clear.interactive(), in: .circle)
            .buttonStyle(.plain)
    }
}
