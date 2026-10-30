import CoreMedia
import Foundation

/// How fast a clip plays its media: so much of the media for so much of the
/// timeline, constant all through the clip. 1:1 plays it as it is, 1:2 at
/// half speed, 2:1 at double.
///
/// Kept as a fraction rather than a number, so a clip's length on the
/// timeline works out exactly from its media's, and clips placed end to end
/// at another speed still meet. Only forward: the media is never played
/// backwards.
public struct ClipSpeed: Hashable, Sendable {
    /// So much of the media...
    public private(set) var media: Int64
    /// ...plays over so much of the timeline.
    public private(set) var timeline: Int64

    /// The media's own speed.
    public static let normal = ClipSpeed(reduced: 1, 1)

    private init(reduced media: Int64, _ timeline: Int64) {
        self.media = media
        self.timeline = timeline
    }

    /// A speed as the fraction of two lengths, reduced. Nil unless both are
    /// more than nothing.
    public init?(media: Int64, timeline: Int64) {
        guard media > 0, timeline > 0 else { return nil }
        let divisor = Self.gcd(media, timeline)
        self.init(reduced: media / divisor, timeline / divisor)
    }

    /// The speed that plays a stretch of media over a stretch of the
    /// timeline. Nil unless both are more than nothing.
    public init?(media: CMTime, timeline: CMTime) {
        guard media.isNumeric, timeline.isNumeric, media > .zero, timeline > .zero else { return nil }
        // (a / b) / (c / d) = (a * d) / (b * c)
        let (top, topOverflow) = media.value.multipliedReportingOverflow(by: Int64(timeline.timescale))
        let (bottom, bottomOverflow) = timeline.value.multipliedReportingOverflow(by: Int64(media.timescale))
        if !topOverflow && !bottomOverflow {
            self.init(media: top, timeline: bottom)
        } else {
            self.init(rate: media.seconds / timeline.seconds)
        }
    }

    /// The nearest simple fraction to a rate, such as 0.5 for half speed.
    public init?(rate: Double) {
        guard rate.isFinite, rate > 0 else { return nil }
        let scale = 1_000_000.0
        self.init(media: Int64((rate * scale).rounded()), timeline: Int64(scale))
    }

    /// This speed applied on top of another, as for media at one speed
    /// inside a clip at another.
    public func combined(with other: ClipSpeed) -> ClipSpeed {
        let (media, mediaOverflow) = self.media.multipliedReportingOverflow(by: other.media)
        let (timeline, timelineOverflow) = self.timeline.multipliedReportingOverflow(by: other.timeline)
        if !mediaOverflow && !timelineOverflow, let speed = ClipSpeed(media: media, timeline: timeline) { return speed }
        return ClipSpeed(rate: rate * other.rate) ?? .normal
    }

    /// The speed as one number: 0.5 at half speed, 2 at double.
    public var rate: Double { Double(media) / Double(timeline) }

    public var isNormal: Bool { media == timeline }

    /// How long a stretch of the timeline plays a length of the media.
    public func timelineDuration(ofMedia duration: CMTime) -> CMTime {
        isNormal ? duration : Self.scale(duration, by: timeline, over: media)
    }

    /// How much of the media plays over a length of the timeline.
    public func mediaDuration(ofTimeline duration: CMTime) -> CMTime {
        isNormal ? duration : Self.scale(duration, by: media, over: timeline)
    }

    /// A time multiplied by a fraction, exactly where it can be held, to the
    /// nearest microsecond otherwise.
    private static func scale(_ time: CMTime, by numerator: Int64, over denominator: Int64) -> CMTime {
        guard time.isNumeric else { return time }
        let (value, valueOverflow) = time.value.multipliedReportingOverflow(by: numerator)
        let (timescale, timescaleOverflow) = Int64(time.timescale).multipliedReportingOverflow(by: denominator)
        if !valueOverflow && !timescaleOverflow {
            let divisor = gcd(abs(value), timescale)
            let reducedScale = timescale / max(divisor, 1)
            if reducedScale <= Int64(Int32.max) {
                return CMTime(value: value / max(divisor, 1), timescale: CMTimeScale(reducedScale))
            }
        }
        return CMTime(seconds: time.seconds * Double(numerator) / Double(denominator), preferredTimescale: 1_000_000)
    }

    private static func gcd(_ a: Int64, _ b: Int64) -> Int64 {
        var (a, b) = (a, b)
        while b != 0 { (a, b) = (b, a % b) }
        return a == 0 ? 1 : a
    }
}

extension ClipSpeed: Codable {
    private enum CodingKeys: String, CodingKey {
        case media, timeline
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let media = try container.decode(Int64.self, forKey: .media)
        let timeline = try container.decode(Int64.self, forKey: .timeline)
        // A speed that can't be played plays at normal speed.
        self = ClipSpeed(media: media, timeline: timeline) ?? .normal
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(media, forKey: .media)
        try container.encode(timeline, forKey: .timeline)
    }
}
