import Foundation

/// An easing curve from (0, 0) to (1, 1), shaped by two control points as
/// CSS's `cubic-bezier()` and Core Animation's timing functions are: x is
/// the fraction of the time between two keyframes, y the fraction of the way
/// between their values.
public struct TimingCurve: Equatable, Hashable, Sendable, Codable {
    /// The first control point. Its x is kept within 0 to 1, so the curve
    /// never runs back in time; its y may overshoot, to bounce.
    public var x1: Double
    public var y1: Double
    /// The second control point, kept within 0 to 1 the same way.
    public var x2: Double
    public var y2: Double

    public init(x1: Double, y1: Double, x2: Double, y2: Double) {
        self.x1 = min(max(x1, 0), 1)
        self.y1 = y1
        self.x2 = min(max(x2, 0), 1)
        self.y2 = y2
    }

    private enum CodingKeys: String, CodingKey {
        case x1, y1, x2, y2
    }

    // Read through the initializer, so a file can't make a curve that runs
    // back in time either.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x1: try container.decode(Double.self, forKey: .x1), y1: try container.decode(Double.self, forKey: .y1),
            x2: try container.decode(Double.self, forKey: .x2), y2: try container.decode(Double.self, forKey: .y2)
        )
    }

    /// How far along the values are, `t` of the way through the time.
    public func progress(at t: Double) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        return Self.bezier(parameter(forX: t), y1, y2)
    }

    /// The curve's parameter where its x is `x`. Newton's method converges
    /// in a few steps almost everywhere; where the slope is too flat for it,
    /// halving the interval always gets there.
    private func parameter(forX x: Double) -> Double {
        var s = x
        for _ in 0..<8 {
            let error = Self.bezier(s, x1, x2) - x
            if abs(error) < 1e-7 { return s }
            let slope = Self.slope(s, x1, x2)
            guard abs(slope) > 1e-6 else { break }
            s -= error / slope
        }
        var low = 0.0
        var high = 1.0
        s = x
        for _ in 0..<40 {
            let value = Self.bezier(s, x1, x2)
            if abs(value - x) < 1e-7 { break }
            if value < x { low = s } else { high = s }
            s = (low + high) / 2
        }
        return s
    }

    /// One coordinate of the curve at parameter `s`, the end points being 0
    /// and 1.
    private static func bezier(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - s
        return 3 * inverse * inverse * s * p1 + 3 * inverse * s * s * p2 + s * s * s
    }

    private static func slope(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
        let inverse = 1 - s
        return 3 * inverse * inverse * p1 + 6 * inverse * s * (p2 - p1) + 3 * s * s * (1 - p2)
    }
}
