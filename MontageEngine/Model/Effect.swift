import Foundation

/// An effect applied to a clip. Effects run in the order the clip lists
/// them; every parameter is `Animatable`, so any of them can be keyframed.
public struct Effect: Identifiable, Equatable, Sendable, Codable {
    public var id: UUID
    /// Turned off, the effect stays on the clip but is skipped.
    public var isEnabled: Bool
    public var kind: Kind
    /// Limits a video effect to part of the picture; nil applies it to all
    /// of it.
    public var mask: Mask?

    public init(id: UUID = UUID(), isEnabled: Bool = true, _ kind: Kind, mask: Mask? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.kind = kind
        self.mask = mask
    }

    public enum Kind: Equatable, Sendable {
        // Video
        case colorCorrection(ColorCorrection)
        case mosaic(Mosaic)
        // Audio
        case gain(Gain)
        case pan(Pan)
        case equalizer(Equalizer)
        case delay(Delay)
        case reverb(Reverb)

        /// Whether the effect changes the picture rather than the sound.
        public var isVideo: Bool {
            switch self {
            case .colorCorrection, .mosaic: true
            case .gain, .pan, .equalizer, .delay, .reverb: false
            }
        }

        /// Whether the effect keeps sounding after the clip ends, so the
        /// composition has to leave room for its tail.
        public var hasTail: Bool {
            switch self {
            case .delay, .reverb: true
            default: false
            }
        }
    }
}

// Written as `{"type": "mosaic", "parameters": {...}}`, so the file names
// each effect plainly and a new kind's parameters can come and go freely.
extension Effect.Kind: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, parameters
    }

    private enum KindType: String, Codable {
        case colorCorrection, mosaic, gain, pan, equalizer, delay, reverb
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(KindType.self, forKey: .type) {
        case .colorCorrection: self = .colorCorrection(try container.decode(ColorCorrection.self, forKey: .parameters))
        case .mosaic: self = .mosaic(try container.decode(Mosaic.self, forKey: .parameters))
        case .gain: self = .gain(try container.decode(Gain.self, forKey: .parameters))
        case .pan: self = .pan(try container.decode(Pan.self, forKey: .parameters))
        case .equalizer: self = .equalizer(try container.decode(Equalizer.self, forKey: .parameters))
        case .delay: self = .delay(try container.decode(Delay.self, forKey: .parameters))
        case .reverb: self = .reverb(try container.decode(Reverb.self, forKey: .parameters))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .colorCorrection(let parameters):
            try container.encode(KindType.colorCorrection, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .mosaic(let parameters):
            try container.encode(KindType.mosaic, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .gain(let parameters):
            try container.encode(KindType.gain, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .pan(let parameters):
            try container.encode(KindType.pan, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .equalizer(let parameters):
            try container.encode(KindType.equalizer, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .delay(let parameters):
            try container.encode(KindType.delay, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        case .reverb(let parameters):
            try container.encode(KindType.reverb, forKey: .type)
            try container.encode(parameters, forKey: .parameters)
        }
    }
}

// MARK: - Video effects
//
// `ColorCorrection` is in a file of its own.

/// Hides part of the picture, such as a face or a number plate.
public struct Mosaic: Equatable, Sendable, Codable {
    public enum Style: String, Equatable, Sendable, Codable {
        case pixelate, blur, checkerboard
    }

    public var style: Style = .pixelate
    /// How coarse the mosaic is, as a fraction of the frame's width.
    public var scale = Animatable(0.03)

    public init() {}
}

// MARK: - Audio effects

public struct Gain: Equatable, Sendable, Codable {
    /// In decibels; 0 is unchanged.
    public var decibels = Animatable(0.0)

    public init() {}
}

public struct Pan: Equatable, Sendable, Codable {
    /// -1 is fully left, 0 is centred, 1 is fully right.
    public var position = Animatable(0.0)

    public init() {}
}

public struct Equalizer: Equatable, Sendable, Codable {
    public struct Band: Equatable, Sendable, Codable {
        /// In hertz.
        public var frequency: Animatable<Double>
        /// In decibels; 0 is flat.
        public var gain: Animatable<Double>
        public var bandwidth: Animatable<Double>

        public init(frequency: Double, gain: Double = 0, bandwidth: Double = 1) {
            self.frequency = Animatable(frequency)
            self.gain = Animatable(gain)
            self.bandwidth = Animatable(bandwidth)
        }
    }

    public var bands: [Band] = [100, 400, 1600, 6400].map { Band(frequency: $0) }

    public init() {}
}

public struct Delay: Equatable, Sendable, Codable {
    /// In seconds.
    public var time = Animatable(0.25)
    /// 0 to 1: how much of each echo comes back as the next.
    public var feedback = Animatable(0.3)
    /// 0 is all dry, 1 is all echo.
    public var mix = Animatable(0.3)

    public init() {}
}

public struct Reverb: Equatable, Sendable, Codable {
    public enum Room: String, Equatable, Sendable, Codable {
        case smallRoom, mediumRoom, largeHall, cathedral, plate
    }

    public var room: Room = .mediumRoom
    /// 0 is all dry, 1 is all reverb.
    public var mix = Animatable(0.25)

    public init() {}
}
