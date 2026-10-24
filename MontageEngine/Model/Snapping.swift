import CoreMedia

/// The times on the timeline an edit can snap to: the start, the playhead,
/// markers, and the edges of clips. Made once when a drag begins, from the
/// project as it was, leaving out the clips being dragged.
public struct TimelineSnapper: Sendable {
    /// What a time snapped to.
    public enum Target: Equatable, Sendable {
        case start, playhead, marker, clipEdge
    }

    public struct Point: Equatable, Sendable {
        public var time: CMTime
        public var target: Target
    }

    /// A snap: the time it landed on, and how far the dragged time or range
    /// moves to get there.
    public struct Snap: Equatable, Sendable {
        public var point: Point
        public var adjustment: CMTime
    }

    /// In time order.
    public private(set) var points: [Point]

    public init(points: [Point]) {
        self.points = points.sorted { $0.time < $1.time }
    }

    /// The snap points of a project. A time that's more than one kind of
    /// point is the kind first in `Target`'s order.
    public init(project: Project, playhead: CMTime?, excluding clipIDs: Set<Clip.ID> = []) {
        var points = [Point(time: .zero, target: .start)]
        if let playhead { points.append(Point(time: playhead, target: .playhead)) }
        points += project.markers.map { Point(time: $0.time, target: .marker) }
        for clip in project.tracks.flatMap(\.clips) where !clipIDs.contains(clip.id) {
            points.append(Point(time: clip.timelineStart, target: .clipEdge))
            points.append(Point(time: clip.timelineRange.end, target: .clipEdge))
        }
        var seen = Set<CMTime>()
        self.init(points: points.filter { seen.insert($0.time).inserted })
    }

    /// The nearest point to a time, if it's within `tolerance` of it.
    public func snap(_ time: CMTime, tolerance: CMTime) -> Snap? {
        guard let point = nearest(to: time), abs(point.time - time) <= tolerance else { return nil }
        return Snap(point: point, adjustment: point.time - time)
    }

    /// The nearest snap for either end of a range being dragged, so the
    /// range's start or end lands on a point; ties go to the start.
    public func snap(_ range: CMTimeRange, tolerance: CMTime) -> Snap? {
        let start = snap(range.start, tolerance: tolerance)
        let end = snap(range.end, tolerance: tolerance)
        switch (start, end) {
        case let (start?, end?): return abs(end.adjustment) < abs(start.adjustment) ? end : start
        case let (start?, nil): return start
        case let (nil, end?): return end
        case (nil, nil): return nil
        }
    }

    private func nearest(to time: CMTime) -> Point? {
        // The first point at or after the time, and the one before it.
        var low = 0, high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].time < time { low = middle + 1 } else { high = middle }
        }
        let candidates = [low - 1, low].filter { points.indices.contains($0) }.map { points[$0] }
        return candidates.min { abs($0.time - time) < abs($1.time - time) }
    }
}

private func abs(_ time: CMTime) -> CMTime {
    time < .zero ? .zero - time : time
}
