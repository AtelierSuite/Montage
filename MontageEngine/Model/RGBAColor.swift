import CoreGraphics

/// A colour as red, green, blue and alpha, each 0 to 1, in sRGB. Keyframed,
/// it blends channel by channel.
public struct RGBAColor: Equatable, Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    /// 1 is opaque.
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(white: Double, alpha: Double = 1) {
        self.init(red: white, green: white, blue: white, alpha: alpha)
    }

    public static let black = RGBAColor(white: 0)
    public static let white = RGBAColor(white: 1)
    public static let clear = RGBAColor(white: 0, alpha: 0)
}

extension RGBAColor: Interpolatable {
    public static func interpolate(from: RGBAColor, to: RGBAColor, fraction: Double) -> RGBAColor {
        RGBAColor(red: .interpolate(from: from.red, to: to.red, fraction: fraction),
                  green: .interpolate(from: from.green, to: to.green, fraction: fraction),
                  blue: .interpolate(from: from.blue, to: to.blue, fraction: fraction),
                  alpha: .interpolate(from: from.alpha, to: to.alpha, fraction: fraction))
    }
}

/// An amount for each of red, green and blue, such as a colour grade's lift,
/// gamma or gain. Keyframed, it blends channel by channel.
public struct RGBValues: Equatable, Hashable, Sendable, Codable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// The same amount for every channel.
    public init(_ all: Double) {
        self.init(red: all, green: all, blue: all)
    }
}

extension RGBValues: Interpolatable {
    public static func interpolate(from: RGBValues, to: RGBValues, fraction: Double) -> RGBValues {
        RGBValues(red: .interpolate(from: from.red, to: to.red, fraction: fraction),
                  green: .interpolate(from: from.green, to: to.green, fraction: fraction),
                  blue: .interpolate(from: from.blue, to: to.blue, fraction: fraction))
    }
}
