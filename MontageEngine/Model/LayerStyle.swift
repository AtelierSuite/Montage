import CoreGraphics
import CoreMedia

/// How the inside of text or a shape is painted.
public struct LayerFill: Equatable, Sendable, Codable {
    public enum Style: String, Codable, Sendable, CaseIterable {
        case none, solid, linearGradient, radialGradient
    }

    public var style: Style
    /// The solid colour, or where a gradient starts: its first end for a
    /// linear one, its middle for a radial one.
    public var color: Animatable<RGBAColor>
    /// Where a gradient ends.
    public var endColor: Animatable<RGBAColor>
    /// Which way a linear gradient runs, in degrees clockwise from pointing
    /// right: 90 runs from top to bottom.
    public var angle: Animatable<Double>

    public init(
        style: Style = .solid, color: RGBAColor = .white, endColor: RGBAColor = RGBAColor(white: 0.6),
        angle: Double = 90
    ) {
        self.style = style
        self.color = Animatable(color)
        self.endColor = Animatable(endColor)
        self.angle = Animatable(angle)
    }

    public var isGradient: Bool { style == .linearGradient || style == .radialGradient }

    func shifted(by offset: CMTime) -> LayerFill {
        var fill = self
        fill.color = color.shifted(by: offset)
        fill.endColor = endColor.shifted(by: offset)
        fill.angle = angle.shifted(by: offset)
        return fill
    }

    /// The fill's values at a time.
    public struct Resolved: Hashable, Sendable {
        public var style: Style
        public var color: RGBAColor
        public var endColor: RGBAColor
        public var angle: Double
    }

    public func resolved(at time: CMTime) -> Resolved {
        Resolved(style: style, color: color.value(at: time), endColor: endColor.value(at: time), angle: angle.value(at: time))
    }
}

/// A line drawn along the edge of a shape, or round text as its outline.
public struct LayerStroke: Equatable, Sendable, Codable {
    public enum Dash: String, Codable, Sendable, CaseIterable {
        case solid, dashed, dotted
    }

    public enum Cap: String, Codable, Sendable, CaseIterable {
        case butt, round, square
    }

    public enum Join: String, Codable, Sendable, CaseIterable {
        case miter, round, bevel
    }

    public var isEnabled: Bool
    public var color: Animatable<RGBAColor>
    /// In the project's frame's pixels.
    public var width: Animatable<Double>
    public var dash: Dash
    public var cap: Cap
    public var join: Join

    public init(
        isEnabled: Bool = false, color: RGBAColor = .black, width: Double = 4, dash: Dash = .solid,
        cap: Cap = .round, join: Join = .round
    ) {
        self.isEnabled = isEnabled
        self.color = Animatable(color)
        self.width = Animatable(width)
        self.dash = dash
        self.cap = cap
        self.join = join
    }

    func shifted(by offset: CMTime) -> LayerStroke {
        var stroke = self
        stroke.color = color.shifted(by: offset)
        stroke.width = width.shifted(by: offset)
        return stroke
    }

    /// The stroke's values at a time; nil when it's off or has no width.
    public struct Resolved: Hashable, Sendable {
        public var color: RGBAColor
        public var width: Double
        public var dash: Dash
        public var cap: Cap
        public var join: Join
    }

    public func resolved(at time: CMTime) -> Resolved? {
        let width = max(0, width.value(at: time))
        guard isEnabled, width > 0 else { return nil }
        return Resolved(color: color.value(at: time), width: width, dash: dash, cap: cap, join: join)
    }
}

/// A shadow cast by text or a shape onto what's under it.
public struct LayerShadow: Equatable, Sendable, Codable {
    public var isEnabled: Bool
    public var color: Animatable<RGBAColor>
    /// How soft its edge is, in the project's frame's pixels.
    public var blur: Animatable<Double>
    /// How far it falls from what casts it, in the frame's pixels, with y
    /// running down.
    public var offset: Animatable<CGSize>

    public init(
        isEnabled: Bool = false, color: RGBAColor = RGBAColor(white: 0, alpha: 0.6), blur: Double = 12,
        offset: CGSize = CGSize(width: 0, height: 6)
    ) {
        self.isEnabled = isEnabled
        self.color = Animatable(color)
        self.blur = Animatable(blur)
        self.offset = Animatable(offset)
    }

    func shifted(by offset: CMTime) -> LayerShadow {
        var shadow = self
        shadow.color = color.shifted(by: offset)
        shadow.blur = blur.shifted(by: offset)
        shadow.offset = self.offset.shifted(by: offset)
        return shadow
    }

    /// The shadow's values at a time; nil when it's off.
    public struct Resolved: Hashable, Sendable {
        public var color: RGBAColor
        public var blur: Double
        public var offsetX: Double
        public var offsetY: Double

        /// How far past what casts it the shadow can reach.
        var reach: Double { blur * 2 + max(abs(offsetX), abs(offsetY)) }
    }

    public func resolved(at time: CMTime) -> Resolved? {
        guard isEnabled else { return nil }
        let offset = offset.value(at: time)
        return Resolved(
            color: color.value(at: time), blur: max(0, blur.value(at: time)),
            offsetX: offset.width, offsetY: offset.height
        )
    }
}
