import Foundation

/// Exposure, contrast and colour. Neutral values leave the picture as it is.
///
/// The adjustments go in the order they're listed: exposure, then brightness,
/// contrast and saturation, then white balance, then lift, gamma and gain,
/// and the look-up table last.
public struct ColorCorrection: Equatable, Sendable {
    /// In stops: -1 halves the light, 1 doubles it.
    public var exposure = Animatable(0.0)
    /// Added to every channel; 0 is unchanged.
    public var brightness = Animatable(0.0)
    /// 1 is unchanged.
    public var contrast = Animatable(1.0)
    /// 1 is unchanged, 0 is greyscale.
    public var saturation = Animatable(1.0)
    /// White balance, in kelvin; 6500 is unchanged, higher is warmer.
    public var temperature = Animatable(6500.0)
    /// Green to magenta; 0 is unchanged, higher is more magenta.
    public var tint = Animatable(0.0)
    /// Raises each channel's shadows, leaving its highlights: 0 is unchanged,
    /// 1 lifts black to white.
    public var lift = Animatable(RGBValues(0))
    /// Bends each channel's midtones, leaving black and white: 1 is
    /// unchanged, above 1 brightens.
    public var gamma = Animatable(RGBValues(1))
    /// Scales each channel, leaving black: 1 is unchanged.
    public var gain = Animatable(RGBValues(1))
    /// A look applied last, if there is one.
    public var lut: ColorLUT?
    /// How much of the look shows: 1 is all of it, 0 none.
    public var lutIntensity = Animatable(1.0)

    public init() {}
}

// Each adjustment is optional to read, so a correction saved before one
// existed still opens, with that one left neutral.
extension ColorCorrection: Codable {
    private enum CodingKeys: String, CodingKey {
        case exposure, brightness, contrast, saturation, temperature, tint, lift, gamma, gain, lut, lutIntensity
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let neutral = ColorCorrection()
        exposure = try container.decodeIfPresent(Animatable<Double>.self, forKey: .exposure) ?? neutral.exposure
        brightness = try container.decodeIfPresent(Animatable<Double>.self, forKey: .brightness) ?? neutral.brightness
        contrast = try container.decodeIfPresent(Animatable<Double>.self, forKey: .contrast) ?? neutral.contrast
        saturation = try container.decodeIfPresent(Animatable<Double>.self, forKey: .saturation) ?? neutral.saturation
        temperature = try container.decodeIfPresent(Animatable<Double>.self, forKey: .temperature) ?? neutral.temperature
        tint = try container.decodeIfPresent(Animatable<Double>.self, forKey: .tint) ?? neutral.tint
        lift = try container.decodeIfPresent(Animatable<RGBValues>.self, forKey: .lift) ?? neutral.lift
        gamma = try container.decodeIfPresent(Animatable<RGBValues>.self, forKey: .gamma) ?? neutral.gamma
        gain = try container.decodeIfPresent(Animatable<RGBValues>.self, forKey: .gain) ?? neutral.gain
        lut = try container.decodeIfPresent(ColorLUT.self, forKey: .lut)
        lutIntensity = try container.decodeIfPresent(Animatable<Double>.self, forKey: .lutIntensity) ?? neutral.lutIntensity
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(exposure, forKey: .exposure)
        try container.encode(brightness, forKey: .brightness)
        try container.encode(contrast, forKey: .contrast)
        try container.encode(saturation, forKey: .saturation)
        try container.encode(temperature, forKey: .temperature)
        try container.encode(tint, forKey: .tint)
        try container.encode(lift, forKey: .lift)
        try container.encode(gamma, forKey: .gamma)
        try container.encode(gain, forKey: .gain)
        try container.encodeIfPresent(lut, forKey: .lut)
        try container.encode(lutIntensity, forKey: .lutIntensity)
    }
}

/// A three-dimensional colour look-up table, such as one read from a
/// `.cube` file: each colour in is looked up in a cube of colours out.
///
/// Kept in the project itself rather than beside it, so a project carries
/// its looks wherever it goes; a 33-point cube is about half a megabyte.
public struct ColorLUT: Equatable, Sendable, Codable {
    /// What the look is called, usually the name of the file it came from.
    public var name: String
    /// How many points the cube has along each side.
    public var dimension: Int
    /// The cube's colours as 32-bit floats, four to an entry (red, green,
    /// blue and alpha), red changing fastest and blue slowest: the layout
    /// `CIColorCube` takes.
    public var data: Data

    /// Nil unless the data holds exactly a cube of `dimension` points.
    public init?(name: String, dimension: Int, data: Data) {
        guard dimension >= 2, data.count == dimension * dimension * dimension * 4 * MemoryLayout<Float32>.size else {
            return nil
        }
        self.name = name
        self.dimension = dimension
        self.data = data
    }

    /// A cube that leaves every colour as it is, or that maps each through
    /// `transform` when there is one.
    public static func identity(
        dimension: Int, name: String = "", transform: (SIMD3<Float>) -> SIMD3<Float> = { $0 }
    ) -> ColorLUT {
        var values: [Float32] = []
        values.reserveCapacity(dimension * dimension * dimension * 4)
        let step = Float(dimension - 1)
        for blue in 0..<dimension {
            for green in 0..<dimension {
                for red in 0..<dimension {
                    let colour = transform(SIMD3(Float(red) / step, Float(green) / step, Float(blue) / step))
                    values += [colour.x, colour.y, colour.z, 1]
                }
            }
        }
        return ColorLUT(name: name, dimension: dimension, data: values.withUnsafeBufferPointer { Data(buffer: $0) })!
    }
}
