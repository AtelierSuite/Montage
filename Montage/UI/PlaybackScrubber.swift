import CoreMedia
import MontageEngine
import SwiftUI

/// A slider along the project, between the playhead's timecode and the
/// project's length, for a picture shown full screen: dragging it scrubs.
struct PlaybackScrubber: View {
    let playback: PlaybackController

    var body: some View {
        HStack(spacing: 12) {
            timecode(playback.currentTime)
            Slider(value: position, in: 0...max(playback.duration.seconds, 0.001)) { isEditing in
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
    private var position: Binding<Double> {
        Binding {
            playback.currentTime.seconds
        } set: { seconds in
            playback.scrub(to: playback.frames.snapped(CMTime(seconds: seconds, preferredTimescale: 6000)))
        }
    }
}
