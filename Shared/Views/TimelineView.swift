import SwiftUI

/// The timeline: a ruler over the project's tracks, each named in a header
/// down the leading edge, with the playhead across them all. The corner
/// above the headers shows where the playhead is.
struct TimelineView: View {
    private let headerWidth = 88.0
    private let rulerHeight = 24.0
    private let trackHeight = 52.0
    /// How far apart, in points, the ruler marks each second.
    private let pointsPerSecond = 60.0

    private let tracks: [(title: LocalizedStringKey, systemImage: String)] = [
        ("Timeline.Track.Video", "film"),
        ("Timeline.Track.Audio", "waveform"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text(verbatim: "00:00:00:00")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.leading, 8)
                    .frame(width: headerWidth, alignment: .leading)
                ruler
            }
            .frame(height: rulerHeight)
            Divider()
            ForEach(tracks.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    Label(tracks[index].title, systemImage: tracks[index].systemImage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                        .frame(width: headerWidth, alignment: .leading)
                    lane(isFirst: index == 0)
                }
                .frame(height: trackHeight)
                Divider()
            }
            Spacer(minLength: 0)
        }
        .background(.background.secondary)
        .overlay(alignment: .topLeading) { playhead }
    }

    private var ruler: some View {
        Canvas { context, size in
            var ticks = Path()
            var second = 0
            var x = 0.0
            while x <= size.width {
                ticks.move(to: CGPoint(x: x, y: size.height))
                ticks.addLine(to: CGPoint(x: x, y: size.height * 0.45))
                let half = x + pointsPerSecond / 2
                ticks.move(to: CGPoint(x: half, y: size.height))
                ticks.addLine(to: CGPoint(x: half, y: size.height * 0.75))
                let label = Text(verbatim: String(format: "%d:%02d", second / 60, second % 60))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                context.draw(label, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                second += 1
                x += pointsPerSecond
            }
            context.stroke(ticks, with: .style(.secondary), lineWidth: 0.5)
        }
    }

    /// A track's lane. Empty for now; the first one says how to fill it.
    private func lane(isFirst: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            .foregroundStyle(.tertiary)
            .overlay {
                if isFirst {
                    Text("Timeline.Empty")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 6)
            .padding(.trailing, 6)
    }

    private var playhead: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .offset(x: headerWidth)
            .allowsHitTesting(false)
    }
}
