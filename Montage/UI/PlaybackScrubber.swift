import CoreMedia
import MontageEngine
import SwiftUI

/// A bar along the project for a picture shown full screen, with where the
/// playhead is and how long is left on a line under it, at either end.
/// The bar is a plain track filled as far as the playhead, with no knob,
/// thickening while it's dragged; dragging it scrubs, nudging the playhead
/// from where it was rather than jumping it to the finger.
struct PlaybackScrubber: View {
    let playback: PlaybackController

    @State private var isDragging = false
    /// Where the playhead was when the drag began, in seconds.
    @State private var dragStart = 0.0

    var body: some View {
        VStack(spacing: 8) {
            track
            HStack {
                timecode(playback.frames.timecode(playback.currentTime))
                Spacer()
                timecode("-" + playback.frames.timecode(max(.zero, playback.duration - playback.currentTime)))
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: 640)
        .glassEffect(.clear, in: .rect(cornerRadius: 22))
    }

    private var track: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let duration = playback.duration.seconds
            let progress = duration > 0 ? min(max(playback.currentTime.seconds / duration, 0), 1) : 0
            let height = isDragging ? 8.0 : 6.0
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(height: height)
                Capsule()
                    .fill(.white)
                    .frame(width: max(progress * width, 0), height: height)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0, width > 0 else { return }
                        if !isDragging {
                            isDragging = true
                            dragStart = playback.currentTime.seconds
                            playback.beginScrubbing()
                        }
                        let seconds = min(max(dragStart + value.translation.width / width * duration, 0), duration)
                        playback.scrub(to: playback.frames.snapped(CMTime(seconds: seconds, preferredTimescale: 6000)))
                    }
                    .onEnded { _ in
                        isDragging = false
                        playback.endScrubbing()
                    }
            )
        }
        .frame(height: 16)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
        .accessibilityElement()
        .accessibilityLabel(Text("Fullscreen.Position"))
        .accessibilityValue(Text(verbatim: playback.frames.timecode(playback.currentTime)))
        .accessibilityAdjustableAction { direction in
            let step = CMTime(value: 5, timescale: 1)
            switch direction {
            case .increment: playback.seek(to: min(playback.duration, playback.currentTime + step))
            case .decrement: playback.seek(to: max(.zero, playback.currentTime - step))
            @unknown default: break
            }
        }
    }

    private func timecode(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.caption.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
    }
}
