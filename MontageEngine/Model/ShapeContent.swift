import CoreGraphics
import CoreMedia

/// A shape clip: what shape it is and how it's painted. Sizes are in the
/// project's frame's pixels, and the numbers and colours can be keyframed.
public struct ShapeContent: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case rectangle, roundedRectangle, ellipse, line, arrow, polygon, star
    }

    public var kind: Kind
    /// The box the shape is drawn in. A line runs across it, and an arrow
    /// points along it to the right.
    public var size: Animatable<CGSize>
    /// For a rounded rectangle.
    public var cornerRadius: Animatable<Double>
    /// How many sides a polygon has, or points a star.
    public var sides: Int
    /// How far in a star's inner corners are, as a fraction of its points'.
    public var innerRadius: Animatable<Double>
    public var fill: LayerFill
    public var stroke: LayerStroke
    public var shadow: LayerShadow

    public init(
        _ kind: Kind = .rectangle, size: CGSize = CGSize(width: 600, height: 400), cornerRadius: Double = 48,
        sides: Int = 5, innerRadius: Double = 0.45, fill: LayerFill = LayerFill(color: RGBAColor(red: 0.2, green: 0.5, blue: 1)),
        stroke: LayerStroke = LayerStroke(width: 8, join: .miter), shadow: LayerShadow = LayerShadow()
    ) {
        self.kind = kind
        self.size = Animatable(size)
        self.cornerRadius = Animatable(cornerRadius)
        self.sides = sides
        self.innerRadius = Animatable(innerRadius)
        self.fill = fill
        self.stroke = stroke
        self.shadow = shadow
    }

    /// A shape of a kind as it's first added: a line is only stroked, and
    /// polygons and stars are as wide as they're tall.
    public static func defaults(for kind: Kind) -> ShapeContent {
        switch kind {
        case .line:
            ShapeContent(kind, size: CGSize(width: 600, height: 0), fill: LayerFill(style: .none),
                         stroke: LayerStroke(isEnabled: true, color: .white, width: 12))
        case .arrow:
            ShapeContent(kind, size: CGSize(width: 600, height: 200))
        case .ellipse, .polygon, .star:
            ShapeContent(kind, size: CGSize(width: 400, height: 400), sides: kind == .polygon ? 6 : 5)
        case .rectangle, .roundedRectangle:
            ShapeContent(kind)
        }
    }

    /// Makes the shape another kind. A line is only stroked and has no
    /// height, so to or from a line the size's height, the fill and the
    /// stroke start again from the new kind's, keeping the width.
    public mutating func changeKind(to newKind: Kind) {
        guard newKind != kind else { return }
        if kind == .line || newKind == .line {
            let defaults = ShapeContent.defaults(for: newKind)
            let width = size.value(at: .zero).width
            size = Animatable(CGSize(width: width, height: defaults.size.value.height))
            fill = defaults.fill
            stroke = defaults.stroke
        }
        kind = newKind
    }

    func shifted(by offset: CMTime) -> ShapeContent {
        var shape = self
        shape.size = size.shifted(by: offset)
        shape.cornerRadius = cornerRadius.shifted(by: offset)
        shape.innerRadius = innerRadius.shifted(by: offset)
        shape.fill = fill.shifted(by: offset)
        shape.stroke = stroke.shifted(by: offset)
        shape.shadow = shadow.shifted(by: offset)
        return shape
    }

    /// Everything needed to draw the shape at a time, which drawn pictures
    /// are cached by.
    public struct Resolved: Hashable, Sendable {
        public var kind: Kind
        public var width: Double
        public var height: Double
        public var cornerRadius: Double
        public var sides: Int
        public var innerRadius: Double
        public var fill: LayerFill.Resolved
        public var stroke: LayerStroke.Resolved?
        public var shadow: LayerShadow.Resolved?
    }

    public func resolved(at time: CMTime) -> Resolved {
        let size = size.value(at: time)
        return Resolved(
            kind: kind, width: max(0, size.width), height: max(0, size.height),
            cornerRadius: max(0, cornerRadius.value(at: time)), sides: max(3, sides),
            innerRadius: min(max(innerRadius.value(at: time), 0.05), 1), fill: fill.resolved(at: time),
            stroke: stroke.resolved(at: time), shadow: shadow.resolved(at: time)
        )
    }
}
