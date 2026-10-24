import CoreMedia
import MontageEngine
import SwiftUI

/// The timeline: a ruler over the project's tracks, each named in a header
/// down the leading edge, with the playhead across them all. The corner
/// above the headers shows where the playhead is, and dragging along the
/// ruler moves it.
///
/// Shows the clips where they are; editing them here comes later (#11).
struct TimelineView: View {
    @Environment(ProjectEditor.self) private var editor

    private let headerWidth = 88.0
    private let rulerHeight = 24.0
    private let trackHeight = 52.0
    /// How far apart, in points, the ruler marks each second.
    private let pointsPerSecond = 60.0
    /// Room after the last clip, to see that it's the end.
    private let trailingRoom = 120.0

    /// The size of the visible part of the lanes.
    @State private var viewport = CGSize.zero
    @State private var scrollPosition = ScrollPosition(edge: .leading)
    /// How far the lanes are scrolled along.
    @State private var scrollOffset = 0.0

    var body: some View {
        let rows = self.rows
        ScrollView(.vertical) {
            HStack(alignment: .top, spacing: 0) {
                VStack(spacing: 0) {
                    TimecodeLabel()
                        .padding(.leading, 8)
                        .frame(width: headerWidth, height: rulerHeight, alignment: .leading)
                    Divider()
                    ForEach(rows) { row in
                        header(row)
                            .frame(width: headerWidth, height: trackHeight, alignment: .leading)
                        Divider()
                    }
                }
                // Held to its width: the dividers would otherwise take half
                // the timeline's.
                .frame(width: headerWidth)
                ScrollView(.horizontal) {
                    lanes(rows)
                        .frame(width: max(viewport.width, contentWidth), alignment: .topLeading)
                        .frame(minHeight: viewport.height, alignment: .top)
                        .overlay(alignment: .topLeading) {
                            Playhead(pointsPerSecond: pointsPerSecond)
                        }
                }
                .scrollPosition($scrollPosition)
                .onScrollGeometryChange(for: Double.self) { $0.contentOffset.x } action: { scrollOffset = $1 }
                .background {
                    PlayheadFollower(
                        pointsPerSecond: pointsPerSecond, visibleRange: scrollOffset...(scrollOffset + viewport.width),
                        scrollPosition: $scrollPosition
                    )
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            viewport = CGSize(width: max(0, size.width - headerWidth), height: size.height)
        }
        .background(.background.secondary)
    }

    /// As wide as the project runs, with room to spare.
    private var contentWidth: Double {
        editor.project.duration.seconds * pointsPerSecond + trailingRoom
    }

    // MARK: - Rows

    /// One of the timeline's rows: a track, or a placeholder for one in a
    /// project that has none yet.
    private struct Row: Identifiable {
        var id: String
        var kind: Track.Kind
        var track: Track?
    }

    /// The project's tracks, top video layer first, then the audio tracks.
    /// A project without tracks shows an empty video and audio lane.
    private var rows: [Row] {
        let tracks = editor.project.tracks
        guard !tracks.isEmpty else {
            return [Row(id: "video", kind: .video), Row(id: "audio", kind: .audio)]
        }
        let video = tracks.filter { $0.kind == .video }.reversed()
        let audio = tracks.filter { $0.kind == .audio }
        return (video + audio).map { Row(id: $0.id.uuidString, kind: $0.kind, track: $0) }
    }

    private func header(_ row: Row) -> some View {
        Group {
            switch row.kind {
            case .video: Label("Timeline.Track.Video", systemImage: "film")
            case .audio: Label("Timeline.Track.Audio", systemImage: "waveform")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.leading, 12)
    }

    private func lanes(_ rows: [Row]) -> some View {
        VStack(spacing: 0) {
            ruler
                .frame(height: rulerHeight)
                .contentShape(.rect)
                .gesture(scrubbing)
            Divider()
            ForEach(rows) { row in
                lane(row, isFirst: row.id == rows.first?.id)
                    .frame(height: trackHeight)
                Divider()
            }
        }
    }

    /// A track's lane: its clips where they sit on the timeline, or a dashed
    /// outline while it has none, the first saying how to fill it.
    @ViewBuilder
    private func lane(_ row: Row, isFirst: Bool) -> some View {
        if let track = row.track, !track.clips.isEmpty {
            ZStack(alignment: .leading) {
                Color.clear
                ForEach(track.clips) { clip in
                    block(for: clip, kind: track.kind)
                }
            }
            .padding(.vertical, 6)
            // A hidden or muted track's clips are left out of playback.
            .opacity(track.kind == .video && track.isHidden || track.kind == .audio && track.isMuted ? 0.4 : 1)
        } else {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(.tertiary)
                .overlay {
                    if isFirst && editor.project.tracks.allSatisfy(\.clips.isEmpty) {
                        Text("Timeline.Empty")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                .padding(.trailing, 6)
                .frame(maxWidth: max(viewport.width, 0), alignment: .leading)
        }
    }

    private func block(for clip: Clip, kind: Track.Kind) -> some View {
        let color: Color = kind == .video ? .blue : .green
        return RoundedRectangle(cornerRadius: 5)
            .fill(color.opacity(0.7))
            .strokeBorder(color, lineWidth: 1)
            .overlay(alignment: .leading) {
                Text(verbatim: editor.project.mediaItem(id: clip.mediaID)?.name ?? "")
                    .font(.caption2)
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
            }
            .clipped()
            .overlay {
                if editor.selectedClipID == clip.id {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.primary, lineWidth: 2)
                }
            }
            .frame(width: max(2, clip.duration.seconds * pointsPerSecond))
            // Picked for the inspector.
            .onTapGesture { editor.selectedClipID = clip.id }
            .offset(x: clip.timelineStart.seconds * pointsPerSecond)
    }

    // MARK: - Ruler

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

    /// Tapping or dragging along the ruler moves the playhead there, onto
    /// the start of the frame under the finger.
    private var scrubbing: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let playback = editor.playback
                let time = CMTime(seconds: max(0, value.location.x / pointsPerSecond), preferredTimescale: 6000)
                playback.scrub(to: playback.frames.snapped(time))
            }
            .onEnded { _ in
                editor.playback.endScrubbing()
            }
    }
}

/// Where the playhead is, as timecode. A view of its own, since it changes
/// every frame while playing and nothing else around it needs to.
private struct TimecodeLabel: View {
    @Environment(ProjectEditor.self) private var editor

    var body: some View {
        let playback = editor.playback
        Text(verbatim: playback.frames.timecode(playback.currentTime))
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(.secondary)
    }
}

/// The line across the tracks at the playhead.
private struct Playhead: View {
    @Environment(ProjectEditor.self) private var editor
    let pointsPerSecond: Double

    var body: some View {
        Rectangle()
            .fill(Color.accentColor)
            .frame(width: 1.5)
            .frame(maxHeight: .infinity)
            .offset(x: editor.playback.currentTime.seconds * pointsPerSecond)
            .allowsHitTesting(false)
    }
}

/// Scrolls the lanes along to keep the playhead in sight while playing.
/// Nothing to see; it only watches the time.
private struct PlayheadFollower: View {
    @Environment(ProjectEditor.self) private var editor
    let pointsPerSecond: Double
    let visibleRange: ClosedRange<Double>
    @Binding var scrollPosition: ScrollPosition

    var body: some View {
        Color.clear
            .onChange(of: editor.playback.currentTime) { _, time in
                guard editor.playback.isPlaying, visibleRange.upperBound > visibleRange.lowerBound else { return }
                let x = time.seconds * pointsPerSecond
                // A page on when it reaches the edge, rather than following
                // every frame, which would make the clips hard to watch.
                if x > visibleRange.upperBound - 8 || x < visibleRange.lowerBound {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scrollPosition.scrollTo(x: max(0, x - 24))
                    }
                }
            }
    }
}
