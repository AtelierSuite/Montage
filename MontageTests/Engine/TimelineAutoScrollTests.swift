@testable import MontageEngine
import Testing

struct TimelineAutoScrollTests {
    private let scroll = TimelineAutoScroll(edgeWidth: 40, maximumSpeed: 1000)
    /// The lanes from 100 to 500 in sight.
    private let visible = 100.0...500.0

    @Test func staysStillAwayFromTheEdges() {
        #expect(scroll.speed(atX: 300, visible: visible) == 0)
        #expect(scroll.speed(atX: 140, visible: visible) == 0)
        #expect(scroll.speed(atX: 460, visible: visible) == 0)
    }

    @Test func scrollsTowardsTheNearerEdgeFasterTheNearerItIs() {
        let start = scroll.speed(atX: 120, visible: visible)
        let nearerStart = scroll.speed(atX: 105, visible: visible)
        #expect(start < 0)
        #expect(nearerStart < start)
        let end = scroll.speed(atX: 480, visible: visible)
        #expect(end > 0)
        #expect(scroll.speed(atX: 495, visible: visible) > end)
        // Halfway into the edge is a quarter of the speed.
        #expect(end == 250)
    }

    @Test func goesNoFasterThanTheMaximumPastTheEdge() {
        #expect(scroll.speed(atX: 100, visible: visible) == -1000)
        #expect(scroll.speed(atX: -50, visible: visible) == -1000)
        #expect(scroll.speed(atX: 900, visible: visible) == 1000)
    }

    @Test func aNarrowViewKeepsItsMiddleStill() {
        // 100 wide: the edges are 25 each.
        let narrow = 0.0...100.0
        #expect(scroll.speed(atX: 30, visible: narrow) == 0)
        #expect(scroll.speed(atX: 70, visible: narrow) == 0)
        #expect(scroll.speed(atX: 10, visible: narrow) < 0)
        #expect(scroll.speed(atX: 0, visible: 0.0...0.0) == 0)
    }

    @Test func scrollsNoFurtherThanEitherEnd() {
        #expect(TimelineAutoScroll.offset(from: 100, speed: 600, elapsed: 0.5, maximumOffset: 1000) == 400)
        #expect(TimelineAutoScroll.offset(from: 100, speed: -600, elapsed: 0.5, maximumOffset: 1000) == 0)
        #expect(TimelineAutoScroll.offset(from: 900, speed: 600, elapsed: 0.5, maximumOffset: 1000) == 1000)
        // Content narrower than the view doesn't scroll at all.
        #expect(TimelineAutoScroll.offset(from: 0, speed: 600, elapsed: 0.5, maximumOffset: -20) == 0)
    }
}
