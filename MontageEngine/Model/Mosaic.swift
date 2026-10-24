import Foundation

/// Hides part of the picture, such as a face or a number plate; usually
/// limited to it by a mask.
public struct Mosaic: Equatable, Sendable {
    public enum Style: String, Equatable, Sendable, Codable, CaseIterable {
        /// Squares of one colour each.
        case pixelate
        case blur
        /// A pattern of squares in two colours over the picture.
        case checkerboard
    }

    public var style: Style = .pixelate
    /// How coarse the mosaic is, as a fraction of the frame's width: the
    /// size of each square, or how far the blur spreads.
    public var scale = Animatable(0.03)
    /// How much of the mosaic shows over the picture: 1 is all of it, 0 none.
    public var strength = Animatable(1.0)
    /// The checkerboard's two colours.
    public var firstColor = Animatable(RGBAColor.black)
    public var secondColor = Animatable(RGBAColor.white)

    public init(style: Style = .pixelate) {
        self.style = style
    }
}

extension Mosaic: Codable {
    private enum CodingKeys: String, CodingKey {
        case style, scale, strength, firstColor, secondColor
    }

    // Only the style is needed to read; the rest fall back to a new
    // mosaic's, so one saved before they existed still opens.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(style: try container.decodeIfPresent(Style.self, forKey: .style) ?? .pixelate)
        scale = try container.decodeIfPresent(Animatable<Double>.self, forKey: .scale) ?? scale
        strength = try container.decodeIfPresent(Animatable<Double>.self, forKey: .strength) ?? strength
        firstColor = try container.decodeIfPresent(Animatable<RGBAColor>.self, forKey: .firstColor) ?? firstColor
        secondColor = try container.decodeIfPresent(Animatable<RGBAColor>.self, forKey: .secondColor) ?? secondColor
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(style, forKey: .style)
        try container.encode(scale, forKey: .scale)
        try container.encode(strength, forKey: .strength)
        try container.encode(firstColor, forKey: .firstColor)
        try container.encode(secondColor, forKey: .secondColor)
    }
}
