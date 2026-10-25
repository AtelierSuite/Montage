import Foundation

/// How fast the timeline scrolls by itself while something is dragged near
/// either end of the part in sight, so a clip, an edge or a selection can be
/// taken past it. The nearer the edge, and past it, the faster.
public struct TimelineAutoScroll: Equatable, Sendable {
    /// How far in from each end, in points, scrolling starts.
    public var edgeWidth: Double
    /// The fastest it goes, in points a second, at the very edge and past it.
    public var maximumSpeed: Double

    public init(edgeWidth: Double = 40, maximumSpeed: Double = 1200) {
        self.edgeWidth = edgeWidth
        self.maximumSpeed = maximumSpeed
    }

    /// The speed, in points a second, to scroll at with the pointer at `x`
    /// along the lanes while `visible` is in sight: below zero towards the
    /// start, above towards the end, and zero away from the edges. In a
    /// narrow view the edges take no more than a quarter of it each.
    public func speed(atX x: Double, visible: ClosedRange<Double>) -> Double {
        let width = visible.upperBound - visible.lowerBound
        let edge = min(edgeWidth, width / 4)
        guard edge > 0, x.isFinite else { return 0 }
        if x < visible.lowerBound + edge {
            return -maximumSpeed * depth(visible.lowerBound + edge - x, edge: edge)
        }
        if x > visible.upperBound - edge {
            return maximumSpeed * depth(x - (visible.upperBound - edge), edge: edge)
        }
        return 0
    }

    /// How far into the edge, from 0 where it begins to 1 at the end and
    /// beyond, eased in so it starts slowly.
    private func depth(_ distance: Double, edge: Double) -> Double {
        let fraction = min(max(distance / edge, 0), 1)
        return fraction * fraction
    }

    /// Where to scroll to after `elapsed` seconds at `speed`, from `offset`,
    /// kept between the start and `maximumOffset`.
    public static func offset(
        from offset: Double, speed: Double, elapsed: Double, maximumOffset: Double
    ) -> Double {
        min(max(offset + speed * elapsed, 0), max(maximumOffset, 0))
    }
}
