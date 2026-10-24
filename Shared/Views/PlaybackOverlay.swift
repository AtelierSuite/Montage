import MontageEngine
import SwiftUI

/// Playback controls laid over the picture, the way the system's video
/// player has them: over a light shade of black so they read on any
/// picture, in clear glass, play and pause in the middle, and anything else
/// in the corners or along the bottom. Moving through the project is the
/// timeline's, or the scrubber's, so there's nothing to skip with.
///
/// Tapping the picture shows and hides them at once. Starting playback hides
/// them straight away, out of the picture's way; pausing brings them back.
/// While playing, they go again a moment after they're brought up.
struct PlaybackOverlay<Corners: View, Bottom: View>: View {
    /// How big the controls are, for how big the picture is.
    enum Size {
        /// A small window floating over the editor.
        case compact
        /// The editor's preview.
        case regular
        /// The whole screen.
        case large

        var playButton: Double {
            switch self {
            case .compact: 44
            case .regular: 60
            case .large: 76
            }
        }
    }

    let playback: PlaybackController
    @Binding var isShown: Bool
    var size = Size.regular
    /// How far in from the overlay's edges the corners and the bottom sit,
    /// such as to keep them in the safe area while the overlay, and the play
    /// button in its middle, cover the whole picture.
    var contentInsets = EdgeInsets()
    /// Laid across the top: a row with whatever goes in the corners.
    @ViewBuilder var corners: Corners
    @ViewBuilder var bottom: Bottom
    /// Laid over the picture under the controls, such as handles to edit
    /// it with: see `canvas(_:onTapPicture:)`.
    var canvas: AnyView?
    /// Hears a tap on the picture away from the controls, and says whether
    /// it took it; one it didn't shows or hides the controls.
    var onTapPicture: ((CGPoint) -> Bool)?

    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            // Whatever isn't a control toggles the controls.
            Color.clear
                .contentShape(.rect)
                .onTapGesture { location in
                    if onTapPicture?(location) != true { setShown(!isShown) }
                }
            if isShown {
                Color.black.opacity(0.3)
                    .allowsHitTesting(false)
            }
            canvas
            if isShown {
                VStack(spacing: 0) {
                    corners
                    Spacer(minLength: 0)
                    bottom
                }
                .padding(size == .large ? 16 : 6)
                .padding(contentInsets)
                // Nothing to play, it would only cover why.
                if playback.playbackError == nil {
                    playButton
                }
            }
        }
        .onChange(of: playback.isPlaying) { _, isPlaying in
            setShown(!isPlaying)
        }
        .onDisappear { hideTask?.cancel() }
    }

    /// The overlay with a view laid over the picture under its controls,
    /// and what a tap on the picture does before it shows or hides them.
    func canvas(_ canvas: some View, onTapPicture: @escaping (CGPoint) -> Bool) -> Self {
        var overlay = self
        overlay.canvas = AnyView(canvas)
        overlay.onTapPicture = onTapPicture
        return overlay
    }

    private var playButton: some View {
        let diameter = size.playButton
        return Button(
            playback.isPlaying ? "Transport.Pause" : "Transport.Play",
            systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
        ) {
            playback.togglePlayPause()
            scheduleHide()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: diameter * 0.4))
        .foregroundStyle(.white)
        .frame(width: diameter, height: diameter)
        .contentShape(.circle)
        .glassEffect(.clear.interactive(), in: .circle)
        .buttonStyle(.plain)
        .disabled(!playback.hasContent)
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
    init(
        playback: PlaybackController, isShown: Binding<Bool>, size: Size = .regular,
        contentInsets: EdgeInsets = EdgeInsets(), @ViewBuilder corners: () -> Corners
    ) {
        self.init(
            playback: playback, isShown: isShown, size: size, contentInsets: contentInsets,
            corners: corners, bottom: { EmptyView() }
        )
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
