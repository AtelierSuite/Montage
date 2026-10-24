import CoreMedia
import Foundation
@testable import MontageEngine
import Testing

/// Seconds, as the times the tests build their timelines from.
private func s(_ seconds: Int64) -> CMTime {
    CMTime(value: seconds, timescale: 1)
}

private func range(_ start: Int64, _ duration: Int64) -> CMTimeRange {
    CMTimeRange(start: s(start), duration: s(duration))
}

struct SnappingTests {
    private let tolerance = CMTime(value: 1, timescale: 2)

    @Test func snapsToTheNearestPointWithinTolerance() {
        var fixture = TimelineFixture([(2, 0, 3)])
        fixture.project.addMarker(at: s(8))
        let snapper = TimelineSnapper(project: fixture.project, playhead: s(10))
        #expect(snapper.points.map(\.target) == [.start, .clipEdge, .clipEdge, .marker, .playhead])
        #expect(snapper.snap(CMTime(value: 41, timescale: 10), tolerance: tolerance) == nil)
        let snap = snapper.snap(CMTime(value: 52, timescale: 10), tolerance: tolerance)
        #expect(snap?.point.time == s(5))
        #expect(snap?.adjustment == CMTime(value: -2, timescale: 10))
        #expect(snapper.snap(CMTime(value: 79, timescale: 10), tolerance: tolerance)?.point.target == .marker)
    }

    @Test func leavesOutTheClipsBeingDragged() {
        let fixture = TimelineFixture([(2, 0, 3)])
        let snapper = TimelineSnapper(project: fixture.project, playhead: nil, excluding: [fixture.id(0)])
        #expect(snapper.points.map(\.time) == [.zero])
    }

    @Test func snapsARangeByWhicheverEndIsNearer() {
        let fixture = TimelineFixture([(0, 0, 4), (10, 0, 2)])
        let snapper = TimelineSnapper(project: fixture.project, playhead: nil)
        // Starting just after the first clip ends, and ending nearer the
        // second's start than that.
        let range = CMTimeRange(start: CMTime(value: 43, timescale: 10), end: CMTime(value: 99, timescale: 10))
        let snap = snapper.snap(range, tolerance: tolerance)
        #expect(snap?.point.time == s(10))
        #expect(snap?.adjustment == CMTime(value: 1, timescale: 10))
    }

    @Test func aPointThatsTwoThingsIsTheFirst() {
        var fixture = TimelineFixture([(0, 0, 4)])
        fixture.project.addMarker(at: s(4))
        let snapper = TimelineSnapper(project: fixture.project, playhead: s(4))
        #expect(snapper.points.map(\.target) == [.start, .playhead])
    }
}
