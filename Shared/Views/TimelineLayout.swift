import CoreMedia
import MontageEngine
import SwiftUI

/// Where everything on the timeline is drawn, in the lanes' own space: x
/// from the timeline's start, y from the top of the ruler. The drawing, the
/// hit testing and the gestures all go through it, so they agree.
struct TimelineLayout {
    /// One of the timeline's rows: a track, or a placeholder for one in a
    /// project that has none yet.
    struct Row: Identifiable {
        var id: String
        var kind: Track.Kind
        var track: Track?
        /// The transitions that play on the track, in timeline order.
        var transitions: [PlacedTransition] = []
    }

    var pointsPerSecond: Double
    var rows: [Row]

    static let rulerHeight = 26.0
    static let trackHeight = 56.0
    /// The space above and below the clips in a lane.
    static let laneInset = 4.0

    /// The project's tracks, top video layer first, then the audio tracks.
    /// A project without tracks shows an empty video and audio lane.
    init(project: Project, pointsPerSecond: Double) {
        self.pointsPerSecond = pointsPerSecond
        let tracks = project.tracks
        if tracks.isEmpty {
            rows = [Row(id: "video", kind: .video), Row(id: "audio", kind: .audio)]
        } else {
            let video = tracks.filter { $0.kind == .video }.reversed()
            let audio = tracks.filter { $0.kind == .audio }
            rows = (video + audio).map {
                Row(id: $0.id.uuidString, kind: $0.kind, track: $0, transitions: project.placedTransitions(on: $0))
            }
        }
    }

    var height: Double { Self.rulerHeight + Double(rows.count) * Self.trackHeight }

    // MARK: - Time

    func x(_ time: CMTime) -> Double {
        time.seconds * pointsPerSecond
    }

    func seconds(atX x: Double) -> Double {
        x / pointsPerSecond
    }

    // MARK: - Rows

    /// The row under a height, which may be before the first (over the
    /// ruler) or after the last.
    func rowIndex(atY y: Double) -> Int {
        Int(((y - Self.rulerHeight) / Self.trackHeight).rounded(.down))
    }

    func rowIndex(of trackID: Track.ID) -> Int? {
        rows.firstIndex { $0.track?.id == trackID }
    }

    func rowTop(_ index: Int) -> Double {
        Self.rulerHeight + Double(index) * Self.trackHeight
    }

    /// Where a clip is drawn in a row.
    func rect(of clip: Clip, inRow index: Int) -> CGRect {
        CGRect(
            x: x(clip.timelineStart), y: rowTop(index) + Self.laneInset,
            width: max(2, clip.duration.seconds * pointsPerSecond), height: Self.trackHeight - Self.laneInset * 2
        )
    }

    /// Where a transition is drawn in a row: over the cut, across the time
    /// it plays, and at least wide enough to tap.
    func rect(of transition: PlacedTransition, inRow index: Int) -> CGRect {
        let range = transition.timelineRange
        let width = max(Self.minimumTransitionWidth, range.duration.seconds * pointsPerSecond)
        let centre = (x(range.start) + x(range.end)) / 2
        let inset = Self.laneInset + 12
        return CGRect(x: centre - width / 2, y: rowTop(index) + inset, width: width, height: Self.trackHeight - inset * 2)
    }

    static let minimumTransitionWidth = 14.0

    // MARK: - Hit testing

    /// The transition at a point, and the row it's in. Transitions are over
    /// the clips, so they're hit first.
    func transition(at point: CGPoint) -> (transition: PlacedTransition, row: Int)? {
        let index = rowIndex(atY: point.y)
        guard rows.indices.contains(index) else { return nil }
        return rows[index].transitions.first { rect(of: $0, inRow: index).contains(point) }.map { ($0, index) }
    }

    /// The clip at a point, and the row it's in.
    func clip(at point: CGPoint) -> (clip: Clip, row: Int)? {
        let index = rowIndex(atY: point.y)
        guard rows.indices.contains(index), let track = rows[index].track else { return nil }
        let seconds = seconds(atX: point.x)
        guard let clip = track.clips.first(where: {
            $0.timelineStart.seconds <= seconds && seconds < $0.timelineRange.end.seconds
        }) else { return nil }
        return (clip, index)
    }

    /// The clips under a rectangle, such as one dragged out to select them:
    /// those in the rows it crosses that share some time with it.
    func clips(under rect: CGRect) -> [(clip: Clip, row: Int)] {
        let first = max(rowIndex(atY: rect.minY), 0)
        let last = min(rowIndex(atY: rect.maxY), rows.count - 1)
        guard first <= last else { return [] }
        let range = CMTimeRange(
            start: CMTime(seconds: max(0, seconds(atX: rect.minX)), preferredTimescale: 6000),
            end: CMTime(seconds: max(0, seconds(atX: rect.maxX)), preferredTimescale: 6000)
        )
        return (first...last).flatMap { index in
            (rows[index].track?.clips(overlapping: range) ?? []).map { ($0, index) }
        }
    }

    /// Every clip with its row, for drawing the ones in sight.
    func clips(in visible: ClosedRange<Double>) -> [(clip: Clip, row: Int)] {
        rows.enumerated().flatMap { index, row in
            (row.track?.clips ?? []).filter {
                x($0.timelineRange.end) >= visible.lowerBound && x($0.timelineStart) <= visible.upperBound
            }.map { ($0, index) }
        }
    }
}

extension FrameTime {
    /// A length of time in seconds, either way, rounded to the nearest whole
    /// frame.
    func rounded(seconds: Double) -> CMTime {
        guard seconds.isFinite else { return .zero }
        let frames = (seconds / frameDuration.seconds).rounded()
        return CMTime(value: Int64(frames) * frameDuration.value, timescale: frameDuration.timescale)
    }
}
