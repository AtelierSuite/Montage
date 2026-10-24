import CoreGraphics
import CoreMedia

/// A value that can be blended between keyframes.
public protocol Interpolatable: Codable, Equatable, Sendable {
    /// The value `fraction` of the way from `from` to `to`, where 0 is
    /// `from` and 1 is `to`. Values that can't be blended hold `from`.
    static func interpolate(from: Self, to: Self, fraction: Double) -> Self
}

extension Double: Interpolatable {
    public static func interpolate(from: Double, to: Double, fraction: Double) -> Double {
        from + (to - from) * fraction
    }
}

extension CGPoint: Interpolatable {
    public static func interpolate(from: CGPoint, to: CGPoint, fraction: Double) -> CGPoint {
        CGPoint(x: .interpolate(from: from.x, to: to.x, fraction: fraction),
                y: .interpolate(from: from.y, to: to.y, fraction: fraction))
    }
}

extension CGSize: Interpolatable {
    public static func interpolate(from: CGSize, to: CGSize, fraction: Double) -> CGSize {
        CGSize(width: .interpolate(from: from.width, to: to.width, fraction: fraction),
               height: .interpolate(from: from.height, to: to.height, fraction: fraction))
    }
}

extension CGFloat: Interpolatable {
    public static func interpolate(from: CGFloat, to: CGFloat, fraction: Double) -> CGFloat {
        from + (to - from) * fraction
    }
}

extension Bool: Interpolatable {
    public static func interpolate(from: Bool, to: Bool, fraction: Double) -> Bool {
        fraction < 1 ? from : to
    }
}

/// A parameter that is either one value throughout, or keyframed to change
/// over time. Every effect and clip parameter is one of these, so any of
/// them can be keyframed without the model changing shape.
public struct Animatable<Value: Interpolatable>: Equatable, Sendable {
    /// The value when there are no keyframes.
    public var value: Value
    /// Keyframes in time order. Empty means `value` holds throughout.
    public private(set) var keyframes: [Keyframe<Value>]

    public init(_ value: Value, keyframes: [Keyframe<Value>] = []) {
        self.value = value
        self.keyframes = keyframes.sorted { $0.time < $1.time }
    }

    public var isAnimated: Bool { !keyframes.isEmpty }

    /// The value at a time, measured from the start of whatever the
    /// parameter belongs to (for a clip's parameters, the clip's start on the
    /// timeline). Before the first keyframe and after the last, the nearest
    /// keyframe's value holds.
    public func value(at time: CMTime) -> Value {
        guard let first = keyframes.first, let last = keyframes.last else { return value }
        if time <= first.time { return first.value }
        if time >= last.time { return last.value }
        // The last keyframe at or before the time; there's always one after.
        let index = keyframes.lastIndex { $0.time <= time }!
        let from = keyframes[index]
        let to = keyframes[index + 1]
        let span = (to.time - from.time).seconds
        let fraction = span > 0 ? (time - from.time).seconds / span : 1
        return Value.interpolate(from: from.value, to: to.value, fraction: from.interpolation.curve(fraction))
    }

    /// Adds a keyframe, replacing any already at the same time.
    public mutating func setKeyframe(_ keyframe: Keyframe<Value>) {
        keyframes.removeAll { $0.time == keyframe.time }
        let index = keyframes.firstIndex { $0.time > keyframe.time } ?? keyframes.endIndex
        keyframes.insert(keyframe, at: index)
    }

    public mutating func removeKeyframe(at time: CMTime) {
        keyframes.removeAll { $0.time == time }
    }

    public mutating func removeAllKeyframes() {
        keyframes.removeAll()
    }
}

extension Animatable: Codable {
    private enum CodingKeys: String, CodingKey {
        case value, keyframes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            try container.decode(Value.self, forKey: .value),
            keyframes: try container.decodeIfPresent([Keyframe<Value>].self, forKey: .keyframes) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value, forKey: .value)
        // Most parameters never get keyframes; leaving the key out keeps
        // project files short.
        if !keyframes.isEmpty {
            try container.encode(keyframes, forKey: .keyframes)
        }
    }
}

/// A parameter's value at one moment.
public struct Keyframe<Value: Interpolatable>: Equatable, Sendable {
    /// When, measured from the start of whatever the parameter belongs to.
    public var time: CMTime
    public var value: Value
    /// How the value travels from this keyframe to the next.
    public var interpolation: Interpolation

    public init(time: CMTime, value: Value, interpolation: Interpolation = .linear) {
        self.time = time
        self.value = value
        self.interpolation = interpolation
    }
}

extension Keyframe: Codable {
    private enum CodingKeys: String, CodingKey {
        case time, value, interpolation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        time = try container.decode(CMTime.self, forKey: .time)
        value = try container.decode(Value.self, forKey: .value)
        interpolation = try container.decodeIfPresent(Interpolation.self, forKey: .interpolation) ?? .linear
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(time, forKey: .time)
        try container.encode(value, forKey: .value)
        try container.encode(interpolation, forKey: .interpolation)
    }
}

/// How a value travels from one keyframe to the next.
public enum Interpolation: String, Codable, Sendable, CaseIterable {
    /// Holds this keyframe's value until the next one, then jumps.
    case hold
    case linear
    case easeIn
    case easeOut
    case easeInOut

    /// Maps the straight fraction of the way between two keyframes to the
    /// fraction of the way between their values.
    func curve(_ t: Double) -> Double {
        switch self {
        case .hold: t < 1 ? 0 : 1
        case .linear: t
        case .easeIn: t * t
        case .easeOut: 1 - (1 - t) * (1 - t)
        case .easeInOut: t < 0.5 ? 2 * t * t : 1 - 2 * (1 - t) * (1 - t)
        }
    }
}
